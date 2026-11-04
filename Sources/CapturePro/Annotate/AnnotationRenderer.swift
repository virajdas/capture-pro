import AppKit

/// Inputs shared by every annotation draw. The context is flipped: image pixels, origin top-left.
struct AnnotationEnv {
    var image: CGImage
    var imageSize: CGSize
    var blurred: CGImage?
    var pixelated: CGImage?
    /// Image pixels per point.
    var unit: CGFloat
    /// Device pixels per image pixel. Shadows ignore the CTM, so they are scaled by hand.
    var shadowScale: CGFloat = 1
    /// The annotation whose text is being edited inline (its text is drawn by the text view).
    var hiddenTextID: UUID?
}

/// The one drawing path used for both the on-screen canvas and the exported image.
enum AnnotationRenderer {
    static func drawScene(_ list: [Annotation], in ctx: CGContext, env: AnnotationEnv) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let full = CGRect(origin: .zero, size: env.imageSize)
        drawImage(env.image, in: full, ctx)
        // Redactions and highlighter ink belong to the page, so the spotlight dims them; everything else floats above.
        let onPage: (Annotation) -> Bool = { $0.kind.isRedaction || $0.kind == .highlighter }
        for a in list where onPage(a) { draw(a, in: ctx, env: env) }
        let spots = list.filter { $0.kind == .spotlight }
        if !spots.isEmpty { drawSpotlights(spots, in: ctx, env: env) }
        for a in list where !onPage(a) && a.kind != .spotlight { draw(a, in: ctx, env: env) }
    }

    /// Draws an image right side up into a flipped context.
    static func drawImage(_ image: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    // MARK: Metrics

    static func strokeWidth(_ a: Annotation, unit: CGFloat) -> CGFloat {
        a.kind == .highlighter ? max(a.props.width * 3.2, 10) * unit : a.props.width * unit
    }

    static func stepRadius(_ a: Annotation, unit: CGFloat) -> CGFloat { a.props.fontSize * 0.85 * unit }
    static func emojiSize(_ a: Annotation, unit: CGFloat) -> CGFloat { a.props.fontSize * 1.9 * unit }

    static func font(_ a: Annotation, unit: CGFloat, scale: CGFloat = 1) -> NSFont {
        let size = a.props.fontSize * unit * scale
        let weight: NSFont.Weight = a.kind == .step || a.props.bold ? .bold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    struct TextLayout {
        var box: CGRect
        var textRect: CGRect
        var font: NSFont
    }

    static func textLayout(_ a: Annotation, unit: CGFloat) -> TextLayout {
        let font = font(a, unit: unit)
        let size = measure(a.text, font: font)
        let fs = font.pointSize
        switch a.kind {
        case .callout:
            let pad = CGSize(width: fs * 0.75, height: fs * 0.5)
            let box = CGRect(x: a.end.x - size.width / 2 - pad.width, y: a.end.y - size.height / 2 - pad.height,
                             width: size.width + pad.width * 2, height: size.height + pad.height * 2)
            return TextLayout(box: box, textRect: box.insetBy(dx: pad.width, dy: pad.height), font: font)
        default:
            let pad = a.props.pill ? CGSize(width: fs * 0.55, height: fs * 0.25) : .zero
            let box = CGRect(origin: a.start, size: CGSize(width: size.width + pad.width * 2, height: size.height + pad.height * 2))
            return TextLayout(box: box, textRect: box.insetBy(dx: pad.width, dy: pad.height), font: font)
        }
    }

    static func measure(_ text: String, font: NSFont) -> CGSize {
        let s = text.isEmpty ? " " : text
        let r = NSAttributedString(string: s, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 1e6, height: 1e6), options: [.usesLineFragmentOrigin, .usesFontLeading])
        var h = ceil(r.height)
        if s.hasSuffix("\n") { h += ceil(font.ascender - font.descender + font.leading) }
        return CGSize(width: max(ceil(r.width), font.pointSize * 0.3), height: h)
    }

    /// Text color for a label: the annotation color, or a readable contrast on a filled background.
    static func textColor(_ a: Annotation) -> NSColor {
        if a.kind == .callout || a.kind == .step || (a.kind == .text && a.props.pill) { return contrast(a.props.color) }
        return NSColor(cgColor: a.props.color.cgColor) ?? .black
    }

    static func contrast(_ c: RGBA) -> NSColor {
        let lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return lum > 0.62 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    // MARK: Drawing

    static func draw(_ a: Annotation, in ctx: CGContext, env: AnnotationEnv) {
        let u = env.unit
        let color = a.props.color.cgColor
        let w = strokeWidth(a, unit: u)
        switch a.kind {
        case .pen:
            layer(a, ctx, env) {
                ctx.addPath(smoothPath(a.points))
                stroke(ctx, color: color, width: w)
            }
        case .highlighter:
            ctx.saveGState()
            ctx.setAlpha(0.5 * a.props.opacity)
            ctx.setBlendMode(.multiply)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addPath(smoothPath(a.points))
            ctx.setLineCap(.round)
            stroke(ctx, color: color, width: w)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        case .line:
            layer(a, ctx, env) {
                ctx.move(to: a.start); ctx.addLine(to: a.end)
                stroke(ctx, color: color, width: w)
            }
        case .arrow:
            layer(a, ctx, env) { drawArrow(a, ctx, width: w, color: color) }
        case .rectangle, .ellipse:
            let r = a.props.filled ? a.rect : a.rect.insetBy(dx: w / 2, dy: w / 2)
            guard r.width > 0, r.height > 0 else { return }
            layer(a, ctx, env) {
                if a.kind == .ellipse {
                    ctx.addEllipse(in: r)
                } else {
                    let radius = a.props.rounded ? min(6 * u + w, min(r.width, r.height) / 2) : 0
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                }
                if a.props.filled { ctx.setFillColor(color); ctx.fillPath() } else { stroke(ctx, color: color, width: w) }
            }
        case .blur, .pixelate:
            let r = a.rect
            guard r.width > 0, r.height > 0 else { return }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3 * u, cornerHeight: 3 * u, transform: nil))
            ctx.clip()
            if let img = a.kind == .blur ? env.blurred : env.pixelated {
                drawImage(img, in: CGRect(origin: .zero, size: env.imageSize), ctx)
            } else {
                ctx.setFillColor(CGColor(gray: 0.6, alpha: 1)); ctx.fill(r)
            }
            ctx.restoreGState()
        case .redact:
            let r = a.rect
            guard r.width > 0, r.height > 0 else { return }
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2 * u, cornerHeight: 2 * u, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        case .spotlight:
            break
        case .magnifier:
            drawMagnifier(a, ctx, env)
        case .text:
            let lay = textLayout(a, unit: u)
            layer(a, ctx, env, strength: a.props.pill ? 1 : 0.6) {
                if a.props.pill {
                    let radius = min(lay.box.height / 2, lay.font.pointSize * 0.9)
                    ctx.addPath(CGPath(roundedRect: lay.box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.setFillColor(color); ctx.fillPath()
                }
                if a.id != env.hiddenTextID { drawText(a.text, in: lay.textRect, font: lay.font, color: textColor(a)) }
            }
        case .callout:
            let lay = textLayout(a, unit: u)
            layer(a, ctx, env) {
                ctx.setFillColor(color)
                let radius = min(lay.box.height / 2, lay.font.pointSize * 0.8)
                ctx.addPath(CGPath(roundedRect: lay.box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
                if !lay.box.contains(a.start) {
                    let c = lay.box.center
                    let dx = a.start.x - c.x, dy = a.start.y - c.y, len = max(hypot(dx, dy), 0.001)
                    let half = min(lay.box.width, lay.box.height) * 0.22
                    let n = CGPoint(x: -dy / len * half, y: dx / len * half)
                    ctx.move(to: CGPoint(x: c.x + n.x, y: c.y + n.y))
                    ctx.addLine(to: a.start)
                    ctx.addLine(to: CGPoint(x: c.x - n.x, y: c.y - n.y))
                    ctx.closePath()
                    ctx.fillPath()
                }
                if a.id != env.hiddenTextID { drawText(a.text, in: lay.textRect, font: lay.font, color: textColor(a)) }
            }
        case .step:
            let r = stepRadius(a, unit: u)
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            layer(a, ctx, env) {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                ctx.setLineWidth(1.5 * u)
                ctx.strokeEllipse(in: circle.insetBy(dx: 0.75 * u, dy: 0.75 * u))
                let font = font(a, unit: u)
                let s = "\(a.number)"
                let size = measure(s, font: font)
                drawText(s, in: CGRect(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2,
                                       width: size.width, height: size.height), font: font, color: textColor(a))
            }
        case .emoji:
            let s = emojiSize(a, unit: u)
            let font = NSFont.systemFont(ofSize: s * 0.8)
            let size = measure(a.props.emoji, font: font)
            layer(a, ctx, env, strength: 0.7) {
                drawText(a.props.emoji, in: CGRect(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2,
                                                   width: size.width, height: size.height), font: font, color: .black)
            }
        }
    }

    /// Composites `body` as one layer with the annotation's opacity and optional soft shadow.
    private static func layer(_ a: Annotation, _ ctx: CGContext, _ env: AnnotationEnv, strength: CGFloat = 1, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setAlpha(a.props.opacity)
        if a.props.shadow {
            let s = env.unit * env.shadowScale
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * s), blur: 5 * s,
                          color: CGColor(gray: 0, alpha: 0.32 * strength))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func stroke(_ ctx: CGContext, color: CGColor, width: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private static func drawText(_ s: String, in r: CGRect, font: NSFont, color: NSColor) {
        guard !s.isEmpty else { return }
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            .draw(with: CGRect(origin: r.origin, size: CGSize(width: 1e6, height: 1e6)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// A Catmull-Rom-ish path through the midpoints of the captured points.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
            if pts.count == 1 { path.addLine(to: first) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    private static func drawArrow(_ a: Annotation, _ ctx: CGContext, width w: CGFloat, color: CGColor) {
        let p0 = a.start, p1 = a.end
        let dx = p1.x - p0.x, dy = p1.y - p0.y, len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let u = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -u.y, y: u.x)
        func pt(_ base: CGPoint, _ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: base.x + u.x * along + n.x * side, y: base.y + u.y * along + n.y * side)
        }
        let double = a.props.arrowStyle == .double
        let headLen = min(len * (double ? 0.3 : 0.45), w * 3.6 + 8)
        let headHalf = headLen * 0.6

        switch a.props.arrowStyle {
        case .open:
            ctx.move(to: p0); ctx.addLine(to: p1)
            ctx.move(to: pt(p1, -headLen, headHalf)); ctx.addLine(to: p1); ctx.addLine(to: pt(p1, -headLen, -headHalf))
            stroke(ctx, color: color, width: w)
        case .classic:
            // A tapered body: thin at the tail, full width where it meets the head.
            let tail = w * 0.22, body = w * 0.55
            ctx.move(to: pt(p0, 0, tail))
            ctx.addLine(to: pt(p1, -headLen, body))
            ctx.addLine(to: pt(p1, -headLen, headHalf))
            ctx.addLine(to: p1)
            ctx.addLine(to: pt(p1, -headLen, -headHalf))
            ctx.addLine(to: pt(p1, -headLen, -body))
            ctx.addLine(to: pt(p0, 0, -tail))
            ctx.closePath()
            fillSoft(ctx, color: color, width: w)
        case .double:
            let body = w * 0.45
            ctx.move(to: p0)
            ctx.addLine(to: pt(p0, headLen, -headHalf))
            ctx.addLine(to: pt(p0, headLen, -body))
            ctx.addLine(to: pt(p1, -headLen, -body))
            ctx.addLine(to: pt(p1, -headLen, -headHalf))
            ctx.addLine(to: p1)
            ctx.addLine(to: pt(p1, -headLen, headHalf))
            ctx.addLine(to: pt(p1, -headLen, body))
            ctx.addLine(to: pt(p0, headLen, body))
            ctx.addLine(to: pt(p0, headLen, headHalf))
            ctx.closePath()
            fillSoft(ctx, color: color, width: w)
        }
    }

    /// Fills the current path and rounds its corners with a matching stroke.
    private static func fillSoft(_ ctx: CGContext, color: CGColor, width w: CGFloat) {
        guard let path = ctx.path else { return }
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.addPath(path)
        stroke(ctx, color: color, width: max(1, w * 0.35))
    }

    private static func drawSpotlights(_ spots: [Annotation], in ctx: CGContext, env: AnnotationEnv) {
        let full = CGRect(origin: .zero, size: env.imageSize)
        let dim = spots.map(\.props.opacity).max() ?? 0.55
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: dim))
        ctx.fill(full)
        ctx.setBlendMode(.clear)
        for s in spots {
            let r = s.rect
            guard r.width > 0, r.height > 0 else { continue }
            if s.props.oval {
                ctx.addEllipse(in: r)
            } else {
                let radius = s.props.rounded ? min(10 * env.unit, min(r.width, r.height) / 2) : 0
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawMagnifier(_ a: Annotation, _ ctx: CGContext, _ env: AnnotationEnv) {
        let c = a.circleRect
        guard c.width > 2 else { return }
        let u = env.unit
        let zoom: CGFloat = 2
        let size = env.imageSize
        // Shadowed disc first, then the zoomed pixels clipped inside it, then the ring.
        layer(a, ctx, env) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: c)
        }
        ctx.saveGState()
        ctx.setAlpha(a.props.opacity)
        ctx.addEllipse(in: c)
        ctx.clip()
        let origin = CGPoint(x: c.midX - c.midX * zoom, y: c.midY - c.midY * zoom)
        ctx.interpolationQuality = .high
        drawImage(env.image, in: CGRect(origin: origin, size: CGSize(width: size.width * zoom, height: size.height * zoom)), ctx)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setAlpha(a.props.opacity)
        let ring = max(2, a.props.width * 0.9) * u
        ctx.setStrokeColor(a.props.color.cgColor)
        ctx.setLineWidth(ring)
        ctx.strokeEllipse(in: c.insetBy(dx: ring / 2, dy: ring / 2))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(max(1, 0.5 * u))
        ctx.strokeEllipse(in: c)
        ctx.restoreGState()
    }
}
