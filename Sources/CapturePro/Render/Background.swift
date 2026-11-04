import AppKit
import CoreImage

/// Renders backgrounds: flowing mesh gradients, linear gradients, solids and images,
/// all finished with a fine static grain to avoid banding.
final class BackgroundRenderer {
    private let lock = NSLock()
    private var grainCache: (CGSize, Double, CIImage)?
    private var imageCache: (String, CGSize, Double, CIImage)?

    // Flowing gradient: five soft color fields drifting on Lissajous paths, with a gentle domain warp.
    // Rendered at 1/8 resolution and upscaled; the field is smooth so nothing is lost.
    private static let meshKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 mesh(vec2 size, float t, vec4 c0, vec4 c1, vec4 c2, vec4 c3, vec4 c4,
                     vec2 p0, vec2 p1, vec2 p2, vec2 p3, vec2 p4) {
        float aspect = size.x / size.y;
        vec2 uv = destCoord() / size;
        uv.y = 1.0 - uv.y;
        uv += 0.045 * vec2(sin(uv.y * 3.1 + t * 0.9), cos(uv.x * 2.7 - t * 0.7));
        vec2 q = vec2(uv.x * aspect, uv.y);
        float w0 = exp(-3.2 * pow(distance(q, vec2(p0.x * aspect, p0.y)), 2.0)) + 0.0001;
        float w1 = exp(-3.2 * pow(distance(q, vec2(p1.x * aspect, p1.y)), 2.0)) + 0.0001;
        float w2 = exp(-3.2 * pow(distance(q, vec2(p2.x * aspect, p2.y)), 2.0)) + 0.0001;
        float w3 = exp(-3.2 * pow(distance(q, vec2(p3.x * aspect, p3.y)), 2.0)) + 0.0001;
        float w4 = exp(-3.2 * pow(distance(q, vec2(p4.x * aspect, p4.y)), 2.0)) + 0.0001;
        vec3 c = (c0.rgb * w0 + c1.rgb * w1 + c2.rgb * w2 + c3.rgb * w3 + c4.rgb * w4)
                 / (w0 + w1 + w2 + w3 + w4);
        return vec4(c, 1.0);
    }
    """)

    private var staticCache: (BackgroundStyle, CGSize, CIImage)?

    func image(style: BackgroundStyle, size: CGSize, time: Double) -> CIImage {
        let isStatic = !style.animated || style.kind == .solid || style.kind == .wallpaper || style.kind == .image
        if isStatic {
            lock.lock()
            if let c = staticCache, c.0 == style, c.1 == size { lock.unlock(); return c.2 }
            lock.unlock()
            var img = compose(style: style, size: size, time: 0)
            if let cg = CaptureVideoCompositor.context.createCGImage(img, from: img.extent) { img = CIImage(cgImage: cg) }
            lock.lock(); staticCache = (style, size, img); lock.unlock()
            return img
        }
        return compose(style: style, size: size, time: time)
    }

    private func compose(style: BackgroundStyle, size: CGSize, time: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var base: CIImage
        switch style.kind {
        case .mesh:
            base = mesh(style: style, size: size, time: time)
        case .linear:
            base = linear(style: style, size: size, time: time)
        case .solid:
            base = CIImage(color: CIColor(cgColor: style.solid.cgColor)).cropped(to: rect)
        case .wallpaper, .image:
            let path = style.kind == .wallpaper ? Self.desktopImagePath() : style.imagePath
            if let path, let img = picture(path: path, size: size, blur: style.imageBlur) {
                base = img
            } else {
                base = mesh(style: style, size: size, time: time)
            }
        }
        if style.grain > 0.001 {
            base = grain(size: size, amount: style.grain)
                .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: base])
        }
        return base.cropped(to: rect)
    }

    private func phase(_ style: BackgroundStyle, _ time: Double) -> Double {
        style.animated ? time / max(style.cycleSeconds, 4) * 2 * .pi : 0
    }

    private func mesh(style: BackgroundStyle, size: CGSize, time: Double) -> CIImage {
        var colors = style.colors
        while colors.count < 5 { colors.append(colors[colors.count % max(colors.count, 1)]) }
        let t = phase(style, time)
        let anchors: [(Double, Double, Double, Double)] = [
            (0.15, 0.2, 1.0, 0.0), (0.85, 0.15, 0.8, 1.7), (0.8, 0.85, 1.1, 3.1),
            (0.2, 0.85, 0.9, 4.4), (0.5, 0.5, 0.7, 2.3),
        ]
        let pts = anchors.map { a -> CIVector in
            CIVector(x: a.0 + 0.22 * sin(t * a.2 + a.3), y: a.1 + 0.18 * cos(t * a.2 * 0.83 + a.3))
        }
        let small = CGSize(width: max(8, ceil(size.width / 4)), height: max(8, ceil(size.height / 4)))
        let cvs = colors.prefix(5).map { CIVector(x: $0.r, y: $0.g, z: $0.b, w: 1) }
        let args: [Any] = [CIVector(x: small.width, y: small.height), t] + cvs + pts
        guard let k = Self.meshKernel,
              let low = k.apply(extent: CGRect(origin: .zero, size: small), arguments: args) else {
            return CIImage(color: CIColor(cgColor: colors[0].cgColor))
        }
        // The field is smooth, so bilinear upscaling from quarter resolution is indistinguishable
        // (the grain hides any residue) and costs a fraction of a full-resolution blur.
        return low.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: size.width / small.width, y: size.height / small.height))
    }

    private func linear(style: BackgroundStyle, size: CGSize, time: Double) -> CIImage {
        let small = CGSize(width: max(8, ceil(size.width / 4)), height: max(8, ceil(size.height / 4)))
        let colors = style.colors.map(\.cgColor) as CFArray
        let angle = (style.angle + (style.animated ? 18 * sin(phase(style, time)) : 0)) * .pi / 180
        guard let ctx = CGContext(data: nil, width: Int(small.width), height: Int(small.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)
        else { return CIImage.empty() }
        let c = CGPoint(x: small.width / 2, y: small.height / 2)
        let r = hypot(small.width, small.height) / 2
        let d = CGPoint(x: cos(angle) * r, y: -sin(angle) * r)
        ctx.drawLinearGradient(grad, start: CGPoint(x: c.x - d.x, y: c.y - d.y),
                               end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg).samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: size.width / small.width, y: size.height / small.height))
    }

    private func picture(path: String, size: CGSize, blur: Double) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = imageCache, c.0 == path, c.1 == size, c.2 == blur { return c.3 }
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let e = img.extent
        let s = max(size.width / e.width, size.height / e.height)
        var out = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        out = out.transformed(by: CGAffineTransform(translationX: (size.width - out.extent.width) / 2 - out.extent.minX,
                                                    y: (size.height - out.extent.height) / 2 - out.extent.minY))
        if blur > 0.5 {
            out = out.clampedToExtent().applyingGaussianBlur(sigma: blur * min(size.width, size.height) / 1080)
        }
        out = out.cropped(to: CGRect(origin: .zero, size: size))
        // Flatten once so per-frame cost is a texture read.
        if let cg = CaptureVideoCompositor.context.createCGImage(out, from: out.extent) {
            out = CIImage(cgImage: cg)
        }
        imageCache = (path, size, blur, out)
        return out
    }

    private func grain(size: CGSize, amount: Double) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let g = grainCache, g.0 == size, g.1 == amount { return g.2 }
        let k = amount * 0.6
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(origin: .zero, size: size))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 1),
            ])
        grainCache = (size, amount, noise)
        return noise
    }

    static func desktopImagePath() -> String? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url.path
    }
}
