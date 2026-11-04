import CoreImage

/// Draws the webcam bubble (or a chroma-keyed cutout) over the composed frame.
enum CameraLayer {
    static func draw(_ frame: CIImage, style cs: CameraStyle, over base: CIImage, canvas: CGSize, unit: Double) -> CIImage {
        var img = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
        let e = img.extent
        if cs.mirror {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -e.width, y: 0))
        }
        if cs.chromaKey { img = ChromaKey.apply(img, style: cs) }

        // Centre-crop to the shape's aspect.
        let aspect: Double = switch cs.shape {
        case .circle, .rounded: 1
        case .rectangle: 4.0 / 3
        case .cutout: e.width / e.height
        }
        var crop = e
        if e.width / e.height > aspect {
            crop.size.width = e.height * aspect
            crop.origin.x = (e.width - crop.width) / 2
        } else {
            crop.size.height = e.width / aspect
            crop.origin.y = (e.height - crop.height) / 2
        }
        let h = cs.size * canvas.height, w = h * aspect
        let rect = position(cs, size: CGSize(width: w, height: h), canvas: canvas)
        let s = h / crop.height
        img = img.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        var out = base
        if cs.shape == .cutout {
            if cs.shadow {
                let shadow = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
                ]).applyingGaussianBlur(sigma: 14 * unit)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -8 * unit))
                out = shadow.composited(over: out)
            }
            return img.composited(over: out)
        }

        let radius = cs.shape == .circle ? h / 2 : cs.shape == .rounded ? h * 0.2 : 10 * unit
        let mask = Compositor.roundedRect(rect, radius: radius, color: .white)
        img = img.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        if cs.shadow {
            let shadow = Compositor.roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4))
                .applyingGaussianBlur(sigma: 16 * unit)
                .transformed(by: CGAffineTransform(translationX: 0, y: -8 * unit))
            out = shadow.composited(over: out)
        }
        out = img.composited(over: out)
        if cs.border > 0.1 {
            let bw = cs.border * unit
            let c = cs.borderColor
            if let stroke = CIFilter(name: "CIRoundedRectangleStrokeGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect.insetBy(dx: bw / 2, dy: bw / 2)),
                "inputRadius": max(0, radius - bw / 2),
                "inputWidth": bw,
                "inputColor": CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a),
            ])?.outputImage {
                out = stroke.composited(over: out)
            }
        }
        return out
    }

    /// The camera's rectangle on the canvas (Core Image coordinates, bottom-left origin).
    static func position(_ cs: CameraStyle, size: CGSize, canvas: CGSize) -> CGRect {
        let m = cs.margin * min(canvas.width, canvas.height)
        let cx: Double
        var cyTop: Double
        switch cs.corner {
        case .bottomRight: cx = canvas.width - m - size.width / 2; cyTop = canvas.height - m - size.height / 2
        case .bottomLeft: cx = m + size.width / 2; cyTop = canvas.height - m - size.height / 2
        case .topRight: cx = canvas.width - m - size.width / 2; cyTop = m + size.height / 2
        case .topLeft: cx = m + size.width / 2; cyTop = m + size.height / 2
        case .custom: cx = cs.x * canvas.width; cyTop = cs.y * canvas.height
        }
        // A keyed cutout of a person reads best standing on the bottom edge.
        if cs.shape == .cutout, cs.corner == .bottomLeft || cs.corner == .bottomRight {
            cyTop = canvas.height - size.height / 2
        }
        return CGRect(x: cx - size.width / 2, y: canvas.height - cyTop - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Chroma key in YCbCr space: distance from the key colour in the colour plane decides
/// transparency (so shadows and dim lighting on the screen still key cleanly), with a soft
/// edge and spill suppression that removes the key colour's tint from hair and edges.
enum ChromaKey {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 chroma(__sample s, __sample blurred, vec2 key, vec3 keyDir, float threshold, float softness, float spill) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : s.rgb;
        vec3 b = blurred.a > 0.0 ? blurred.rgb / blurred.a : blurred.rgb;
        float yb = dot(b, vec3(0.2126, 0.7152, 0.0722));
        vec2 cc = vec2((b.b - yb) / 1.8556, (b.r - yb) / 1.5748);
        float d = distance(cc, key);
        float a = smoothstep(threshold, threshold + softness, d);
        float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float p = max(0.0, dot(c - vec3(y), keyDir));
        float near = 1.0 - smoothstep(threshold, threshold + softness + 0.3, d);
        c = clamp(c - keyDir * p * spill * (0.35 + 0.65 * near), 0.0, 1.0);
        a *= s.a;
        return vec4(c * a, a);
    }
    """)

    static func apply(_ image: CIImage, style cs: CameraStyle) -> CIImage {
        guard let kernel else { return image }
        let k = cs.keyColor
        let y = 0.2126 * k.r + 0.7152 * k.g + 0.0722 * k.b
        let key = CIVector(x: (k.b - y) / 1.8556, y: (k.r - y) / 1.5748)
        var dir = (k.r - y, k.g - y, k.b - y)
        let len = max(1e-4, sqrt(dir.0 * dir.0 + dir.1 * dir.1 + dir.2 * dir.2))
        dir = (dir.0 / len, dir.1 / len, dir.2 / len)
        // A slightly blurred copy decides the matte, hiding 4:2:0 chroma blockiness at edges.
        let smooth = image.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: image.extent)
        return kernel.apply(extent: image.extent, arguments: [
            image, smooth, key, CIVector(x: dir.0, y: dir.1, z: dir.2),
            cs.threshold, cs.softness, cs.spill,
        ]) ?? image
    }

    /// Guesses the backdrop colour from the frame's border (median of the outer edge pixels).
    static func detect(in image: CIImage) -> RGBA? {
        let w = 64, h = 36
        let e = image.extent
        let small = image.transformed(by: CGAffineTransform(scaleX: Double(w) / e.width, y: Double(h) / e.height)
            .translatedBy(x: -e.minX, y: -e.minY))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        CaptureVideoCompositor.context.render(small, toBitmap: &px, rowBytes: w * 4,
                                              bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        for yy in 0..<h {
            for xx in 0..<w where yy < 3 || yy >= h - 3 || xx < 3 || xx >= w - 3 {
                let i = (yy * w + xx) * 4
                rs.append(Double(px[i]) / 255); gs.append(Double(px[i + 1]) / 255); bs.append(Double(px[i + 2]) / 255)
            }
        }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        guard !rs.isEmpty else { return nil }
        return RGBA(median(rs), median(gs), median(bs))
    }
}
