import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var open: [URL: EditorWindowController] = [:]
    private let window: NSWindow
    private let model: EditorModel

    static func open(_ project: RecordingProject) {
        if let existing = open[project.url] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = EditorWindowController(project: project)
        open[project.url] = c
        AppWindows.opened()
        c.window.makeKeyAndOrderFront(nil)
    }

    private init(project: RecordingProject) {
        model = EditorModel(project: project)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = project.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("CaptureProEditor")
    }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        Self.open[model.project.url] = nil
        AppWindows.closed()
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case looks = "Looks", background = "Background", frame = "Frame", cursor = "Cursor", camera = "Zoom", webcam = "Webcam", audio = "Audio"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .looks: "sparkles"
        case .audio: "speaker.wave.2"
        case .webcam: "person.crop.circle"
        case .background: "paintpalette"
        case .frame: "square.on.square"
        case .cursor: "cursorarrow.motionlines"
        case .camera: "plus.magnifyingglass"
        }
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var tab: InspectorTab = .looks
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PlayerSurface(player: model.player)
                        .overlay { CameraDragOverlay(model: model) }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                }
                Divider()
                inspector.frame(width: 320)
            }
            Divider()
            EditorTimeline(model: model)
                .frame(height: 132)
        }
        .background(.background)
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 64)
            Text(model.project.name).font(.headline).lineLimit(1)
            Spacer()
            Menu {
                Button("Save as Default Look") { model.saveAsDefaultLook() }
                Button("Reset Zoom to Automatic") { model.regenerateSegments() }
                Button("Turn All Zooms On") { model.setAllSegments(enabled: true) }
                Button("Turn All Zooms Off") { model.setAllSegments(enabled: false) }
                Divider()
                Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.project.url]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            Text("\(format(model.currentTime)) / \(format(model.trimEnd - model.trimStart))")
                .font(.system(.callout, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 14)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { t in
                    Image(systemName: t.symbol).help(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Form {
                switch tab {
                case .looks:
                    Section("Looks") { PresetGallery(style: $model.style) }
                case .audio:
                    AudioControls(model: model)
                case .webcam:
                    WebcamControls(model: model)
                case .background:
                    Section("Background") { BackgroundControls(style: $model.style.background) }
                case .frame:
                    Section("Frame") { FrameControls(style: $model.style.frame) }
                case .cursor:
                    Section("Cursor") { CursorControls(style: $model.style.cursor) }
                case .camera:
                    if let id = model.selectedSegment, let seg = model.segments.first(where: { $0.id == id }) {
                        Section("Selected zoom") {
                            Toggle("Zoom enabled", isOn: Binding(
                                get: { seg.enabled },
                                set: { v in model.updateSegment(id) { $0.enabled = v } }))
                            LabeledSlider("Zoom", value: Binding(
                                get: { seg.scale },
                                set: { v in model.updateSegment(id) { $0.scale = v } }), in: 1.1...4, format: "%.1f×")
                            Toggle("Follow cursor", isOn: Binding(
                                get: { seg.focusX == nil },
                                set: { follow in
                                    model.updateSegment(id) {
                                        if follow { $0.focusX = nil; $0.focusY = nil }
                                        else {
                                            let c = model.project.input.clicks.first { $0.t >= seg.start && $0.t <= seg.end }
                                            $0.focusX = c?.x ?? 0.5; $0.focusY = c?.y ?? 0.5
                                        }
                                    }
                                }))
                            if seg.focusX != nil {
                                LabeledSlider("Focus X", value: Binding(get: { seg.focusX ?? 0.5 },
                                    set: { v in model.updateSegment(id) { $0.focusX = v } }), in: 0...1, format: "%.0f%%", scale: 100)
                                LabeledSlider("Focus Y", value: Binding(get: { seg.focusY ?? 0.5 },
                                    set: { v in model.updateSegment(id) { $0.focusY = v } }), in: 0...1, format: "%.0f%%", scale: 100)
                            }
                            Button("Remove This Zoom", role: .destructive) { model.deleteSegment(id) }
                        }
                    }
                    Section("Zoom") { ZoomControls(style: $model.style.zoom) }
                    Section {
                        Text("Double-click the zoom track to add a zoom. Drag zooms to move them, drag their edges to resize, and use the eye to switch a zoom on or off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .background(.regularMaterial)
    }

    private func format(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int(s * 10) % 10)
    }
}

struct AudioControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        let info = model.project.info
        if !info.hasSystemAudio && !info.hasMicrophone {
            Section("Audio") {
                Text("This recording has no audio. System audio and microphone can be turned on for new recordings in the menu bar or Settings › Recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Section("Audio") {
                if info.hasSystemAudio {
                    volume("System audio", symbol: "speaker.wave.2", value: $model.systemVolume)
                }
                if info.hasMicrophone {
                    volume("Microphone", symbol: "mic", value: $model.microphoneVolume)
                }
            }
        }
    }

    private func volume(_ title: String, symbol: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Button {
                value.wrappedValue = value.wrappedValue > 0 ? 0 : 1
            } label: {
                Image(systemName: value.wrappedValue > 0 ? symbol : symbol + ".slash")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(value.wrappedValue > 0 ? "Mute" : "Unmute")
            LabeledSlider(title, value: value, in: 0...2, format: "%.0f%%", scale: 100)
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    /// A bare player layer: no controls and no black letterbox, so the canvas floats on the window.
    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: LayerView, context: Context) {}
}

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Bindable var prefs = Preferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            if let p = model.exportProgress {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: p)
                    HStack {
                        Text("Rendering… \(Int(p * 100))%").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Cancel") { model.cancelExport() }
                    }
                }
            } else if let url = model.exportResult {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy File") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    }
                    Spacer()
                    Button("Done") { model.exportResult = nil; dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    ExportControls(settings: $model.export)
                    Section {
                        LabeledContent("Save to") { FolderPicker(path: $prefs.stored.exportFolder) }
                        Toggle("Ask where to save each time", isOn: $prefs.stored.askWhereToExport)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 330)
                if let e = model.exportError {
                    Text(e).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(prefs.stored.askWhereToExport ? "Export…" : "Export") { choose() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func choose() {
        let ext = model.export.format == .gif ? "gif" : model.export.format.rawValue
        let folder = Preferences.shared.exportFolderURL
        guard prefs.stored.askWhereToExport else {
            model.startExport(to: Self.uniqueURL(in: folder, name: model.project.name, ext: ext))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .movie]
        panel.nameFieldStringValue = model.project.name + "." + ext
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            model.startExport(to: url)
        }
    }

    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
