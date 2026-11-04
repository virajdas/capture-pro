import AppKit
import AVFoundation
import ScreenCaptureKit

enum CaptureTarget {
    case display(SCDisplay)
    /// Rect in display-local points, top-left origin.
    case area(SCDisplay, CGRect)
    case window(SCWindow)

    var globalRect: CGRect {
        switch self {
        case .display(let d): d.frame
        case .area(let d, let r): r.offsetBy(dx: d.frame.minX, dy: d.frame.minY)
        case .window(let w): Self.windowBounds(w.windowID) ?? w.frame
        }
    }

    static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    static func scale(for display: SCDisplay) -> Double {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }.map { Double($0.backingScaleFactor) } ?? 2
    }
}

struct RecordingOptions {
    var fps = 60
    var hideSystemCursor = true
    var systemAudio = false
    var microphone = false
    var microphoneID: String? = nil
    var camera: CameraRecorder? = nil
}

/// Lazily-created AAC writer for one audio stream, so we can adopt whatever format arrives.
private final class AudioFileWriter {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstPTS: Double?

    init(url: URL) { self.url = url }

    func append(_ buf: CMSampleBuffer) {
        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(buf),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            let channels = min(2, Int(asbd.mChannelsPerFrame))
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ], sourceFormatHint: fmt)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { return }
            w.add(i)
            let pts = CMSampleBufferGetPresentationTimeStamp(buf)
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts)
            writer = w; input = i
            firstPTS = pts.seconds
        }
        if let input, input.isReadyForMoreMediaData { input.append(buf) }
    }

    func finish() async -> Bool {
        guard let writer, let input else { return false }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let target: CaptureTarget
    let options: RecordingOptions
    let projectURL: URL
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudio: AudioFileWriter?
    private var micAudio: AudioFileWriter?
    private let tracker: InputTracker
    private let videoQueue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "capture.audio", qos: .userInteractive)
    private var firstPTS: CMTime?
    private var lastBuffer: CMSampleBuffer?
    private var pixelSize = CGSize.zero
    private var pointSize = CGSize.zero
    private var captureFPS = 60
    private var dropped = 0

    init(target: CaptureTarget, options: RecordingOptions, projectURL: URL) {
        self.target = target
        self.options = options
        self.projectURL = projectURL
        let t = target
        self.tracker = InputTracker(area: { t.globalRect })
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var scale = 2.0
        switch target {
        case .display(let d):
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            scale = CaptureTarget.scale(for: d)
            pointSize = d.frame.size
        case .area(let d, let rect):
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            scale = CaptureTarget.scale(for: d)
            config.sourceRect = rect
            pointSize = rect.size
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
            scale = Double(filter.pointPixelScale)
            pointSize = w.frame.size
            config.ignoreShadowsSingleWindow = true
        }
        pixelSize = CGSize(width: (pointSize.width * scale / 2).rounded() * 2,
                           height: (pointSize.height * scale / 2).rounded() * 2)
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        let captureFPS = options.fps
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFPS))
        self.captureFPS = captureFPS
        config.showsCursor = !options.hideSystemCursor
        // 4:2:0 is what the hardware encoder consumes natively: half the memory traffic of BGRA
        // and no conversion pass, which keeps the rest of the Mac responsive while recording.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.captureResolution = .best
        if options.systemAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        if options.microphone {
            config.captureMicrophone = true
            if let id = options.microphoneID { config.microphoneCaptureDeviceID = id }
        }

        let w = try AVAssetWriter(outputURL: projectURL.appendingPathComponent("raw.mov"), fileType: .mov)
        // HEVC: H.264 cannot encode 5K/6K retina frames. Generous bitrate keeps text crisp.
        let bitrate = min(0.2 * pixelSize.width * pixelSize.height * Double(captureFPS), 120_000_000)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelSize.width,
            AVVideoHeightKey: pixelSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: captureFPS,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        vi.expectsMediaDataInRealTime = true
        w.add(vi)
        guard w.startWriting() else { throw w.error ?? ExportError.failed("Could not start writing") }
        writer = w
        videoInput = vi
        if options.systemAudio { systemAudio = AudioFileWriter(url: projectURL.appendingPathComponent("system.m4a")) }
        if options.microphone { micAudio = AudioFileWriter(url: projectURL.appendingPathComponent("mic.m4a")) }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if options.microphone { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue) }
        stream = s
        tracker.start()
        try await s.startCapture()
        options.camera?.startRecording()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buf.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let writer, let videoInput else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(buf)
            if firstPTS == nil {
                firstPTS = pts
                writer.startSession(atSourceTime: pts)
                tracker.setStart(pts.seconds)
            }
            if videoInput.isReadyForMoreMediaData { videoInput.append(buf) } else { dropped += 1 }
            lastBuffer = buf
        case .audio:
            guard firstPTS != nil else { return }
            systemAudio?.append(buf)
        case .microphone:
            guard firstPTS != nil else { return }
            micAudio?.append(buf)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error) }
    }

    func stop() async throws -> RecordingProject {
        let stopHost = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream?.stopCapture()
        stream = nil
        let (log, images) = tracker.stop()

        guard let writer, let videoInput, let first = firstPTS else {
            writer?.cancelWriting()
            throw ExportError.failed("No frames were captured. Check Screen Recording permission in System Settings.")
        }
        // Frames only arrive when the screen changes; repeat the last one so the video
        // lasts until the moment recording stopped.
        let end: CMTime = await withCheckedContinuation { cont in
            videoQueue.async {
                var end = CMSampleBufferGetPresentationTimeStamp(self.lastBuffer!)
                if let last = self.lastBuffer, CMTimeCompare(stopHost, end) > 0 {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: stopHost, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                          sampleTimingArray: &timing, sampleBufferOut: &copy)
                    if let copy, videoInput.isReadyForMoreMediaData, videoInput.append(copy) { end = stopHost }
                }
                cont.resume(returning: end)
            }
        }
        if dropped > 0 { NSLog("Capture Pro: encoder skipped \(dropped) frames") }
        videoInput.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.failed("Could not finish the recording")
        }

        var info = RecordingInfo()
        info.duration = CMTimeSubtract(end, first).seconds
        info.pointWidth = pointSize.width
        info.pointHeight = pointSize.height
        info.pixelWidth = pixelSize.width
        info.pixelHeight = pixelSize.height
        switch target {
        case .display: info.mode = "display"
        case .area: info.mode = "area"
        case .window: info.mode = "window"
        }
        if let a = systemAudio, await a.finish(), let p = a.firstPTS {
            info.hasSystemAudio = true
            info.systemAudioOffset = p - first.seconds
        }
        if let m = micAudio, await m.finish(), let p = m.firstPTS {
            info.hasMicrophone = true
            info.microphoneOffset = p - first.seconds
        }
        if let cam = options.camera, await cam.stop(), let p = cam.firstHostTime {
            info.hasCamera = true
            info.cameraOffset = p - first.seconds
        }

        let cursors = projectURL.appendingPathComponent("cursors")
        for (id, img) in images {
            let url = cursors.appendingPathComponent("cursor-\(id).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }

        let prefs = Preferences.shared
        let project = RecordingProject(url: projectURL, info: info, input: log,
                                       edit: EditState(style: prefs.style, export: prefs.export))
        project.edit.segments = project.effectiveSegments()
        project.save()
        return project
    }
}
