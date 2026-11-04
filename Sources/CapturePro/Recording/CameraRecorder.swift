import AVFoundation
import AppKit

/// Records the webcam to its own file alongside the screen, timed on the host clock so it
/// lines up with the screen capture, and feeds the floating preview bubble.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let url: URL
    private let queue = DispatchQueue(label: "capture.camera", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstHostTime: Double?
    private var recording = false

    init(url: URL, deviceID: String?) throws {
        self.url = url
        super.init()
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw ExportError.failed("No camera found") }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ExportError.failed("Camera unavailable") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw ExportError.failed("Camera unavailable") }
        session.addOutput(output)
        session.commitConfiguration()
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Starts the camera (for the preview) without writing.
    func startPreview() {
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func startRecording() {
        queue.async { self.recording = true }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buf: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(buf)
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(buf) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dims.width, AVVideoHeightKey: dims.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Double(dims.width * dims.height) * 30 * 0.25,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1,
                ],
            ])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            guard w.startWriting() else { return }
            // Session time is the original sample time; the host-clock start is kept for alignment.
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buf))
            writer = w; input = i
            firstHostTime = pts.seconds
        }
        if let input, input.isReadyForMoreMediaData { input.append(buf) }
    }

    func stop() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                self.recording = false
                self.session.stopRunning()
                cont.resume()
            }
        }
        guard let writer, let input else { return false }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}

/// A draggable circular webcam preview shown while recording. It belongs to Capture Pro, so
/// it's excluded from the screen capture — the camera is composited later, where you choose.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?

    func show(session: AVCaptureSession) {
        let size = 180.0
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: screen.maxX - size - 28, y: screen.minY + 28, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer?.addSublayer(preview)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
