import AppKit
import ScreenCaptureKit

enum SelectionPurpose { case screenshot, recording }
enum SelectionStart { case area, window }

/// Full-screen overlay to choose an area, window or display. Drag for an area, Space toggles
/// window picking, a plain click takes the whole display, Esc cancels.
@MainActor
final class SelectionController {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?
    private var content: SCShareableContent?
    fileprivate var windowMode = false
    fileprivate var hoveredWindow: SCWindow?
    fileprivate var orderedWindows: [SCWindow] = []
    fileprivate let purpose: SelectionPurpose
    private var keyMonitor: Any?

    init(purpose: SelectionPurpose) { self.purpose = purpose }

    func run(start: SelectionStart) async -> CaptureTarget? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            Permissions.showScreenRecordingHelp()
            return nil
        }
        self.content = content
        orderedWindows = Self.frontToBack(content.windows)
        windowMode = start == .window

        return await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let w = OverlayWindow(screen: screen, controller: self)
                windows.append(w)
                w.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            let mouse = NSEvent.mouseLocation
            (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                if e.keyCode == 53 { self.finish(nil); return nil }
                if e.keyCode == 49 { self.toggleWindowMode(); return nil }
                return e
            }
            updateHover()
        }
    }

    fileprivate func toggleWindowMode() {
        windowMode.toggle()
        updateHover()
    }

    fileprivate func updateHover() {
        let p = Self.cgPoint(NSEvent.mouseLocation)
        hoveredWindow = windowMode ? orderedWindows.first { $0.frame.contains(p) } : nil
        windows.forEach { $0.overlay.needsDisplay = true }
    }

    fileprivate func finish(_ target: CaptureTarget?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let c = continuation
        continuation = nil
        // Give the window server a beat to remove the overlay before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { c?.resume(returning: target) }
    }

    fileprivate func display(for screen: NSScreen) -> SCDisplay? {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return content?.displays.first { $0.displayID == id }
    }

    fileprivate func complete(screen: NSScreen, rect: NSRect?) {
        if windowMode {
            finish(hoveredWindow.map { .window($0) })
            return
        }
        guard let display = display(for: screen) else { finish(nil); return }
        if let rect, rect.width >= 4, rect.height >= 4 {
            let local = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
            finish(.area(display, local.integral))
        } else {
            finish(.display(display))
        }
    }

    /// Cocoa global (bottom-left) → CoreGraphics global (top-left).
    static func cgPoint(_ p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    static func cocoaRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func frontToBack(_ windows: [SCWindow]) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
                && $0.owningApplication?.processID != me && rank[$0.windowID] != nil }
            .sorted { rank[$0.windowID]! < rank[$1.windowID]! }
    }
}

private final class OverlayWindow: NSPanel {
    let overlay: OverlayView

    init(screen: NSScreen, controller: SelectionController) {
        overlay = OverlayView(screen: screen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlay
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    let screen: NSScreen
    unowned let controller: SelectionController
    private var dragStart: NSPoint?
    private var dragRect: NSRect?

    init(screen: NSScreen, controller: SelectionController) {
        self.screen = screen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller.updateHover()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, !controller.windowMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        var r = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(r.width, r.height)
            r.size = NSSize(width: side, height: side)
            if p.x < s.x { r.origin.x = s.x - side }
            if p.y < s.y { r.origin.y = s.y - side }
        }
        dragRect = r.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        controller.complete(screen: screen, rect: dragRect)
        dragStart = nil
        dragRect = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(controller.purpose == .recording ? 0.35 : 0.25)
        dim.setFill()
        bounds.fill()

        var hole: NSRect?
        if controller.windowMode, let w = controller.hoveredWindow {
            let global = SelectionController.cocoaRect(w.frame)
            hole = NSRect(x: global.minX - screen.frame.minX, y: global.minY - screen.frame.minY,
                          width: global.width, height: global.height)
        } else if let r = dragRect {
            hole = r
        }

        if let hole {
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: hole, xRadius: controller.windowMode ? 10 : 0, yRadius: controller.windowMode ? 10 : 0).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            if controller.windowMode {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10).fill()
            }
            let border = NSBezierPath(roundedRect: hole.insetBy(dx: -0.5, dy: -0.5),
                                      xRadius: controller.windowMode ? 10 : 0, yRadius: controller.windowMode ? 10 : 0)
            border.lineWidth = 1
            NSColor.white.withAlphaComponent(0.9).setStroke()
            border.stroke()
            if !controller.windowMode {
                drawPill("\(Int(hole.width)) × \(Int(hole.height))",
                         at: NSPoint(x: hole.midX, y: max(hole.minY - 22, 18)))
            }
        }

        if screen.frame.contains(NSEvent.mouseLocation) || dragRect != nil {
            let verb = controller.purpose == .recording ? "record" : "capture"
            let hint = controller.windowMode
                ? "Click a window to \(verb)   ·   Space for area   ·   Esc to cancel"
                : "Drag to \(verb) an area   ·   Click for full screen   ·   Space for window   ·   Esc"
            drawPill(hint, at: NSPoint(x: bounds.midX, y: bounds.maxY - 64), large: true)
        }
    }

    private func drawPill(_ text: String, at center: NSPoint, large: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: large ? 13 : 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let r = NSRect(x: center.x - size.width / 2 - 12, y: center.y - size.height / 2 - 6,
                       width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: NSPoint(x: r.minX + 12, y: r.minY + 6))
    }
}
