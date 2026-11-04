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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        if Self.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case background = "Background", frame = "Frame", cursor = "Cursor", camera = "Camera"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .background: "paintpalette"
        case .frame: "square.on.square"
        case .cursor: "cursorarrow.motionlines"
        case .camera: "plus.magnifyingglass"
        }
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var tab: InspectorTab = .background
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PlayerSurface(player: model.player)
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
                case .background:
                    Section("Background") { BackgroundControls(style: $model.style.background) }
                case .frame:
                    Section("Frame") { FrameControls(style: $model.style.frame) }
                case .cursor:
                    Section("Cursor") { CursorControls(style: $model.style.cursor) }
                case .camera:
                    if let id = model.selectedSegment, let seg = model.segments.first(where: { $0.id == id }) {
                        Section("Selected zoom") {
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
                    Section("Camera") { ZoomControls(style: $model.style.zoom) }
                    Section {
                        Text("Double-click the zoom track to add a zoom. Drag zooms to move them, or drag their edges to resize.")
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
                Form { ExportControls(settings: $model.export) }
                    .formStyle(.grouped)
                    .frame(height: 230)
                if let e = model.exportError {
                    Text(e).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export…") { choose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func choose() {
        let panel = NSSavePanel()
        let ext = model.export.format == .gif ? "gif" : model.export.format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .movie]
        panel.nameFieldStringValue = model.project.name + "." + ext
        panel.directoryURL = Preferences.shared.exportFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            model.startExport(to: url)
        }
    }
}
