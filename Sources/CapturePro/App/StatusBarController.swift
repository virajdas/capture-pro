import AppKit
import Observation

/// The menu bar item: the whole app lives here.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private let recording = RecordingController.shared

    override init() {
        super.init()
        if let button = item.button {
            button.image = Self.glyph()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Capture Pro"
        }
        observeRecording()
    }

    private func observeRecording() {
        withObservationTracking {
            _ = recording.phase
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.refreshAppearance()
                self?.observeRecording()
            }
        }
    }

    private func refreshAppearance() {
        guard let button = item.button else { return }
        switch recording.phase {
        case .recording:
            button.image = Self.recordingGlyph()
            button.contentTintColor = .systemRed
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateElapsed() }
            }
            updateElapsed()
        case .finishing:
            timer?.invalidate()
            button.title = " Saving…"
        default:
            timer?.invalidate()
            timer = nil
            button.title = ""
            button.contentTintColor = nil
            button.image = Self.glyph()
        }
    }

    private func updateElapsed() {
        guard let start = recording.startedAt else { return }
        let s = Int(Date().timeIntervalSince(start))
        item.button?.attributedTitle = NSAttributedString(
            string: String(format: " %d:%02d", s / 60, s % 60),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if recording.phase == .recording {
            Task { await recording.stop() }
            return
        }
        let right = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        switch (right, Preferences.shared.stored.menuClick) {
        case (false, .area): Actions.captureArea()
        case (false, .record): Actions.recordArea()
        default: showMenu()
        }
    }

    private func showMenu() {
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let keys = Preferences.shared.stored.shortcuts

        menu.addItem(header("Screenshot"))
        menu.addItem(entry("Capture Area", "viewfinder", keys[.captureArea]) { Actions.captureArea() })
        menu.addItem(entry("Capture Window", "macwindow", keys[.captureWindow]) { Actions.captureWindow() })
        menu.addItem(entry("Capture Screen", "display", keys[.captureScreen]) { Actions.captureScreen() })
        menu.addItem(.separator())
        menu.addItem(header("Record"))
        menu.addItem(entry("Record Area or Window…", "record.circle", keys[.record]) { Actions.recordArea() })
        menu.addItem(entry("Record Full Screen", "rectangle.inset.filled.badge.record", nil) { Actions.recordScreen() })
        let sys = entry("System Audio", "speaker.wave.2", nil) { Preferences.shared.stored.systemAudio.toggle() }
        sys.state = Preferences.shared.stored.systemAudio ? .on : .off
        sys.indentationLevel = 1
        menu.addItem(sys)
        let mic = entry("Microphone", "mic", nil) { Preferences.shared.stored.microphone.toggle() }
        mic.state = Preferences.shared.stored.microphone ? .on : .off
        mic.indentationLevel = 1
        menu.addItem(mic)
        let cam = entry("Camera", "video", nil) { Preferences.shared.stored.camera.toggle() }
        cam.state = Preferences.shared.stored.camera ? .on : .off
        cam.indentationLevel = 1
        menu.addItem(cam)
        menu.addItem(.separator())

        let beautify = entry("Beautify Screenshots", "sparkles", nil) {
            Preferences.shared.stored.beautifyScreenshots.toggle()
        }
        beautify.state = Preferences.shared.stored.beautifyScreenshots ? .on : .off
        menu.addItem(beautify)

        let recent = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu()
        let projects = RecordingProject.list(in: Preferences.shared.recordingFolderURL).prefix(8)
        if projects.isEmpty {
            let none = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for url in projects {
            sub.addItem(entry(url.deletingPathExtension().lastPathComponent, nil, nil) {
                if let p = try? RecordingProject.load(url) { EditorWindowController.open(p) }
            })
        }
        sub.addItem(.separator())
        sub.addItem(entry("Show in Finder", nil, nil) {
            NSWorkspace.shared.open(Preferences.shared.recordingFolderURL)
        })
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(entry("Open Screenshots Folder", "folder", nil) {
            NSWorkspace.shared.open(Preferences.shared.screenshotFolderURL)
        })
        menu.addItem(.separator())
        menu.addItem(entry("Welcome Tour…", "hand.wave", nil) { OnboardingWindowController.show() })
        let settings = entry("Settings…", "gearshape", nil) { SettingsWindowController.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = entry("Quit Capture Pro", nil, nil) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func entry(_ title: String, _ symbol: String?, _ shortcut: Shortcut?, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let shortcut {
            let attr = NSMutableAttributedString(string: title)
            attr.append(NSAttributedString(string: "\t" + shortcut.display, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.menuFont(ofSize: 0),
            ]))
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
            attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
            i.attributedTitle = attr
        }
        return i
    }

    /// A minimal aperture: a rounded frame with a soft dot — drawn, so it's crisp at any scale.
    static func glyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let frame = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 3), xRadius: 4, yRadius: 4)
            frame.lineWidth = 1.6
            NSColor.black.setStroke()
            frame.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 2.6, y: r.midY - 2.6, width: 5.2, height: 5.2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func recordingGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.midX - 5, y: r.midY - 5, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Top-level user actions shared by the menu and global shortcuts.
@MainActor
enum Actions {
    static func captureArea() { Task { await ScreenshotService.capture(start: .area) } }
    static func captureWindow() { Task { await ScreenshotService.capture(start: .window) } }
    static func captureScreen() { Task { await ScreenshotService.capture(start: nil) } }
    static func recordArea() { Task { await RecordingController.shared.start(start: .area) } }
    static func recordScreen() { Task { await RecordingController.shared.start(start: nil) } }

    static func toggleRecording() {
        if RecordingController.shared.phase == .recording {
            Task { await RecordingController.shared.stop() }
        } else {
            recordArea()
        }
    }

    static func registerHotKeys() {
        let s = Preferences.shared.stored.shortcuts
        var bindings: [(Shortcut, () -> Void)] = []
        if let k = s[.captureArea] { bindings.append((k, captureArea)) }
        if let k = s[.captureWindow] { bindings.append((k, captureWindow)) }
        if let k = s[.captureScreen] { bindings.append((k, captureScreen)) }
        if let k = s[.record] { bindings.append((k, toggleRecording)) }
        HotKeys.shared.register(bindings)
    }
}
