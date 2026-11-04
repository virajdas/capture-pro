import AppKit

/// What the editor's pointer does. Drawing tools map onto an `AnnotationKind`.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, line, arrow, rectangle, ellipse
    case text, step, callout, emoji
    case blur, pixelate, redact, spotlight, magnifier
    case crop, eraser

    var id: String { rawValue }

    var name: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .step: "Numbered Step"
        case .callout: "Callout"
        case .emoji: "Stamp"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .crop: "Crop"
        case .eraser: "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .step: "1.circle"
        case .callout: "bubble.left"
        case .emoji: "face.smiling"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .redact: "rectangle.fill"
        case .spotlight: "flashlight.on.fill"
        case .magnifier: "magnifyingglass.circle"
        case .crop: "crop"
        case .eraser: "eraser"
        }
    }

    /// Single-key shortcut (no modifiers).
    var key: Character {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .step: "n"
        case .callout: "c"
        case .emoji: "e"
        case .blur: "b"
        case .pixelate: "x"
        case .redact: "d"
        case .spotlight: "s"
        case .magnifier: "m"
        case .crop: "k"
        case .eraser: "w"
        }
    }

    var kind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }

    /// Groups for the floating palette.
    static let groups: [[AnnotationTool]] = [
        [.select],
        [.pen, .highlighter, .line, .arrow],
        [.rectangle, .ellipse],
        [.text, .step, .callout, .emoji],
        [.blur, .pixelate, .redact, .spotlight, .magnifier],
        [.crop, .eraser],
    ]

    var cursor: NSCursor {
        switch self {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
    }
}

enum AnnotationKind: String, CaseIterable {
    case pen, highlighter, line, arrow, rectangle, ellipse
    case text, step, callout, emoji
    case blur, pixelate, redact, spotlight, magnifier

    /// Defined by the rectangle between `start` and `end`.
    var isBoxed: Bool { [.rectangle, .ellipse, .blur, .pixelate, .redact, .spotlight, .magnifier].contains(self) }
    /// Defined by two endpoints the user can grab.
    var hasEndpoints: Bool { [.line, .arrow, .callout].contains(self) }
    var isFreehand: Bool { self == .pen || self == .highlighter }
    /// Hides or rewrites the pixels underneath; drawn below everything else.
    var isRedaction: Bool { [.blur, .pixelate, .redact].contains(self) }
    var hasText: Bool { self == .text || self == .callout }
}

enum ArrowStyle: String, CaseIterable, Identifiable {
    case classic, open, double
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .classic: "arrowtriangle.right.fill"
        case .open: "chevron.right"
        case .double: "arrow.left.and.right"
        }
    }
    var label: String {
        switch self {
        case .classic: "Filled head"
        case .open: "Open head"
        case .double: "Double-headed"
        }
    }
}

/// Visual properties. Lengths are in points; the renderer converts with the image's pixel scale.
struct AnnotationProps: Equatable {
    var color = AnnotationProps.swatches[0]
    var width: Double = 4
    var opacity: Double = 1
    var filled = false
    var rounded = true
    var shadow = true
    var fontSize: Double = 20
    var bold = true
    var pill = false
    var arrowStyle: ArrowStyle = .classic
    var emoji = "✅"
    var oval = false

    static let swatches: [RGBA] = [
        RGBA(hex: "#F2464B"), RGBA(hex: "#F7923A"), RGBA(hex: "#F9CF3C"), RGBA(hex: "#34C17A"),
        RGBA(hex: "#3B82F6"), RGBA(hex: "#8B5CF6"), RGBA(hex: "#1C1C1E"), RGBA(hex: "#FFFFFF"),
    ]

    static let emojis = ["✅", "❌", "⭐️", "👉", "⚠️", "❗️", "❓", "💡", "🔥", "👍", "❤️", "🎯"]

    static func defaults(for kind: AnnotationKind) -> AnnotationProps {
        var p = AnnotationProps()
        switch kind {
        case .highlighter: p.color = swatches[2]; p.width = 6; p.shadow = false
        case .text: p.fontSize = 22
        case .callout: p.color = swatches[4]; p.fontSize = 17
        case .step: p.fontSize = 18
        case .emoji: p.fontSize = 28
        case .magnifier: p.color = swatches[7]
        case .rectangle, .ellipse: p.width = 3.5
        case .spotlight: p.opacity = 0.55
        default: break
        }
        return p
    }
}

/// One annotation, stored in image pixel coordinates (origin top-left, y down).
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 0
    var props: AnnotationProps

    enum Handle: Equatable {
        case start, end
        /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
        case corner(Int)
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The circle a magnifier draws, inscribed in its box.
    var circleRect: CGRect {
        let r = rect, d = min(r.width, r.height)
        return CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
    }

    func bounds(unit: CGFloat) -> CGRect {
        let w = props.width * unit
        switch kind {
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            let pad = AnnotationRenderer.strokeWidth(self, unit: unit) / 2
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -pad, dy: -pad)
        case .line, .arrow:
            return rect.insetBy(dx: -w * 2, dy: -w * 2)
        case .magnifier:
            return circleRect
        case .text:
            return AnnotationRenderer.textLayout(self, unit: unit).box
        case .callout:
            return AnnotationRenderer.textLayout(self, unit: unit).box.union(CGRect(origin: start, size: .zero))
        case .step:
            let r = AnnotationRenderer.stepRadius(self, unit: unit)
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .emoji:
            let s = AnnotationRenderer.emojiSize(self, unit: unit)
            return CGRect(x: start.x - s / 2, y: start.y - s / 2, width: s, height: s)
        default:
            return rect
        }
    }

    func hit(_ p: CGPoint, unit: CGFloat, tolerance: CGFloat) -> Bool {
        let w = AnnotationRenderer.strokeWidth(self, unit: unit)
        switch kind {
        case .pen, .highlighter:
            guard bounds(unit: unit).insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
            if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= w / 2 + tolerance }
            return zip(points, points.dropFirst()).contains { Self.distance(p, $0, $1) <= w / 2 + tolerance }
        case .line, .arrow:
            return Self.distance(p, start, end) <= max(w, 6 * unit) / 2 + tolerance
        case .rectangle:
            let r = rect.insetBy(dx: -tolerance, dy: -tolerance)
            guard r.contains(p) else { return false }
            if props.filled { return true }
            let inner = rect.insetBy(dx: w / 2 + tolerance, dy: w / 2 + tolerance)
            return inner.isEmpty || !inner.contains(p)
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = hypot(nx, ny)
            if props.filled { return d <= 1 + tolerance / min(r.width, r.height) * 2 }
            let band = (w / 2 + tolerance) / (min(r.width, r.height) / 2)
            return abs(d - 1) <= band
        case .magnifier:
            let c = circleRect
            return hypot(p.x - c.midX, p.y - c.midY) <= c.width / 2 + tolerance
        case .callout:
            return AnnotationRenderer.textLayout(self, unit: unit).box.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
                || Self.distance(p, start, AnnotationRenderer.textLayout(self, unit: unit).box.center) <= 6 * unit + tolerance
        default:
            return bounds(unit: unit).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    var handles: [(Handle, CGPoint)] {
        if kind.hasEndpoints { return [(.start, start), (.end, end)] }
        guard kind.isBoxed else { return [] }
        let r = kind == .magnifier ? circleRect : rect
        return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
    }

    mutating func drag(_ handle: Handle, to p: CGPoint, constrain: Bool) {
        switch handle {
        case .start:
            start = constrain ? Self.snapAngle(p, from: end) : p
        case .end:
            end = constrain ? Self.snapAngle(p, from: start) : p
        case .corner(let i):
            let r = kind == .magnifier ? circleRect : rect
            let fixed = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][i]
            start = fixed
            end = (constrain || kind == .magnifier) ? Self.square(p, from: fixed) : p
        }
    }

    mutating func move(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        for i in points.indices { points[i].x += d.dx; points[i].y += d.dy }
    }

    // MARK: Geometry helpers

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Snaps `p` to the nearest 45° direction from `origin`.
    static func snapAngle(_ p: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: origin.x + cos(angle) * len, y: origin.y + sin(angle) * len)
    }

    /// Makes the box from `origin` to `p` square, keeping the drag direction.
    static func square(_ p: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let s = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -s : s), y: origin.y + (dy < 0 ? -s : s))
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
