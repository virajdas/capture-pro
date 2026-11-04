import AppKit

/// Shows the Dock icon while any document window (recording editor, screenshot editor,
/// onboarding) is open, and returns to a pure menu bar app when the last one closes.
@MainActor
enum AppWindows {
    private static var count = 0

    static func opened() {
        count += 1
        if count == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
