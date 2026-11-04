// Renders the app icon: a calm gradient squircle holding the same frame-and-dot mark as the menu bar.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    squircle.addClip()
    let colors = ["#7DDCF9", "#6F9BF5", "#6B6FE8", "#9A7FF5", "#C0A6F7"].map { hex -> NSColor in
        let v = Int(hex.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    NSGradient(colors: colors)!.draw(in: body, angle: -55)
    // Soft light bloom in the upper left.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: body.minX + body.width * 0.25, y: body.maxY - body.height * 0.2), radius: 0,
              toCenter: NSPoint(x: body.minX + body.width * 0.25, y: body.maxY - body.height * 0.2), radius: body.width * 0.7,
              options: [])

    // The mark: a frosted rounded frame with a dot.
    let frame = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.26)
    let fp = NSBezierPath(roundedRect: frame, xRadius: frame.height * 0.2, yRadius: frame.height * 0.2)
    NSColor.white.withAlphaComponent(0.18).setFill()
    fp.fill()
    fp.lineWidth = s * 0.035
    NSColor.white.withAlphaComponent(0.95).setStroke()
    fp.stroke()
    let d = s * 0.12
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: frame.midX - d / 2, y: frame.midY - d / 2, width: d, height: d)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
