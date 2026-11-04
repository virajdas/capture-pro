import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Builds the AVFoundation pipeline (trimmed composition + Core Image video composition)
/// shared by the live preview and the exporter.
enum CompositionBuilder {
    struct Result {
        let asset: AVMutableComposition
        let video: AVMutableVideoComposition
        let duration: Double
    }

    static func build(project: RecordingProject, compositor: Compositor, fps: Int) async throws -> Result {
        let source = AVURLAsset(url: project.videoURL)
        let comp = AVMutableComposition()
        let start = project.edit.trimStart.clamped(0, max(0, project.info.duration - 0.1))
        let end = max(start + 0.1, project.trimEnd)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        guard let srcVideo = try await source.loadTracks(withMediaType: .video).first,
              let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.failed("The recording has no video") }
        try video.insertTimeRange(range, of: srcVideo, at: .zero)

        // Audio lives in separate files that may start slightly after the first frame.
        var audioFiles: [(URL, Double)] = []
        if project.info.hasSystemAudio { audioFiles.append((project.systemAudioURL, project.info.systemAudioOffset)) }
        if project.info.hasMicrophone { audioFiles.append((project.microphoneURL, project.info.microphoneOffset)) }
        for (url, offset) in audioFiles {
            let a = AVURLAsset(url: url)
            guard let track = try? await a.loadTracks(withMediaType: .audio).first,
                  let dur = try? await a.load(.duration).seconds,
                  let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            // Map [start, end] of the video timeline into the audio file's own timeline.
            let aStart = max(0, start - offset)
            let aEnd = min(dur, end - offset)
            guard aEnd > aStart else { continue }
            let at = max(0, offset - start)
            try? dst.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: aStart, preferredTimescale: 48000),
                            end: CMTime(seconds: aEnd, preferredTimescale: 48000)),
                of: track, at: CMTime(seconds: at, preferredTimescale: 48000))
        }

        let compositor = compositor
        let videoComp = try await AVMutableVideoComposition.videoComposition(with: comp) { request in
            let img = compositor.render(source: request.sourceImage, time: request.compositionTime.seconds)
            request.finish(with: img, context: nil)
        }
        videoComp.renderSize = compositor.state.canvas
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return Result(asset: comp, video: videoComp, duration: end - start)
    }
}

enum ExportError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let s) = self { return s }
        return nil
    }
}

/// Renders the final video (or GIF) offline with explicit bitrate control.
final class Exporter {
    private(set) var cancelled = false
    func cancel() { cancelled = true }

    func export(project: RecordingProject, to url: URL, progress: @escaping (Double) -> Void) async throws {
        let ex = project.edit.export
        let style = project.edit.style
        let src = CGSize(width: project.info.pixelWidth, height: project.info.pixelHeight)
        let gif = ex.format == .gif
        var canvas = RenderState.canvasSize(source: src, style: style, shortSide: ex.resolution.shortSide)
        if gif {
            let s = Double(ex.gifWidth) / canvas.width
            canvas = CGSize(width: (canvas.width * s / 2).rounded() * 2, height: (canvas.height * s / 2).rounded() * 2)
        }
        let timeline = MotionTimeline(
            input: project.input, duration: project.info.duration, segments: project.effectiveSegments(),
            style: style, aspect: src.width / max(src.height, 1))
        let state = RenderState(style: style, canvas: canvas,
                                pointSize: CGSize(width: project.info.pointWidth, height: project.info.pointHeight),
                                timeline: timeline, cursors: project.cursorImages(),
                                timeOffset: project.edit.trimStart)
        let compositor = Compositor(state: state)
        let fps = gif ? ex.gifFPS : ex.fps
        let built = try await CompositionBuilder.build(project: project, compositor: compositor, fps: fps)
        try? FileManager.default.removeItem(at: url)

        if gif {
            try await writeGIF(built, to: url, fps: fps, progress: progress)
        } else {
            try await writeVideo(built, to: url, settings: ex, canvas: canvas, progress: progress)
        }
    }

    private func writeVideo(_ b: CompositionBuilder.Result, to url: URL, settings: ExportSettings,
                            canvas: CGSize, progress: @escaping (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: b.asset)
        let vTracks = try await b.asset.loadTracks(withMediaType: .video)
        let aTracks = try await b.asset.loadTracks(withMediaType: .audio)

        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        vOut.videoComposition = b.video
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(o)
            aOut = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: settings.format == .mov ? .mov : .mp4)
        let bitrate = settings.quality.bpp * canvas.width * canvas.height * Double(settings.fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
        ]
        if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width, AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Could not read recording") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Could not write file") }
        writer.startSession(atSourceTime: .zero)

        let duration = b.duration
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pump(vOut, into: vIn, label: "video") { t in progress(min(1, t / duration)) } }
            if let aOut, let aIn {
                group.addTask { await self.pump(aOut, into: aIn, label: "audio") { _ in } }
            }
        }

        if cancelled || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if cancelled { throw CancellationError() }
            throw ExportError.failed(reader.error?.localizedDescription ?? "Export failed")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Export failed")
        }
        progress(1)
    }

    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                      tick: @escaping (Double) -> Void) async {
        let queue = DispatchQueue(label: "export.\(label)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !done {
                    if self.cancelled {
                        done = true
                    } else if let buf = output.copyNextSampleBuffer() {
                        tick(CMSampleBufferGetPresentationTimeStamp(buf).seconds)
                        if !input.append(buf) { done = true }
                        continue
                    } else {
                        done = true
                    }
                }
                if done {
                    input.markAsFinished()
                    cont.resume()
                }
            }
        }
    }

    private func writeGIF(_ b: CompositionBuilder.Result, to url: URL, fps: Int,
                          progress: @escaping (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: b.asset)
        let vTracks = try await b.asset.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.videoComposition = b.video
        reader.add(out)
        guard reader.startReading() else { throw ExportError.failed("Could not read recording") }

        // ImageIO needs the exact frame count up front, so spool frames to disk first.
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spool) }
        var frames: [URL] = []
        let ctx = CIContext()
        while let buf = out.copyNextSampleBuffer() {
            if cancelled { reader.cancelReading(); throw CancellationError() }
            guard let px = CMSampleBufferGetImageBuffer(buf) else { continue }
            let ci = CIImage(cvPixelBuffer: px)
            let url = spool.appendingPathComponent("\(frames.count).png")
            try ctx.writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            frames.append(url)
            progress(0.85 * min(1, CMSampleBufferGetPresentationTimeStamp(buf).seconds / b.duration))
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ExportError.failed("Could not create GIF")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
            kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps),
        ]] as CFDictionary
        for (i, f) in frames.enumerated() {
            if cancelled { throw CancellationError() }
            if let src = CGImageSourceCreateWithURL(f as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
            progress(0.85 + 0.15 * Double(i) / Double(max(frames.count, 1)))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.failed("Could not finish GIF") }
        progress(1)
    }
}
