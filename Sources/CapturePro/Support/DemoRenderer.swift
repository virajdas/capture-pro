import AppKit
import AVFoundation
import ScreenCaptureKit

/// `CapturePro --render-demo <folder>`: builds a synthetic recording (fake UI, scripted cursor,
/// clicks and typing), exports it through the real pipeline, and writes still frames for review.
enum DemoRenderer {
    static func run(output: URL) {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await render(output)
                print("Demo written to \(output.path)")
            } catch {
                print("Demo failed: \(error)")
                exit(1)
            }
            sema.signal()
        }
        sema.wait()
    }

    static func recordTest(output: URL) {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { throw ExportError.failed("No display") }
                let url = output.appendingPathComponent("Test.capturepro")
                try? FileManager.default.removeItem(at: url)
                let rec = Recorder(target: .display(display), options: RecordingOptions(fps: 60, systemAudio: true),
                                   projectURL: url)
                try await rec.start()
                try await Task.sleep(for: .seconds(3))
                let project = try await rec.stop()
                print(String(format: "Recorded %.2fs at %.0f×%.0f, %d cursor samples, audio: %@",
                             project.info.duration, project.info.pixelWidth, project.info.pixelHeight,
                             project.input.moves.count, project.info.hasSystemAudio ? "yes" : "no"))
                try await Exporter().export(project: project, to: output.appendingPathComponent("test.mp4")) { _ in }
                print("Exported test.mp4")
            } catch {
                print("Record test failed: \(error)")
            }
            sema.signal()
        }
        sema.wait()
    }

    private static func render(_ folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("Demo.capturepro")
        try? FileManager.default.removeItem(at: projectURL)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("cursors"), withIntermediateDirectories: true)

        let size = CGSize(width: 2880, height: 1800), points = CGSize(width: 1440, height: 900)
        let duration = 9.0, fps = 30.0

        var input = InputLog()
        let path: [(Double, Double, Double)] = [
            (0, 0.5, 0.6), (1.0, 0.18, 0.3), (1.6, 0.18, 0.3), (2.6, 0.62, 0.42), (3.0, 0.62, 0.42),
            (5.2, 0.64, 0.44), (6.0, 0.85, 0.8), (6.4, 0.85, 0.8), (9, 0.5, 0.6),
        ]
        var t = 0.0
        while t <= duration {
            let p = interpolate(path, t)
            input.moves.append(MoveSample(t: t, x: p.0, y: p.1))
            t += 1.0 / 120
        }
        for c in [1.2, 2.8, 6.2] {
            let p = interpolate(path, c)
            input.clicks.append(ClickEvent(t: c, x: p.0, y: p.1))
            input.clicks.append(ClickEvent(t: c + 0.09, x: p.0, y: p.1, up: true))
        }
        input.keys = stride(from: 3.2, to: 5.0, by: 0.12).map { $0 }

        let writer = try AVAssetWriter(outputURL: projectURL.appendingPathComponent("raw.mov"), fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(vi)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * fps)
        for f in 0...frames {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let time = Double(f) / fps
            let typed = max(0, min(15, Int((time - 3.2) / 0.12)))
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            drawFakeUI(into: pb, size: size, typed: typed, selected: time > 1.2 ? 1 : 0)
            adaptor.append(pb, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
        }
        vi.markAsFinished()
        await writer.finishWriting()

        var info = RecordingInfo()
        info.duration = duration
        info.pointWidth = points.width; info.pointHeight = points.height
        info.pixelWidth = size.width; info.pixelHeight = size.height
        var export = ExportSettings()
        export.resolution = .p1080
        let project = RecordingProject(url: projectURL, info: info, input: input,
                                       edit: EditState(style: StyleSettings(), export: export))
        project.edit.segments = project.effectiveSegments()
        project.save()
        print("Zoom segments:", project.edit.segments.map { String(format: "%.2f–%.2f @%.1fx", $0.start, $0.end, $0.scale) })

        let out = folder.appendingPathComponent("demo.mp4")
        let start = Date()
        try await Exporter().export(project: project, to: out) { _ in }
        print(String(format: "Exported in %.1fs", Date().timeIntervalSince(start)))

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for s in [0.5, 1.3, 2.0, 4.0, 6.3, 8.5] {
            let (img, _) = try await gen.image(at: CMTime(seconds: s, preferredTimescale: 600))
            let url = folder.appendingPathComponent(String(format: "frame-%.1f.png", s))
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
            }
        }

        project.edit.export.format = .gif
        try await Exporter().export(project: project, to: folder.appendingPathComponent("demo.gif")) { _ in }

        // Beautified still.
        if let still = try await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image as CGImage?,
           let pretty = Compositor.beautify(still, style: StyleSettings()) {
            let url = folder.appendingPathComponent("beautified.png")
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, pretty, nil)
                CGImageDestinationFinalize(d)
            }
        }
    }

    private static func interpolate(_ path: [(Double, Double, Double)], _ t: Double) -> (Double, Double) {
        guard let i = path.lastIndex(where: { $0.0 <= t }), i + 1 < path.count else { return (path.last!.1, path.last!.2) }
        let a = path[i], b = path[i + 1]
        let f = smoothstep(0, 1, (t - a.0) / (b.0 - a.0))
        return (lerp(a.1, b.1, f), lerp(a.2, b.2, f))
    }

    private static func drawFakeUI(into pb: CVPixelBuffer, size: CGSize, typed: Int, selected: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let W = size.width, H = size.height
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Sidebar
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W * 0.24, height: H))
        for i in 0..<9 {
            let y = H - 200 - Double(i) * 110
            if i == selected {
                ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.47, blue: 1, alpha: 1))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 30, y: y - 20, width: W * 0.24 - 60, height: 80), cornerWidth: 16, cornerHeight: 16, transform: nil))
                ctx.fillPath()
            }
            ctx.setFillColor(CGColor(gray: i == selected ? 1 : 0.55, alpha: 1))
            ctx.fill(CGRect(x: 70, y: y + 10, width: 260 + Double((i * 37) % 120), height: 22))
        }
        // Title bar
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: W * 0.24, y: H - 140, width: W, height: 140))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 40 + Double(i) * 46, y: H - 90, width: 26, height: 26))
        }
        // Text field with typed characters
        let field = CGRect(x: W * 0.45, y: H * 0.5, width: W * 0.36, height: 100)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: field, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.47, blue: 1, alpha: typed > 0 ? 1 : 0.3)); ctx.setLineWidth(4)
        ctx.addPath(CGPath(roundedRect: field, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        for i in 0..<typed { ctx.fill(CGRect(x: field.minX + 30 + Double(i) * 38, y: field.midY - 18, width: 28, height: 36)) }
        // Cards
        for i in 0..<3 {
            let r = CGRect(x: W * 0.3 + Double(i) * W * 0.23, y: H * 0.12, width: W * 0.2, height: H * 0.26)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 24, cornerHeight: 24, transform: nil)); ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
            ctx.fill(CGRect(x: r.minX + 40, y: r.maxY - 80, width: r.width * 0.6, height: 24))
            ctx.fill(CGRect(x: r.minX + 40, y: r.maxY - 130, width: r.width * 0.4, height: 18))
        }
        // Button bottom right
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.47, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: W * 0.8, y: H * 0.15, width: 360, height: 100), cornerWidth: 50, cornerHeight: 50, transform: nil))
        ctx.fillPath()
    }
}
