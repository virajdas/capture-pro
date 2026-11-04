import AppKit
import SwiftUI

/// Draws the document with the same renderer used for export and turns mouse/keys into edits.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let doc: AnnotationDocument
    private var drag: Drag?
    private var textView: InlineTextView?

    /// Space kept clear of the floating chrome.
    static let insets = NSEdgeInsets(top: 64, left: 84, bottom: 92, right: 32)

    private enum Drag {
        case create(UUID)
        case move(UUID, last: CGPoint)
        case handle(UUID, Annotation.Handle)
        case crop(start: CGPoint)
        case cropCorner(Int)
        case cropMove(last: CGPoint)
        case erase
        case pan(last: CGPoint)
    }

    struct Geometry {
        var region: CGRect
        var scale: CGFloat
        var content: CGRect
        var outer: CGRect
        var radius: CGFloat
        var beautified: Bool

        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: content.minX + (p.x - region.minX) * scale, y: content.minY + (p.y - region.minY) * scale)
        }
        func toImage(_ p: CGPoint) -> CGPoint {
            CGPoint(x: region.minX + (p.x - content.minX) / scale, y: region.minY + (p.y - content.minY) / scale)
        }
        func toView(_ r: CGRect) -> CGRect {
            let o = toView(r.origin)
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }
    }

    init(doc: AnnotationDocument) {
        self.doc = doc
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var geometry: Geometry {
        let full = doc.fullRect
        let cropping = doc.tool == .crop
        let region = cropping ? full : doc.cropRect
        let i = Self.insets
        let avail = CGRect(x: i.left, y: i.top, width: max(40, bounds.width - i.left - i.right),
                           height: max(40, bounds.height - i.top - i.bottom))
        let beautified = doc.beautify && !cropping
        var outerSize = region.size
        var content = CGRect(origin: .zero, size: region.size)
        var radius: CGFloat = 0
        if beautified {
            let g = BeautifyGeometry.layout(size: region.size, style: doc.beautifyStyle)
            outerSize = g.canvas; content = g.content; radius = g.radius
        }
        // Never enlarge past actual size (in points) when fitting; zoom can go further.
        let fit = min(avail.width / outerSize.width, avail.height / outerSize.height, 1 / doc.unit)
        let s = fit * doc.zoom
        let outer = CGRect(x: avail.midX - outerSize.width * s / 2 + doc.pan.x, y: avail.midY - outerSize.height * s / 2 + doc.pan.y,
                           width: outerSize.width * s, height: outerSize.height * s)
        let c = CGRect(x: outer.minX + content.minX * s, y: outer.minY + content.minY * s,
                       width: content.width * s, height: content.height * s)
        return Geometry(region: region, scale: s, content: c, outer: outer, radius: radius * s, beautified: beautified)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.needsDisplay = true
                self.syncEditor()
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    private func render() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.backdropColor.setFill()
        bounds.fill()

        let g = geometry
        let backing = window?.backingScaleFactor ?? 2
        let contentPath = CGPath(roundedRect: g.content, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil)

        if g.beautified {
            if let bd = doc.backdrop(for: g.region.size) {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                AnnotationRenderer.drawImage(bd, in: g.outer, ctx)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
                ctx.fill(g.outer)
            }
        } else if [.none, .noneSkipLast, .noneSkipFirst].contains(doc.image.alphaInfo) {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: CGColor(gray: 0, alpha: 0.18))
            ctx.addPath(contentPath)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(contentPath)
        ctx.clip()
        ctx.translateBy(x: g.content.minX, y: g.content.minY)
        ctx.scaleBy(x: g.scale, y: g.scale)
        ctx.translateBy(x: -g.region.minX, y: -g.region.minY)
        ctx.interpolationQuality = drag == nil ? .high : .medium
        let env = AnnotationEnv(image: doc.display, imageSize: doc.size, blurred: doc.blurred, pixelated: doc.pixelated,
                                unit: doc.unit, shadowScale: g.scale * backing, hiddenTextID: doc.editingID)
        AnnotationRenderer.drawScene(doc.annotations, in: ctx, env: env)
        ctx.restoreGState()

        if g.beautified && doc.beautifyStyle.frame.border {
            ctx.addPath(CGPath(roundedRect: g.content.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, g.radius - 0.5),
                               cornerHeight: max(0, g.radius - 0.5), transform: nil))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        if doc.tool == .crop { drawCropOverlay(ctx, g) }
        if let a = doc.selected, doc.editingID == nil || a.kind == .callout { drawSelection(a, ctx, g) }
    }

    private static let backdropColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.935, alpha: 1)
    }

    private func drawSelection(_ a: Annotation, _ ctx: CGContext, _ g: Geometry) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        if !a.kind.hasEndpoints {
            let b = g.toView(a.bounds(unit: doc.unit)).insetBy(dx: -4, dy: -4)
            ctx.setStrokeColor(accent.copy(alpha: 0.8) ?? accent)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (_, p) in a.handles { drawHandle(g.toView(p), ctx, accent: accent) }
        ctx.restoreGState()
    }

    private func drawHandle(_ p: CGPoint, _ ctx: CGContext, accent: CGColor) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
    }

    private func drawCropOverlay(_ ctx: CGContext, _ g: Geometry) {
        let img = g.content
        let sel = (doc.pendingCrop.map { g.toView($0.intersection(doc.fullRect)) }) ?? img
        ctx.saveGState()
        ctx.addRect(img)
        ctx.addRect(sel)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath(using: .evenOdd)
        guard doc.pendingCrop != nil else { ctx.restoreGState(); return }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = sel.minX + sel.width * CGFloat(i) / 3, y = sel.minY + sel.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: sel.minY)); ctx.addLine(to: CGPoint(x: x, y: sel.maxY))
            ctx.move(to: CGPoint(x: sel.minX, y: y)); ctx.addLine(to: CGPoint(x: sel.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel)
        // L-shaped corner grips.
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        let l = min(18, sel.width / 3, sel.height / 3)
        for c in cropCorners(sel) {
            let sx: CGFloat = c.x == sel.minX ? 1 : -1, sy: CGFloat = c.y == sel.minY ? 1 : -1
            ctx.move(to: CGPoint(x: c.x + sx * l, y: c.y)); ctx.addLine(to: c); ctx.addLine(to: CGPoint(x: c.x, y: c.y + sy * l))
        }
        ctx.strokePath()
        let label = "\(Int(doc.pendingCrop!.width)) × \(Int(doc.pendingCrop!.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: sel.midX - size.width / 2 - 8, y: sel.maxY + 8, width: size.width + 16, height: size.height + 6)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
        ctx.restoreGState()
    }

    private func cropCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    override func resetCursorRects() {
        addCursorRect(geometry.content.intersection(bounds), cursor: doc.tool.cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncEditor()
    }

    // MARK: Mouse

    private func topHit(_ p: CGPoint, _ g: Geometry) -> Annotation? {
        let tol = 4 / g.scale
        return doc.annotations.reversed().first { $0.hit(p, unit: doc.unit, tolerance: tol) }
    }

    private func handleHit(_ viewPoint: CGPoint, _ g: Geometry) -> (UUID, Annotation.Handle)? {
        guard let a = doc.selected else { return nil }
        for (h, p) in a.handles {
            let v = g.toView(p)
            if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= 8 { return (a.id, h) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if v.y < 52 { window?.performDrag(with: event); return }
        if doc.editingID != nil { endEditing(); return }
        window?.makeFirstResponder(self)
        let g = geometry
        let p = g.toImage(v)
        let shift = event.modifierFlags.contains(.shift)

        if event.clickCount == 2, doc.tool != .crop, doc.tool != .eraser, let a = topHit(p, g), a.kind.hasText {
            drag = nil
            beginEditing(a.id)
            return
        }

        switch doc.tool {
        case .crop:
            if let sel = doc.pendingCrop {
                let vr = g.toView(sel)
                if event.clickCount == 2, vr.contains(v) { doc.applyCrop(); return }
                if let i = cropCorners(vr).firstIndex(where: { hypot($0.x - v.x, $0.y - v.y) <= 12 }) {
                    drag = .cropCorner(i); return
                }
                if vr.contains(v) { drag = .cropMove(last: p); return }
            }
            drag = .crop(start: clamp(p))
        case .eraser:
            doc.beginChange()
            drag = .erase
            erase(at: p, g)
        case .select:
            if let (id, h) = handleHit(v, g) {
                doc.beginChange(); drag = .handle(id, h)
            } else if let a = topHit(p, g) {
                doc.selection = a.id
                doc.beginChange(); drag = .move(a.id, last: p)
            } else {
                doc.selection = nil
                drag = doc.zoom > 1 ? .pan(last: v) : nil
            }
        default:
            if let (id, h) = handleHit(v, g) {
                doc.beginChange(); drag = .handle(id, h); return
            }
            if doc.tool == .text, let a = topHit(p, g), a.kind == .text {
                doc.selection = a.id
                beginEditing(a.id)
                return
            }
            guard let kind = doc.tool.kind else { return }
            create(kind, at: p, shift: shift)
        }
        needsDisplay = true
    }

    private func create(_ kind: AnnotationKind, at p: CGPoint, shift: Bool) {
        doc.beginChange()
        var a = Annotation(kind: kind, start: p, end: p, props: doc.defaults[kind] ?? AnnotationProps.defaults(for: kind))
        if kind.isFreehand { a.points = [p] }
        if kind == .step { a.number = doc.nextStepNumber }
        doc.add(a)
        switch kind {
        case .text:
            drag = nil
            beginEditing(a.id)
        case .step, .emoji:
            drag = .move(a.id, last: p)
        default:
            drag = .create(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let g = geometry
        let v = convert(event.locationInWindow, from: nil)
        let p = g.toImage(v)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .create(let id):
            guard var a = doc[id] else { return }
            if a.kind.isFreehand {
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) >= 1.5 / g.scale {
                    a.points.append(p)
                }
            } else if a.kind == .magnifier || (shift && (a.kind == .rectangle || a.kind == .ellipse || a.kind == .spotlight)) {
                a.end = Annotation.square(p, from: a.start)
            } else if shift && a.kind.hasEndpoints {
                a.end = Annotation.snapAngle(p, from: a.start)
            } else {
                a.end = p
            }
            doc[id] = a
        case .move(let id, let last):
            guard var a = doc[id] else { return }
            a.move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            doc[id] = a
            self.drag = .move(id, last: p)
        case .handle(let id, let h):
            guard var a = doc[id] else { return }
            a.drag(h, to: p, constrain: shift)
            doc[id] = a
        case .crop(let start):
            var end = clamp(p)
            if shift { end = clamp(Annotation.square(end, from: start)) }
            doc.pendingCrop = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                     width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .cropCorner(let i):
            guard let r = doc.pendingCrop else { return }
            let fixed = cropCorners(r)[(i + 2) % 4]
            let q = clamp(p)
            doc.pendingCrop = CGRect(x: min(fixed.x, q.x), y: min(fixed.y, q.y), width: abs(q.x - fixed.x), height: abs(q.y - fixed.y))
        case .cropMove(let last):
            guard var r = doc.pendingCrop else { return }
            r.origin.x = max(0, min(doc.size.width - r.width, r.origin.x + p.x - last.x))
            r.origin.y = max(0, min(doc.size.height - r.height, r.origin.y + p.y - last.y))
            doc.pendingCrop = r
            self.drag = .cropMove(last: p)
        case .erase:
            erase(at: p, g)
        case .pan(let last):
            doc.pan = CGPoint(x: doc.pan.x + v.x - last.x, y: doc.pan.y + v.y - last.y)
            self.drag = .pan(last: v)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .create(let id):
            guard var a = doc[id] else { doc.commitChange(); return }
            let u = doc.unit
            if a.kind.isFreehand {
                if a.points.count == 1 { a.points.append(CGPoint(x: a.start.x + 0.5, y: a.start.y + 0.5)) }
                doc[id] = a
            } else if a.kind == .callout {
                if hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 12 * u {
                    a.end = CGPoint(x: a.start.x + 70 * u, y: a.start.y - 50 * u)
                    doc[id] = a
                }
                beginEditing(id)
                return
            } else if a.kind.hasEndpoints {
                if hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4 * u { doc[id] = nil; doc.selection = nil }
            } else if a.rect.width < 3 * u || a.rect.height < 3 * u {
                doc[id] = nil
                doc.selection = nil
            }
            doc.commitChange()
        case .crop:
            if let r = doc.pendingCrop, r.width < 4 || r.height < 4 { doc.pendingCrop = nil }
        case .cropCorner, .cropMove, .pan:
            break
        default:
            doc.commitChange()
        }
    }

    private func erase(at p: CGPoint, _ g: Geometry) {
        if let a = topHit(p, g) { doc[a.id] = nil }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(doc.size.width, p.x)), y: max(0, min(doc.size.height, p.y)))
    }

    // MARK: Zoom

    override func magnify(with event: NSEvent) {
        setZoom(doc.zoom * (1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(doc.zoom * (1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)))
        } else if doc.zoom > 1 {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            doc.pan = CGPoint(x: doc.pan.x + event.scrollingDeltaX * k, y: doc.pan.y + event.scrollingDeltaY * k)
        }
    }

    func setZoom(_ z: CGFloat) {
        doc.zoom = max(1, min(8, z))
        if doc.zoom == 1 { doc.pan = .zero }
    }

    // MARK: Keys

    /// Handles a key-down for the whole window. Returns false to let it through.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode

        if let tv = textView {
            if code == 53 { endEditing(); return true }
            guard mods.contains(.command) else { return false }
            switch chars {
            case "a": tv.selectAll(nil)
            case "c": tv.copy(nil)
            case "v": tv.pasteAsPlainText(nil)
            case "x": tv.cut(nil)
            case "z": mods.contains(.shift) ? tv.undoManager?.redo() : tv.undoManager?.undo()
            case "\r": endEditing()
            default: if code == 36 { endEditing() } else { return false }
            }
            return true
        }

        if mods.contains(.command) {
            let shift = mods.contains(.shift)
            switch chars {
            case "z": shift ? doc.redo() : doc.undo()
            case "d": doc.duplicateSelection()
            case "c": doc.copyToClipboard()
            case "s": shift ? doc.saveAs() : doc.save()
            case "w": window?.performClose(nil)
            case "=", "+": setZoom(doc.zoom * 1.25)
            case "-": setZoom(doc.zoom / 1.25)
            case "0": setZoom(1)
            default:
                if code == 36 || code == 76 { done(); return true }
                if code == 51 { doc.deleteSelection(); return true }
                return false
            }
            return true
        }
        guard !mods.contains(.control), !mods.contains(.option) else { return false }

        let step: CGFloat = mods.contains(.shift) ? 10 : 1
        switch code {
        case 53: escape()
        case 51, 117: doc.deleteSelection()
        case 36, 76:
            if doc.tool == .crop { doc.applyCrop() } else if let a = doc.selected, a.kind.hasText { beginEditing(a.id) }
        case 123: doc.nudge(-step, 0)
        case 124: doc.nudge(step, 0)
        case 125: doc.nudge(0, step)
        case 126: doc.nudge(0, -step)
        default:
            guard mods.isEmpty, chars.count == 1, let tool = AnnotationTool.allCases.first(where: { String($0.key) == chars })
            else { return false }
            doc.tool = tool
        }
        return true
    }

    private func escape() {
        if doc.tool == .crop { doc.cancelCrop(); return }
        if drag != nil { return }
        if doc.selection != nil { doc.selection = nil; return }
        window?.performClose(nil)
    }

    func done() {
        if doc.editingID != nil { endEditing() }
        doc.copyToClipboard()
        window?.performClose(nil)
    }

    // MARK: Inline text

    func beginEditing(_ id: UUID) {
        guard let a = doc[id], a.kind.hasText else { return }
        if doc.editingID != nil { endEditing() }
        doc.beginChange()
        doc.selection = id
        doc.editingID = id
        let tv = InlineTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1e6, height: 1e6)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.allowsUndo = true
        tv.focusRingType = .none
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.string = a.text
        tv.delegate = self
        addSubview(tv)
        textView = tv
        syncEditor()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
    }

    func endEditing() {
        guard let id = doc.editingID, let tv = textView else { return }
        let text = tv.string
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        doc.editingID = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc[id] = nil
            doc.selection = nil
        } else if var a = doc[id] {
            a.text = text
            doc[id] = a
        }
        doc.commitChange()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let id = doc.editingID, let tv = textView, var a = doc[id] else { return }
        a.text = tv.string
        doc[id] = a
        syncEditor()
    }

    /// Keeps the text view on top of the annotation it edits, at the canvas scale.
    func syncEditor() {
        guard let tv = textView else { return }
        guard let id = doc.editingID, let a = doc[id] else { endEditing(); return }
        let g = geometry
        let lay = AnnotationRenderer.textLayout(a, unit: doc.unit)
        let font = AnnotationRenderer.font(a, unit: doc.unit, scale: g.scale)
        let color = AnnotationRenderer.textColor(a).withAlphaComponent(a.props.opacity)
        if tv.font != font { tv.font = font }
        tv.textColor = color
        tv.insertionPointColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color]
        let r = g.toView(lay.textRect)
        tv.frame = CGRect(x: r.minX, y: r.minY, width: r.width + 6, height: r.height + 2)
    }
}

/// The inline editor. Keeps its own key handling minimal; the window routes Esc and ⌘ shortcuts.
final class InlineTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

struct AnnotationCanvas: NSViewRepresentable {
    let view: AnnotationCanvasView
    func makeNSView(context: Context) -> AnnotationCanvasView { view }
    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {}
}
