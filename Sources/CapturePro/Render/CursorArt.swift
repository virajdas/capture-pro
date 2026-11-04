import AppKit
import CoreImage

/// A cursor ready to composite: a high-resolution image with a baked soft shadow.
struct CursorSprite {
    let image: CIImage
    /// Pixels per logical point in `image`.
    let density: Double
    /// Logical point size of the cursor (without shadow padding).
    let height: Double
    /// Hot spot in image pixels, bottom-left origin.
    let hot: CGPoint
}

enum CursorArt {
    static let density = 6.0
    static let shadowPad = 4.0

    /// Renders an `NSImage` cursor at high resolution into a PNG-ready image.
    static func render(_ image: NSImage, size: NSSize) -> CGImage? {
        let w = Int(ceil(size.width * density)), h = Int(ceil(size.height * density))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func sprite(from cg: CGImage, info: CursorImageInfo, shadow: Bool) -> CursorSprite {
        let pad = shadowPad * density
        let w = cg.width + Int(pad * 2), h = cg.height + Int(pad * 2)
        var out = cg
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            if shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * density), blur: 2.2 * density,
                              color: CGColor(gray: 0, alpha: 0.38))
            }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: pad, y: pad, width: Double(cg.width), height: Double(cg.height)))
            if let img = ctx.makeImage() { out = img }
        }
        let d = Double(cg.width) / max(info.width, 1)
        return CursorSprite(
            image: CIImage(cgImage: out),
            density: d,
            height: info.height,
            hot: CGPoint(x: pad + info.hotX * d, y: pad + (info.height - info.hotY) * d))
    }

    /// A crisp macOS-style arrow, used when no system cursor shape was recorded.
    static func defaultArrow() -> (CGImage, CursorImageInfo) {
        let size = NSSize(width: 17, height: 25)
        let img = NSImage(size: size, flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 1.5, y: 1.5))
            p.line(to: NSPoint(x: 1.5, y: 19.5))
            p.line(to: NSPoint(x: 5.8, y: 15.4))
            p.line(to: NSPoint(x: 8.8, y: 22.3))
            p.line(to: NSPoint(x: 11.6, y: 21.1))
            p.line(to: NSPoint(x: 8.7, y: 14.4))
            p.line(to: NSPoint(x: 14.6, y: 14.4))
            p.close()
            p.lineJoinStyle = .round
            NSColor.white.setStroke()
            p.lineWidth = 2.2
            p.stroke()
            NSColor.black.setFill()
            p.fill()
            return true
        }
        let cg = render(img, size: size)!
        return (cg, CursorImageInfo(id: -1, width: size.width, height: size.height, hotX: 1.5, hotY: 1.5, file: ""))
    }

    /// A soft ring used for click ripples (white; tinted at render time).
    static let ring: CIImage = {
        let s = 256
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(14)
        ctx.setShadow(offset: .zero, blur: 10, color: CGColor(gray: 1, alpha: 0.8))
        ctx.strokeEllipse(in: CGRect(x: 20, y: 20, width: s - 40, height: s - 40))
        return CIImage(cgImage: ctx.makeImage()!)
    }()

    /// A soft filled glow used for the "halo" click effect.
    static let halo: CIImage = {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 128, y: 128),
            "inputRadius0": 40, "inputRadius1": 128,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.9),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
    }()
}
