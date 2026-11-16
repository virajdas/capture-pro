import AppKit
import ScreenCaptureKit
import SwiftUI

/// Scrolling screenshots: pick an area, scroll (or let Capture Pro scroll), and the frames are
/// stitched into one tall image that then goes through the normal screenshot flow.
@MainActor
@Observable
final class ScrollCapture: NSObject {
    static private(set) var current: ScrollCapture?

    enum Status: Equatable { case waiting, capturing, slowDown, full, finishing }

    private(set) var status: Status = .waiting
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var autoScrolling = false

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: FrameOutput?
    /// Only used on the frame queue while capturing, then read once on finish after it drains.
    @ObservationIgnored nonisolated(unsafe) private let stitcher: ScrollStitcher
    @ObservationIgnored private let frame = AreaFrame()
    @ObservationIgnored private var bar: NSPanel?
    @ObservationIgnored private var scrollTimer: Timer?
    @ObservationIgnored private var stillFrames = 0
    @ObservationIgnored private var keyMonitors: [Any] = []
    private let globalRect: CGRect

    static func start() async {
        guard current == nil else { return }
        guard await Permissions.ensureScreenRecording() else {
            Permissions.showScreenRecordingHelp()
            return
        }
        guard let target = await SelectionController(purpose: .screenshot).run(start: .area),
              let (display, rect) = await area(for: target) else { return }
        let session = ScrollCapture(display: display, rect: rect)
        current = session
        await session.begin(display: display, rect: rect)
    }

    /// Every target becomes an area on one display (a window is captured where it sits on screen).
    private static func area(for target: CaptureTarget) async -> (SCDisplay, CGRect)? {
        switch target {
        case .area(let d, let r): return (d, r)
        case .display(let d): return (d, CGRect(origin: .zero, size: d.frame.size))
        case .window(let w):
            guard let content = try? await SCShareableContent.current,
                  let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) })
            else { return nil }
            let r = w.frame.intersection(d.frame).offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
            return (d, r.integral)
        }
    }

    private init(display: SCDisplay, rect: CGRect) {
        globalRect = rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        let scale = CaptureTarget.scale(for: display)
        let rowBytes = Int(rect.width * scale) * 4
        // Keep the stitched image within ~320 MB and a height every app can open.
        stitcher = ScrollStitcher(maxHeight: min(30_000, 320_000_000 / max(rowBytes, 1)))
        super.init()
    }

    private func begin(display: SCDisplay, rect: CGRect) async {
        let cocoa = SelectionController.cocoaRect(globalRect)
        frame.show(cocoa, color: .accentColor)
        showBar(below: cocoa)
        installKeys()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = CaptureTarget.scale(for: display)
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.displayP3
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.queueDepth = 3
            pixelWidth = config.width
            let out = FrameOutput { [weak self] f in self?.process(f) }
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: out.queue)
            try await s.startCapture()
            stream = s
            output = out
        } catch {
            cancel()
            NSSound.beep()
        }
    }

    /// Runs on the frame queue; the stitcher is only touched there.
    nonisolated private func process(_ f: StitchFrame) {
        let outcome = stitcher.add(f)
        let height = stitcher.height
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pixelHeight = height
            switch outcome {
            case .started, .appended:
                self.status = .capturing
                self.stillFrames = 0
            case .unchanged, .scrolledBack:
                self.stillFrames += 1
                if self.status == .slowDown { self.status = .capturing }
                // Auto-scroll has reached the end of the page.
                if self.autoScrolling, self.stillFrames > 18 { self.finish() }
            case .lost:
                self.status = .slowDown
            case .full:
                self.status = .full
                self.stopAutoScroll()
            }
        }
    }

    // MARK: Controls

    func toggleAutoScroll() {
        if autoScrolling { stopAutoScroll(); return }
        guard Permissions.accessibility else {
            Permissions.requestAccessibility()
            return
        }
        autoScrolling = true
        stillFrames = 0
        let point = CGPoint(x: globalRect.midX, y: globalRect.midY)
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            // Scroll in small pixel steps at the centre of the area, slow enough to always overlap.
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -14, wheel2: 0, wheel3: 0) {
                e.location = point
                e.post(tap: .cghidEventTap)
            }
        }
    }

    private func stopAutoScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        autoScrolling = false
    }

    func finish() {
        guard status != .finishing else { return }
        status = .finishing
        stopAutoScroll()
        Task {
            try? await stream?.stopCapture()
            // Let the frame queue drain before reading the result.
            await withCheckedContinuation { c in output?.queue.async { c.resume() } ?? c.resume() }
            let image = stitcher.image()
            tearDown()
            if let image {
                await ScreenshotService.deliver(image, isWindow: false)
            } else {
                NSSound.beep()
            }
        }
    }

    func cancel() {
        stopAutoScroll()
        Task { try? await stream?.stopCapture() }
        tearDown()
    }

    private func tearDown() {
        frame.hide()
        bar?.orderOut(nil)
        bar = nil
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        stream = nil
        Self.current = nil
    }

    private func installKeys() {
        let handler: (NSEvent) -> Bool = { [weak self] e in
            guard let self else { return false }
            switch e.keyCode {
            case 53: self.cancel(); return true          // Esc
            case 36, 76: self.finish(); return true      // Return / Enter
            default: return false
            }
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) { keyMonitors.append(m) }
        // Works while you're scrolling in another app when Accessibility is allowed.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) { keyMonitors.append(m) }
    }

    private func showBar(below area: NSRect) {
        let size = NSSize(width: 460, height: 56)
        let screen = NSScreen.screens.first { $0.frame.intersects(area) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 14)
        if origin.y < screen.minY + 8 { origin.y = min(area.maxY + 14, screen.maxY - size.height - 8) }
        if origin.y + size.height > screen.maxY { origin.y = area.minY + 20 }
        origin.x = Double(origin.x).clamped(screen.minX + 8, screen.maxX - size.width - 8)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = ScrollBarHostingView(rootView: ScrollCaptureBar(session: self))
        p.orderFrontRegardless()
        bar = p
    }
}

private final class FrameOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "capture.scroll", qos: .userInitiated)
    private let handler: (StitchFrame) -> Void

    init(handler: @escaping (StitchFrame) -> Void) { self.handler = handler }

    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buf.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(buf) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px)
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        handler(StitchFrame(width: CVPixelBufferGetWidth(px), height: h, bytesPerRow: bpr,
                            data: Data(bytes: base, count: bpr * h)))
    }
}

private final class ScrollBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ScrollCaptureBar: View {
    let session: ScrollCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(session.status == .slowDown ? .orange : .secondary)
                .symbolEffect(.pulse, isActive: session.status == .waiting || session.autoScrolling)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(message).font(.callout.weight(.medium))
                Text(session.pixelHeight > 0 ? "\(session.pixelWidth) × \(session.pixelHeight) px" : "Esc to cancel · Return when done")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                session.toggleAutoScroll()
            } label: {
                Label(session.autoScrolling ? "Stop" : "Auto-scroll",
                      systemImage: session.autoScrolling ? "pause.fill" : "arrow.down.to.line")
            }
            .help(Permissions.accessibility ? "Let Capture Pro scroll for you" : "Needs Accessibility permission to scroll for you")
            Button("Cancel") { session.cancel() }
            Button("Done") { session.finish() }
                .buttonStyle(.borderedProminent)
                .disabled(session.pixelHeight == 0)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: session.status)
    }

    private var icon: String {
        switch session.status {
        case .waiting: "computermouse"
        case .capturing: "arrow.down"
        case .slowDown: "tortoise"
        case .full: "checkmark.circle"
        case .finishing: "hourglass"
        }
    }

    private var message: String {
        switch session.status {
        case .waiting: "Scroll to capture"
        case .capturing: session.autoScrolling ? "Scrolling…" : "Keep scrolling"
        case .slowDown: "A little slower"
        case .full: "That's as tall as it gets"
        case .finishing: "Stitching…"
        }
    }
}
