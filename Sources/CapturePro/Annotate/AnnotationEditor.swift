import AppKit
import SwiftUI

/// Opens the screenshot annotation editor.
@MainActor
enum AnnotationEditor {
    /// `image` is the raw capture in pixels; `file` is where it was already saved, if anywhere.
    static func open(image: CGImage, file: URL?) {
        AnnotationWindowController.open(image: image, file: file)
    }
}

@MainActor
final class AnnotationWindowController: NSObject, NSWindowDelegate {
    private static var open: [ObjectIdentifier: AnnotationWindowController] = [:]
    let window: AnnotationWindow
    let doc: AnnotationDocument
    let canvas: AnnotationCanvasView

    static func open(image: CGImage, file: URL?) {
        let c = AnnotationWindowController(image: image, file: file)
        let offset = CGFloat(open.count) * 24
        open[ObjectIdentifier(c)] = c
        AppWindows.opened()
        if offset > 0 { c.window.setFrameOrigin(NSPoint(x: c.window.frame.minX + offset, y: c.window.frame.minY - offset)) }
        c.window.makeKeyAndOrderFront(nil)
        c.window.makeFirstResponder(c.canvas)
    }

    private init(image: CGImage, file: URL?) {
        doc = AnnotationDocument(image: image, file: file)
        canvas = AnnotationCanvasView(doc: doc)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1100, visible.width - 40), height: min(760, visible.height - 40))
        window = AnnotationWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init()
        window.title = doc.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives a 52 pt titlebar so the traffic lights line up with the header.
        window.toolbar = NSToolbar(identifier: "AnnotationEditor")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 700)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: AnnotationEditorView(doc: doc, canvas: canvas))
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.canvas.handleKey(event) ?? false }
        doc.window = window
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.endEditing()
        window.keyHandler = nil
        Self.open[ObjectIdentifier(self)] = nil
        AppWindows.closed()
    }
}

/// Routes key-downs through the canvas first, and never lets Esc fall through to anything else.
final class AnnotationWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

// MARK: - Chrome

struct AnnotationEditorView: View {
    @Bindable var doc: AnnotationDocument
    let canvas: AnnotationCanvasView

    var body: some View {
        ZStack {
            AnnotationCanvas(view: canvas)
            VStack(spacing: 0) {
                AnnotationHeader(doc: doc, canvas: canvas)
                Spacer(minLength: 0)
                PropertyBar(doc: doc, canvas: canvas)
                    .padding(.bottom, 22)
            }
            HStack {
                ToolPalette(doc: doc)
                    .padding(.leading, 16)
                    .padding(.top, 40)
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 700)
    }
}

private struct AnnotationHeader: View {
    @Bindable var doc: AnnotationDocument
    let canvas: AnnotationCanvasView
    @State private var showBeautify = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 72)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(Int(doc.cropRect.width)) × \(Int(doc.cropRect.height))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            HStack(spacing: 2) {
                HeaderIcon(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z") { doc.undo() }
                    .disabled(!doc.canUndo)
                HeaderIcon(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z") { doc.redo() }
                    .disabled(!doc.canRedo)
            }

            HStack(spacing: 0) {
                Toggle(isOn: $doc.beautify) {
                    Label("Beautify", systemImage: "sparkles")
                }
                .toggleStyle(.button)
                .help("Add a background, padding, rounded corners and a shadow")
                HeaderIcon(symbol: "chevron.down", help: "Beautify options", size: 10) { showBeautify.toggle() }
                    .popover(isPresented: $showBeautify, arrowEdge: .bottom) { BeautifyPopover(doc: doc) }
            }

            Divider().frame(height: 20)

            DragOutThumbnail(doc: doc)
            ShareButton(doc: doc)

            Menu {
                Button("Save As…") { doc.saveAs() }
                if let file = doc.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            } label: {
                Label(doc.flash == "Saved" ? "Saved" : "Save",
                      systemImage: doc.flash == "Saved" ? "checkmark" : "square.and.arrow.down")
            } primaryAction: {
                doc.save()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Save  ⌘S   ·   Save As  ⇧⌘S")

            Button {
                doc.copyToClipboard()
            } label: {
                Text(doc.flash == "Copied" ? "Copied ✓" : "Copy")
                    .frame(minWidth: 64)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.borderedProminent)
            .help("Copy to the clipboard  ⌘C")

            Button("Done") { canvas.done() }
                .help("Copy and close  ⌘↩")
        }
        .animation(.easeOut(duration: 0.18), value: doc.flash)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(doc.zoom > 1 ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
    }
}

private struct HeaderIcon: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary.opacity(0.8) : Color.primary.opacity(0.25))
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct BeautifyPopover: View {
    @Bindable var doc: AnnotationDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Beautify", isOn: $doc.beautify).toggleStyle(.switch).font(.headline)
            PaletteGrid(selection: Binding(get: { doc.beautifyStyle.background.paletteID },
                                           set: { id in
                                               doc.beautifyStyle.background.paletteID = id
                                               if ![.mesh, .linear].contains(doc.beautifyStyle.background.kind) {
                                                   doc.beautifyStyle.background.kind = .mesh
                                               }
                                               doc.beautify = true
                                           }),
                        custom: $doc.beautifyStyle.background.useCustomColors)
            LabeledSlider("Padding", value: $doc.beautifyStyle.frame.padding, in: 0.02...0.25, format: "%.0f%%", scale: 100)
            LabeledSlider("Corners", value: $doc.beautifyStyle.frame.cornerRadius, in: 0...48, format: "%.0f")
            LabeledSlider("Shadow", value: $doc.beautifyStyle.frame.shadowOpacity, in: 0...1, format: "%.0f%%", scale: 100)
            Text("Uses your default look from Settings; changes here apply to this screenshot only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct DragOutThumbnail: View {
    let doc: AnnotationDocument

    var body: some View {
        Image(nsImage: NSImage(cgImage: doc.display, size: .zero))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 34, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .onDrag {
                doc.exportTemporaryFile().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
            }
            .help("Drag the finished image into any app")
    }
}

private final class AnchorHolder {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let holder: AnchorHolder
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}

private struct ShareButton: View {
    let doc: AnnotationDocument
    @State private var anchor = AnchorHolder()

    var body: some View {
        HeaderIcon(symbol: "square.and.arrow.up", help: "Share") {
            guard let url = doc.exportTemporaryFile(), let v = anchor.view else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        }
        .background(AnchorView(holder: anchor))
    }
}

// MARK: - Tool palette

private struct ToolPalette: View {
    @Bindable var doc: AnnotationDocument

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AnnotationTool.groups.indices, id: \.self) { gi in
                if gi > 0 { Divider().frame(width: 20).padding(.vertical, 4) }
                ForEach(AnnotationTool.groups[gi]) { tool in
                    ToolButton(tool: tool, selected: doc.tool == tool) { doc.tool = tool }
                }
            }
        }
        .padding(6)
        .floatingPanel(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ToolButton: View {
    let tool: AnnotationTool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 29)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .help("\(tool.name)  (\(tool.key.uppercased()))")
    }
}

// MARK: - Property bar

private struct PropertyBar: View {
    @Bindable var doc: AnnotationDocument
    let canvas: AnnotationCanvasView

    var body: some View {
        HStack(spacing: 12) {
            if doc.tool == .crop {
                cropControls
            } else if let kind = doc.activeKind {
                controls(for: kind)
            } else {
                Text(doc.tool == .eraser ? "Click or drag across annotations to remove them"
                                         : "Choose a tool, or click an annotation to edit it")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .floatingPanel(Capsule(style: .continuous))
        .animation(.easeOut(duration: 0.15), value: doc.activeKind)
    }

    private var cropControls: some View {
        Group {
            Text(doc.pendingCrop == nil ? "Drag to choose an area" : "Drag the corners to adjust · ↩ to apply")
                .font(.callout).foregroundStyle(.secondary)
            Button("Reset") { doc.resetCrop() }.disabled(doc.crop == nil && doc.pendingCrop == nil)
            Button("Cancel") { doc.cancelCrop() }
            Button("Apply") { doc.applyCrop() }
                .buttonStyle(.borderedProminent)
                .disabled(doc.pendingCrop == nil)
        }
    }

    @ViewBuilder
    private func controls(for kind: AnnotationKind) -> some View {
        let p = doc.props
        if ![.blur, .pixelate, .redact, .spotlight].contains(kind) {
            ColorSwatches(color: doc.binding(\.color))
            BarDivider()
        }
        if kind == .arrow {
            HStack(spacing: 2) {
                ForEach(ArrowStyle.allCases) { s in
                    IconToggle(symbol: s.symbol, help: s.label,
                               isOn: Binding(get: { p.arrowStyle == s }, set: { if $0 { doc.binding(\.arrowStyle).wrappedValue = s } }))
                }
            }
        }
        if kind == .emoji {
            HStack(spacing: 1) {
                ForEach(AnnotationProps.emojis, id: \.self) { e in
                    Button { doc.binding(\.emoji).wrappedValue = e } label: {
                        Text(e).font(.system(size: 16))
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(p.emoji == e ? Color.accentColor.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            BarDivider()
        }
        if [.pen, .highlighter, .line, .arrow, .magnifier].contains(kind) || ([.rectangle, .ellipse].contains(kind) && !p.filled) {
            MiniSlider(symbol: "lineweight", help: "Stroke width", value: doc.binding(\.width), range: 1...16)
        }
        if kind == .rectangle || kind == .ellipse {
            IconToggle(symbol: kind == .ellipse ? "circle.fill" : "square.fill", help: "Filled", isOn: doc.binding(\.filled))
        }
        if kind == .rectangle || (kind == .spotlight && !p.oval) {
            IconToggle(symbol: "app", help: "Rounded corners", isOn: doc.binding(\.rounded))
        }
        if kind == .spotlight {
            IconToggle(symbol: "oval", help: "Oval spotlight", isOn: doc.binding(\.oval))
        }
        if [.text, .callout, .step, .emoji].contains(kind) {
            MiniSlider(symbol: "textformat.size", help: "Size", value: doc.binding(\.fontSize), range: 10...72)
        }
        if kind == .text || kind == .callout {
            IconToggle(symbol: "bold", help: "Bold", isOn: doc.binding(\.bold))
        }
        if kind == .text {
            IconToggle(symbol: "capsule.fill", help: "Background pill", isOn: doc.binding(\.pill))
        }
        if [.blur, .pixelate, .redact].contains(kind) {
            Text(kind == .redact ? "Covers the area with a solid box" : "Hides what's underneath")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            MiniSlider(symbol: kind == .spotlight ? "circle.lefthalf.filled" : "circle.dotted",
                       help: kind == .spotlight ? "Dimming" : "Opacity", value: doc.binding(\.opacity), range: 0.1...1)
        }
        if ![.highlighter, .blur, .pixelate, .redact, .spotlight].contains(kind) {
            IconToggle(symbol: "square.filled.on.square", help: "Drop shadow", isOn: doc.binding(\.shadow))
        }
        if doc.selection != nil {
            BarDivider()
            IconToggle(symbol: "plus.square.on.square", help: "Duplicate  ⌘D",
                       isOn: Binding(get: { false }, set: { _ in doc.duplicateSelection() }))
            IconToggle(symbol: "trash", help: "Delete  ⌫",
                       isOn: Binding(get: { false }, set: { _ in doc.deleteSelection() }))
        }
    }
}

private struct ColorSwatches: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationProps.swatches, id: \.self) { c in
                let selected = Self.close(c, color)
                Circle()
                    .fill(Color(rgba: c))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
                    .padding(2.5)
                    .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(Circle())
                    .onTapGesture { color = c }
            }
            ColorPicker("", selection: Binding(get: { Color(rgba: color) }, set: { color = RGBA($0) }), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 34)
                .help("Custom color")
        }
    }

    static func close(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }
}

private struct MiniSlider: View {
    let symbol: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .frame(width: 84)
        }
        .help(help)
    }
}

private struct IconToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct BarDivider: View {
    var body: some View { Divider().frame(height: 20) }
}

private extension View {
    func floatingPanel<S: InsettableShape>(_ shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}
