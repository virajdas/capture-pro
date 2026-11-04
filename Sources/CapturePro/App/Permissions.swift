import AppKit
import ApplicationServices
import ScreenCaptureKit

enum Permissions {
    /// Set once ScreenCaptureKit has actually answered, which is the ground truth.
    nonisolated(unsafe) private static var verified = false

    /// Quick check. `CGPreflightScreenCaptureAccess` can report "no" until the app relaunches
    /// even after access is granted, so a successful real query also counts.
    static var screenRecording: Bool { verified || CGPreflightScreenCaptureAccess() }

    /// Asks ScreenCaptureKit directly, without prompting.
    static func checkScreenRecording() async -> Bool {
        if screenRecording { return true }
        if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
            verified = true
        }
        return verified
    }

    /// Use before capturing: true if capture will work; otherwise prompts (first time) and returns false.
    static func ensureScreenRecording() async -> Bool {
        if await checkScreenRecording() { return true }
        _ = CGRequestScreenCaptureAccess()
        return await checkScreenRecording()
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @MainActor
    static func showScreenRecordingHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow screen recording"
        alert.informativeText = "Capture Pro needs Screen Recording access to take screenshots and recordings.\n\n"
            + "Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording. "
            + "If Capture Pro is already listed and switched on, select it, remove it with “–”, add it again with “+”, "
            + "then quit and reopen Capture Pro — macOS sometimes keeps a stale entry from an older copy of the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
