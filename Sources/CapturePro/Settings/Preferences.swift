import AppKit
import Observation
import ServiceManagement

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
}

enum AfterRecording: String, Codable, CaseIterable, Identifiable {
    case editor, export, reveal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: "Open the editor"
        case .export: "Export with my default style"
        case .reveal: "Just save the project"
        }
    }
}

enum AfterScreenshot: String, Codable, CaseIterable, Identifiable {
    case editor, preview, nothing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: "Open the editor"
        case .preview: "Show a floating preview"
        case .nothing: "Nothing"
        }
    }
}

enum MenuClickAction: String, Codable, CaseIterable, Identifiable {
    case menu, area, record
    var id: String { rawValue }
    var label: String {
        switch self {
        case .menu: "Show menu"
        case .area: "Capture area"
        case .record: "Start recording"
        }
    }
}

struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, …).
    var modifiers: UInt32
}

enum HotKeyAction: String, Codable, CaseIterable, Identifiable {
    case captureArea, captureWindow, captureScreen, record
    var id: String { rawValue }
    var label: String {
        switch self {
        case .captureArea: "Capture area"
        case .captureWindow: "Capture window"
        case .captureScreen: "Capture screen"
        case .record: "Start / stop recording"
        }
    }
}

/// App-wide settings, persisted to UserDefaults as JSON.
@Observable
final class Preferences {
    static let shared = Preferences()

    struct Stored: Codable {
        /// Bumped when defaults change; older saves get the new defaults for those settings.
        var schema = Stored.currentSchema
        static let currentSchema = 2
        // General
        var menuClick: MenuClickAction = .menu
        var playSounds = true
        var shortcuts: [HotKeyAction: Shortcut] = [
            .captureArea: Shortcut(keyCode: 18, modifiers: 0x0800 | 0x0200),   // ⌥⇧1
            .captureWindow: Shortcut(keyCode: 19, modifiers: 0x0800 | 0x0200), // ⌥⇧2
            .captureScreen: Shortcut(keyCode: 20, modifiers: 0x0800 | 0x0200), // ⌥⇧3
            .record: Shortcut(keyCode: 23, modifiers: 0x0800 | 0x0200),        // ⌥⇧5
        ]
        // Screenshots
        var screenshotFolder: String = Stored.defaultFolder(.picturesDirectory)
        var saveScreenshots = false
        var copyScreenshots = true
        var afterScreenshot: AfterScreenshot = .editor
        var showPreview = true
        var previewSeconds: Double = 6
        var imageFormat: ImageFormat = .png
        var beautifyScreenshots = false
        var windowShadow = true
        var screenshotCursor = false
        // Recording
        var recordingFolder: String = Stored.defaultFolder(.moviesDirectory)
        var fps = 60
        var countdown = 3
        var systemAudio = false
        var microphone = false
        var microphoneID: String? = nil
        var camera = false
        var cameraID: String? = nil
        /// Show the floating webcam bubble while recording (the camera records either way).
        var showCameraPreview = true
        var hideSystemCursor = true
        var afterRecording: AfterRecording = .editor
        var exportFolder: String = Stored.defaultFolder(.moviesDirectory)
        var askWhereToExport = false
        var revealAfterExport = true
        // Look
        var style = StyleSettings()
        var export = ExportSettings()

        static func defaultFolder(_ dir: FileManager.SearchPathDirectory) -> String {
            let base = FileManager.default.urls(for: dir, in: .userDomainMask).first!
            return base.appendingPathComponent("Capture Pro", isDirectory: true).path
        }
    }

    var stored: Stored {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "settings") {
            let old = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schema"] as? Int ?? 1
            // Version 2 changed these defaults; reset them once for existing users.
            let reset: [[String]] = old < 2
                ? [["saveScreenshots"], ["copyScreenshots"], ["showPreview"], ["style", "zoom"]]
                : []
            var s = Resilient.decode(Stored.self, from: data, defaults: Stored(), dropping: reset) ?? Stored()
            s.schema = Stored.currentSchema
            stored = s
        } else {
            stored = Stored()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }

    func reset() { stored = Stored() }

    var style: StyleSettings { stored.style }
    var export: ExportSettings { stored.export }

    var screenshotFolderURL: URL { Self.ensure(stored.screenshotFolder) }
    var recordingFolderURL: URL { Self.ensure(stored.recordingFolder) }
    var exportFolderURL: URL { Self.ensure(stored.exportFolder) }

    private static func ensure(_ path: String) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

extension Notification.Name {
    static let preferencesChanged = Notification.Name("CaptureProPreferencesChanged")
}
