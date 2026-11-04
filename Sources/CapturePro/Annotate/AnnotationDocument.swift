import AppKit
import CoreImage
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// State of one annotation editor: the screenshot, its annotations, crop, look and history.
@MainActor
@Observable
final class AnnotationDocument {
    let image: CGImage
    let size: CGSize
    /// Image pixels per point (the Retina scale the screenshot was taken at).
    let unit: CGFloat
    var file: URL?
    var name: String {
        didSet { window?.title = name }
    }

    /// Downscaled copy for drawing on screen when the original is very large.
    private(set) var display: CGImage
    private(set) var blurred: CGImage?
    private(set) var pixelated: CGImage?

    var annotations: [Annotation] = []
    var selection: UUID?
    var editingID: UUID?
    var tool: AnnotationTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            if tool == .crop { pendingCrop = crop; toolBeforeCrop = oldValue } else { pendingCrop = nil }
            if tool == .eraser || tool == .crop { selection = nil }
        }
    }
    var crop: CGRect?
    var pendingCrop: CGRect?
    var defaults: [AnnotationKind: AnnotationProps]

    var beautify: Bool
    var beautifyStyle: StyleSettings

    var zoom: CGFloat = 1
    var pan: CGPoint = .zero
    /// Transient confirmation shown on the toolbar ("Copied", "Saved").
    var flash: String?

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var toolBeforeCrop: AnnotationTool = .arrow
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var pending: Snapshot?
    @ObservationIgnored private var propKey: (String, UUID?)?
    @ObservationIgnored private var savedState: SavedState?
    @ObservationIgnored private var backdropKey: BackdropKey?
    private var backdrop: (key: BackdropKey, image: CGImage)?
    /// Bumped on every history change so SwiftUI refreshes undo/redo availability.
    private(set) var historyRevision = 0

    struct Snapshot: Equatable {
        var annotations: [Annotation]
        var crop: CGRect?
    }

    private struct SavedState: Equatable {
        var snapshot: Snapshot
        var beautify: Bool
        var style: StyleSettings
    }

    struct BackdropKey: Equatable {
        var size: CGSize
        var style: StyleSettings
    }

    init(image: CGImage, file: URL?) {
        self.image = image
        self.size = CGSize(width: image.width, height: image.height)
        self.unit = NSScreen.main?.backingScaleFactor ?? 2
        self.file = file
        self.name = file?.deletingPathExtension().lastPathComponent ?? "Screenshot"
        self.display = image
        var d: [AnnotationKind: AnnotationProps] = [:]
        for k in AnnotationKind.allCases { d[k] = AnnotationProps.defaults(for: k) }
        self.defaults = d
        let prefs = Preferences.shared.stored
        self.beautify = prefs.beautifyScreenshots
        self.beautifyStyle = prefs.style
        if file != nil { savedState = currentState }
        prepareEffects()
    }

    // MARK: Derived

    var fullRect: CGRect { CGRect(origin: .zero, size: size) }

    /// The visible part of the image (all of it, or the applied crop).
    var cropRect: CGRect {
        guard let crop else { return fullRect }
        let r = crop.intersection(fullRect).integral
        return r.width >= 1 && r.height >= 1 ? r : fullRect
    }

    var selectedIndex: Int? { selection.flatMap { id in annotations.firstIndex { $0.id == id } } }
    var selected: Annotation? { selectedIndex.map { annotations[$0] } }

    subscript(id: UUID) -> Annotation? {
        get { annotations.first { $0.id == id } }
        set {
            guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            if let newValue { annotations[i] = newValue } else { annotations.remove(at: i) }
        }
    }

    /// The kind the property bar edits: the selection, else the active drawing tool.
    var activeKind: AnnotationKind? { selected?.kind ?? tool.kind }

    var props: AnnotationProps {
        if let s = selected { return s.props }
        return activeKind.flatMap { defaults[$0] } ?? AnnotationProps()
    }

    var nextStepNumber: Int { (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    // MARK: Properties

    func binding<T>(_ kp: WritableKeyPath<AnnotationProps, T>) -> Binding<T> {
        Binding(get: { self.props[keyPath: kp] },
                set: { value in
                    var p = self.props
                    p[keyPath: kp] = value
                    self.setProps(p, key: "\(kp)")
                })
    }

    /// Applies properties to the selection (one undo step per continuous edit) and remembers them for the kind.
    func setProps(_ p: AnnotationProps, key: String) {
        if let i = selectedIndex {
            if propKey == nil || propKey!.0 != key || propKey!.1 != selection {
                checkpoint()
                propKey = (key, selection)
            }
            annotations[i].props = p
        }
        if let k = activeKind { defaults[k] = p }
    }

    // MARK: History

    var snapshot: Snapshot { Snapshot(annotations: annotations, crop: crop) }
    var canUndo: Bool { _ = historyRevision; return !undoStack.isEmpty }
    var canRedo: Bool { _ = historyRevision; return !redoStack.isEmpty }

    /// Starts a gesture; `commitChange` records it if anything changed.
    func beginChange() { if pending == nil { pending = snapshot } }

    func commitChange() {
        if let p = pending, p != snapshot { push(p) }
        pending = nil
    }

    func checkpoint() { push(snapshot) }

    private func push(_ s: Snapshot) {
        undoStack.append(s)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        propKey = nil
        historyRevision += 1
    }

    func undo() {
        guard editingID == nil, let s = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(s)
    }

    func redo() {
        guard editingID == nil, let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        annotations = s.annotations
        crop = s.crop
        if let id = selection, self[id] == nil { selection = nil }
        propKey = nil
        historyRevision += 1
    }

    // MARK: Editing

    func add(_ a: Annotation) {
        annotations.append(a)
        selection = a.id
    }

    func deleteSelection() {
        guard let id = selection else { return }
        checkpoint()
        self[id] = nil
        selection = nil
    }

    func duplicateSelection() {
        guard var a = selected else { return }
        checkpoint()
        a.id = UUID()
        a.move(by: CGVector(dx: 16 * unit, dy: 16 * unit))
        if a.kind == .step { a.number = nextStepNumber }
        add(a)
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let i = selectedIndex else { return }
        if propKey == nil || propKey!.0 != "nudge" || propKey!.1 != selection {
            checkpoint()
            propKey = ("nudge", selection)
        }
        annotations[i].move(by: CGVector(dx: dx * unit, dy: dy * unit))
    }

    func applyCrop() {
        if let p = pendingCrop?.intersection(fullRect).integral, p.width >= 8, p.height >= 8 {
            let next: CGRect? = p == fullRect ? nil : p
            if next != crop { checkpoint(); crop = next }
        }
        tool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func resetCrop() {
        if crop != nil { checkpoint(); crop = nil }
        pendingCrop = nil
        tool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func cancelCrop() {
        tool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    // MARK: Effects

    private func prepareEffects() {
        let src = image, u = unit
        Task.detached(priority: .userInitiated) {
            let fx = Self.makeEffects(src, unit: u)
            await MainActor.run {
                if let d = fx.display { self.display = d }
                self.blurred = fx.blurred
                self.pixelated = fx.pixelated
            }
        }
    }

    private func ensureEffects() {
        guard blurred == nil || pixelated == nil else { return }
        let fx = Self.makeEffects(image, unit: unit)
        blurred = fx.blurred
        pixelated = fx.pixelated
    }

    /// Full-size blurred and pixelated copies (drawn clipped), plus a screen proxy for huge captures.
    nonisolated static func makeEffects(_ image: CGImage, unit: CGFloat) -> (blurred: CGImage?, pixelated: CGImage?, display: CGImage?) {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let src = CIImage(cgImage: image)
        let extent = src.extent
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        func make(_ img: CIImage, _ rect: CGRect) -> CGImage? {
            ctx.createCGImage(img, from: rect, format: .RGBA8, colorSpace: cs)
        }
        let sigma = max(8, min(extent.width, extent.height) / 90, 7 * unit)
        let blurred = src.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let pixelated = src.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, 7 * unit), kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: extent)
        var display: CGImage?
        let long = max(extent.width, extent.height)
        if long > 3200 {
            let k = 2560 / long
            let scaled = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            display = make(scaled, scaled.extent.integral)
        }
        return (make(blurred, extent), make(pixelated, extent), display)
    }

    // MARK: Output

    /// Flattens the image and every annotation at full resolution, cropped, optionally beautified.
    func render(includeBeautify: Bool) -> CGImage {
        if annotations.contains(where: { $0.kind == .blur || $0.kind == .pixelate }) { ensureEffects() }
        let region = cropRect
        let w = Int(region.width), h = Int(region.height)
        let cs = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        let env = AnnotationEnv(image: image, imageSize: size, blurred: blurred, pixelated: pixelated, unit: unit)
        AnnotationRenderer.drawScene(annotations, in: ctx, env: env)
        guard var out = ctx.makeImage() else { return image }
        if includeBeautify, beautify, let pretty = Compositor.beautify(out, style: beautifyStyle) { out = pretty }
        return out
    }

    private var currentState: SavedState { SavedState(snapshot: snapshot, beautify: beautify, style: beautifyStyle) }
    var isSaved: Bool { savedState == currentState }

    func copyToClipboard() {
        ScreenshotService.copy(render(includeBeautify: true), file: isSaved ? file : nil)
        show("Copied")
    }

    func save() {
        let img = render(includeBeautify: true)
        if let file, Self.write(img, to: file) {
            savedState = currentState
            show("Saved")
        } else if let url = ScreenshotService.save(img, format: Preferences.shared.stored.imageFormat,
                                                   folder: Preferences.shared.screenshotFolderURL) {
            file = url
            name = url.deletingPathExtension().lastPathComponent
            savedState = currentState
            show("Saved")
        } else {
            NSSound.beep()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        let format = Preferences.shared.stored.imageFormat
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.nameFieldStringValue = "\(name).\(format.ext)"
        panel.directoryURL = file?.deletingLastPathComponent() ?? Preferences.shared.screenshotFolderURL
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            if Self.write(self.render(includeBeautify: true), to: url) {
                self.file = url
                self.name = url.deletingPathExtension().lastPathComponent
                self.savedState = self.currentState
                self.show("Saved")
            } else {
                NSSound.beep()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Writes the flattened image to a temporary PNG for sharing and dragging out.
    func exportTemporaryFile() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Capture Pro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        return Self.write(render(includeBeautify: true), to: url) ? url : nil
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        let ok = [UTType.png, .jpeg, .heic, .tiff].contains(type)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, (ok ? type : .png).identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    func show(_ message: String) {
        flash = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if self?.flash == message { self?.flash = nil }
        }
    }

    // MARK: Beautify preview

    /// The beautified background for the canvas preview, computed off the main thread from a small placeholder.
    func backdrop(for regionSize: CGSize) -> CGImage? {
        let key = BackdropKey(size: regionSize, style: beautifyStyle)
        if let b = backdrop, b.key == key { return b.image }
        if backdropKey != key {
            backdropKey = key
            let style = beautifyStyle
            Task.detached(priority: .userInitiated) {
                guard let img = Self.makeBackdrop(size: regionSize, style: style) else { return }
                await MainActor.run {
                    if self.backdropKey == key { self.backdrop = (key, img) }
                }
            }
        }
        return nil
    }

    nonisolated private static func makeBackdrop(size: CGSize, style: StyleSettings) -> CGImage? {
        let k = min(1, 1400 / max(size.width, size.height))
        let w = max(2, Int(size.width * k)), h = max(2, Int(size.height * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let placeholder = ctx.makeImage() else { return nil }
        return Compositor.beautify(placeholder, style: style)
    }
}

/// Where the screenshot sits inside a beautified frame — mirrors `Compositor.beautify`.
enum BeautifyGeometry {
    struct Layout {
        var canvas: CGSize
        /// Content rect, origin top-left.
        var content: CGRect
        var radius: CGFloat
    }

    static func layout(size: CGSize, style: StyleSettings) -> Layout {
        var style = style
        style.frame.aspect = .auto
        let p = style.frame.padding
        let canvasShort = min(size.width, size.height) / max(0.4, 1 - 2 * p)
        let canvas = RenderState.canvasSize(source: size, style: style, shortSide: canvasShort)
        let rect = Compositor.screenRect(canvas: CGRect(origin: .zero, size: canvas), sourceAspect: size.width / size.height, padding: p)
        let fix = size.width / max(rect.width, 1)
        let out = CGSize(width: (canvas.width * fix).rounded(), height: (canvas.height * fix).rounded())
        let content = CGRect(x: (out.width - size.width) / 2, y: (out.height - size.height) / 2, width: size.width, height: size.height)
        return Layout(canvas: out, content: content, radius: style.frame.cornerRadius * min(out.width, out.height) / 1080)
    }
}
