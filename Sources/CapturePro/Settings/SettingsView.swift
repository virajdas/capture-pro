import SwiftUI
import AVFoundation

@MainActor
final class SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Capture Pro Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ScreenshotPane().tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }.tag("shots")
            RecordingPane().tabItem { Label("Recording", systemImage: "record.circle") }.tag("rec")
            LookPane().tabItem { Label("Look", systemImage: "paintpalette") }.tag("look")
            ShortcutsPane().tabItem { Label("Shortcuts", systemImage: "command") }.tag("keys")
        }
        .padding(.top, 8)
        .frame(width: 640, height: 560)
    }
}

private struct GeneralPane: View {
    @Bindable var prefs = Preferences.shared
    @State private var launch = Preferences.shared.launchAtLogin
    @State private var screenOK = Permissions.screenRecording
    @State private var axOK = Permissions.accessibility
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(title: "Screen Recording", detail: "Required for screenshots and recordings.", granted: screenOK) {
                    if !Permissions.requestScreenRecording() { Permissions.openSettings("Privacy_ScreenCapture") }
                }
                PermissionRow(title: "Accessibility", detail: "Optional. Lets auto-zoom notice when you type (only timing is stored, never keys).",
                              granted: axOK) {
                    Permissions.requestAccessibility()
                }
            }
            Section("Save locations") {
                LabeledContent("Screenshots") { FolderPicker(path: $prefs.stored.screenshotFolder) }
                LabeledContent("Recording projects") { FolderPicker(path: $prefs.stored.recordingFolder) }
                LabeledContent("Exported videos") { FolderPicker(path: $prefs.stored.exportFolder) }
                Toggle("Ask where to save each export", isOn: $prefs.stored.askWhereToExport)
                Toggle("Show exports in Finder when done", isOn: $prefs.stored.revealAfterExport)
            }
            Section("Menu bar") {
                Picker("Clicking the icon", selection: $prefs.stored.menuClick) {
                    ForEach(MenuClickAction.allCases) { Text($0.label).tag($0) }
                }
                Text("Right-click always opens the menu. While recording, a click stops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launch)
                    .onChange(of: launch) { _, v in prefs.launchAtLogin = v }
                Toggle("Play sounds", isOn: $prefs.stored.playSounds)
            }
            Section {
                HStack {
                    Text("Capture Pro — calm, open-source capture for macOS.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { prefs.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in
            screenOK = Permissions.screenRecording
            axOK = Permissions.accessibility
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }
    }
}

private struct ScreenshotPane: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("After capturing") {
                Toggle("Copy to clipboard", isOn: $prefs.stored.copyScreenshots)
                Toggle("Also save to the screenshots folder", isOn: $prefs.stored.saveScreenshots)
                Picker("Then", selection: $prefs.stored.afterScreenshot) {
                    ForEach(AfterScreenshot.allCases) { Text($0.label).tag($0) }
                }
                if prefs.stored.afterScreenshot == .preview {
                    LabeledSlider("Preview stays for", value: $prefs.stored.previewSeconds, in: 2...20, format: "%.0f s")
                }
            }
            Section("Image") {
                Picker("Format", selection: $prefs.stored.imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Include the cursor", isOn: $prefs.stored.screenshotCursor)
                Toggle("Include window shadow", isOn: $prefs.stored.windowShadow)
                Toggle("Beautify with background", isOn: $prefs.stored.beautifyScreenshots)
                Text("Beautified screenshots use the background and frame from the Look tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingPane: View {
    @Bindable var prefs = Preferences.shared
    @State private var mics: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Frame rate", selection: $prefs.stored.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Countdown", selection: $prefs.stored.countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                Toggle("Replace cursor with a smooth one", isOn: $prefs.stored.hideSystemCursor)
                Text("Hides the real cursor while recording and draws a smoothed, enlarged one afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Toggle("Record system audio", isOn: $prefs.stored.systemAudio)
                Toggle("Record microphone", isOn: $prefs.stored.microphone)
                if prefs.stored.microphone {
                    Picker("Microphone", selection: $prefs.stored.microphoneID) {
                        Text("System default").tag(String?.none)
                        ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                }
            }
            Section("When a recording ends") {
                Picker("Then", selection: $prefs.stored.afterRecording) {
                    ForEach(AfterRecording.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Default export") {
                ExportControls(settings: $prefs.stored.export)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                    mediaType: .audio, position: .unspecified).devices
        }
    }
}

struct ExportControls: View {
    @Binding var settings: ExportSettings

    var body: some View {
        Picker("Format", selection: $settings.format) {
            ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
        }
        if settings.format == .gif {
            Picker("Width", selection: $settings.gifWidth) {
                ForEach([480, 640, 800, 960, 1280], id: \.self) { Text("\($0) px").tag($0) }
            }
            Picker("Frame rate", selection: $settings.gifFPS) {
                ForEach([10, 15, 20, 24], id: \.self) { Text("\($0) fps").tag($0) }
            }
        } else {
            Picker("Resolution", selection: $settings.resolution) {
                ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Frame rate", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Codec", selection: $settings.codec) {
                ForEach(ExportCodec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Quality", selection: $settings.quality) {
                ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }
}

private struct LookPane: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Text("Defaults for new recordings and beautified screenshots. Every recording can be tuned further in the editor.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Looks") { PresetGallery(style: $prefs.stored.style, columns: 4) }
            Section("Background") { BackgroundControls(style: $prefs.stored.style.background) }
            Section("Frame") { FrameControls(style: $prefs.stored.style.frame) }
            Section("Cursor") { CursorControls(style: $prefs.stored.style.cursor) }
            Section("Camera") { ZoomControls(style: $prefs.stored.style.zoom) }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsPane: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        ShortcutField(shortcut: Binding(
                            get: { prefs.stored.shortcuts[action] },
                            set: { prefs.stored.shortcuts[action] = $0 }))
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new key combination. Press ⌫ to clear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutField: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (shortcut?.display ?? "None"))
                .frame(minWidth: 110)
                .foregroundStyle(recording ? Color.accentColor : .primary)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 51 || e.keyCode == 117 { shortcut = nil; stop(); return nil }
            if e.keyCode == 53 { stop(); return nil }
            if let s = Shortcut(event: e) { shortcut = s; stop() }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Actions.registerHotKeys()
    }
}

struct FolderPicker: View {
    @Binding var path: String

    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer()
            Button("Change…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
        }
    }
}
