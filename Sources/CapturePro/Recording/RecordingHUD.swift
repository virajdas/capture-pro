import AppKit
import SwiftUI

/// A calm 3-2-1 countdown in the middle of the capture area.
@MainActor
enum Countdown {
    static func run(seconds: Int, over rect: NSRect) async -> Bool {
        guard seconds > 0 else { return true }
        let size = NSSize(width: 140, height: 140)
        let panel = NSPanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let model = CountdownModel(value: seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()

        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { cancelled = true }
        }
        for v in stride(from: seconds, through: 1, by: -1) {
            model.value = v
            try? await Task.sleep(for: .seconds(1))
            if cancelled { break }
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        panel.orderOut(nil)
        // Let the panel disappear before the first frame is captured.
        try? await Task.sleep(for: .milliseconds(120))
        return !cancelled
    }
}

@Observable
private final class CountdownModel {
    var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    let model: CountdownModel
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
            Text("\(model.value)")
                .font(.system(size: 64, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.value)
        }
        .padding(10)
        .environment(\.colorScheme, .dark)
    }
}

/// A thin frame marking the area being recorded. Our own windows are excluded from capture.
@MainActor
final class AreaFrame {
    private var panel: NSPanel?

    func show(_ rect: NSRect) {
        let r = rect.insetBy(dx: -4, dy: -4)
        let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color.red.opacity(0.7)))
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
