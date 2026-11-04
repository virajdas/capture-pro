import AppKit
import Carbon.HIToolbox
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
        menu.addItem(ToggleMenuRow.item("System Audio", symbol: "speaker.wave.2", key: \.systemAudio))
        menu.addItem(ToggleMenuRow.item("Microphone", symbol: "mic", key: \.microphone))
        menu.addItem(ToggleMenuRow.item("Camera", symbol: "video", key: \.camera))
        menu.addItem(.separator())
        menu.addItem(ToggleMenuRow.item("Beautify Screenshots", symbol: "sparkles", key: \.beautifyScreenshots))

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
            // Shown in the menu's own shortcut column, which sizes itself to the content.
            let name = Shortcut.keyName(shortcut.keyCode)
            if name.count == 1 {
                i.keyEquivalent = name.lowercased()
                var mask: NSEvent.ModifierFlags = []
                if shortcut.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
                if shortcut.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
                if shortcut.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
                if shortcut.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
                i.keyEquivalentModifierMask = mask
            } else {
                i.toolTip = shortcut.display
            }
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

/// A menu row with a switch. Clicking it flips the setting in place — the menu stays open,
/// so several options can be set in one go.
final class ToggleMenuRow: NSView {
    private let key: WritableKeyPath<Preferences.Stored, Bool>
    private let toggle = NSSwitch()
    private var hovering = false { didSet { needsDisplay = true } }

    static func item(_ title: String, symbol: String, key: WritableKeyPath<Preferences.Stored, Bool>) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ToggleMenuRow(title: title, symbol: symbol, key: key)
        return item
    }

    init(title: String, symbol: String, key: WritableKeyPath<Preferences.Stored, Bool>) {
        self.key = key
        // Narrow by default; the menu stretches the row to its own width.
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        autoresizingMask = [.width]
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        toggle.controlSize = .mini
        toggle.state = Preferences.shared.stored[keyPath: key] ? .on : .off
        toggle.target = self
        toggle.action = #selector(switched)
        for v in [icon, label, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Clicking anywhere on the row flips the switch.
    override func mouseUp(with event: NSEvent) {
        toggle.state = toggle.state == .on ? .off : .on
        switched()
    }

    @objc private func switched() {
        Preferences.shared.stored[keyPath: key] = toggle.state == .on
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
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
