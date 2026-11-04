import AppKit
import CoreImage

/// Immutable inputs for rendering frames. Swapped atomically when the user edits.
final class RenderState {
    let style: StyleSettings
    let canvas: CGSize
    let pointSize: CGSize
    let timeline: MotionTimeline?
    let sprites: [Int: CursorSprite]
    let fallback: CursorSprite
    /// Source time = composition time + offset (trimming).
    let timeOffset: Double
    /// Real-time preview: cheaper resampling so playback never drops frames.
    let preview: Bool
    let camera: CameraStyle

    init(style: StyleSettings, canvas: CGSize, pointSize: CGSize, timeline: MotionTimeline?,
         cursors: [Int: (CGImage, CursorImageInfo)], timeOffset: Double, preview: Bool = false,
         camera: CameraStyle = CameraStyle()) {
        self.preview = preview
        self.camera = camera
        self.style = style
        self.canvas = canvas
        self.pointSize = pointSize
        self.timeline = timeline
        self.timeOffset = timeOffset
        var sprites: [Int: CursorSprite] = [:]
        for (id, c) in cursors { sprites[id] = CursorArt.sprite(from: c.0, info: c.1, shadow: style.cursor.shadow) }
        self.sprites = sprites
        let arrow = CursorArt.defaultArrow()
        self.fallback = CursorArt.sprite(from: arrow.0, info: arrow.1, shadow: style.cursor.shadow)
    }

    /// Output canvas for a source of `source` pixels at a given short side.
    static func canvasSize(source: CGSize, style: StyleSettings, shortSide: Double) -> CGSize {
        let srcAspect = source.width / max(source.height, 1)
        let a = style.frame.aspect.value ?? srcAspect
        var w: Double, h: Double
        if a >= 1 { h = shortSide; w = shortSide * a } else { w = shortSide; h = shortSide / a }
        return CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
    }
}

final class Compositor {
    let background = BackgroundRenderer()
    private let lock = NSLock()
    private var _state: RenderState

    init(state: RenderState) { _state = state }

    // The frame's shadow never changes between frames, so it's blurred once and reused.
    private struct ShadowKey: Hashable {
        let canvas: CGSize, rect: CGRect, radius: Double, frame: FrameStyle
        func hash(into h: inout Hasher) { h.combine(rect.minX); h.combine(rect.width); h.combine(canvas.width); h.combine(frame) }
    }
    private var shadowCache: (ShadowKey, CIImage)?

    private func shadow(for rect: CGRect, radius: Double, canvas: CGSize, frame fs: FrameStyle, unit: Double) -> CIImage {
        let key = ShadowKey(canvas: canvas, rect: rect, radius: radius, frame: fs)
        lock.lock()
        if let c = shadowCache, c.0 == key { lock.unlock(); return c.1 }
        lock.unlock()
        let spread = fs.shadowSpread * unit
        let c = fs.shadowColor
        let shape = Self.roundedRect(rect.insetBy(dx: -spread, dy: -spread), radius: max(0, radius + spread),
                                     color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: fs.shadowOpacity))
        let blurred = shape
            .applyingGaussianBlur(sigma: max(0.1, fs.shadowRadius * unit / 2))
            .transformed(by: CGAffineTransform(translationX: fs.shadowOffsetX * unit, y: -fs.shadowOffset * unit))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        var image = blurred
        if let cg = CaptureVideoCompositor.context.createCGImage(blurred, from: blurred.extent) {
            image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: blurred.extent.minX, y: blurred.extent.minY))
        }
        lock.lock(); shadowCache = (key, image); lock.unlock()
        return image
    }

    var state: RenderState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    /// Composes one output frame. `time` is the composition time (seconds from trim start).
    func render(source: CIImage, camera: CIImage? = nil, time: Double) -> CIImage {
        let st = state
        let t = time + st.timeOffset
        let W = st.canvas.width, H = st.canvas.height
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let unit = min(W, H) / 1080
        let fs = st.style.frame

        let src = source.extent
        let screenRect = Self.screenRect(canvas: canvas, sourceAspect: src.width / src.height, padding: fs.padding)
        let m = st.timeline?.sample(at: t) ?? MotionSample()

        // Camera viewport in source pixels.
        let vw = src.width / m.camScale, vh = src.height / m.camScale
        let vx = m.camX * src.width - vw / 2
        let vyTop = m.camY * src.height - vh / 2
        let vyBottom = src.height - vyTop - vh
        let k = screenRect.width / vw

        var screen = source
            .cropped(to: CGRect(x: src.minX + vx, y: src.minY + vyBottom, width: vw, height: vh))
            .transformed(by: CGAffineTransform(translationX: -(src.minX + vx), y: -(src.minY + vyBottom)))
        if st.preview {
            screen = screen.samplingLinear().transformed(by: CGAffineTransform(scaleX: k, y: k))
        } else if abs(k - 1) > 0.001 {
            screen = screen.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: k, kCIInputAspectRatioKey: 1,
            ])
        }
        screen = screen.transformed(by: CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))

        // Camera motion blur: a radial smear while zooming, a directional one while panning.
        let mb = st.style.zoom.motionBlur
        if mb > 0.01 {
            let zoomAmt = abs(m.camVScale) * 4 * mb * unit
            let panX = m.camVX * screenRect.width * m.camScale / 60
            let panY = m.camVY * screenRect.height * m.camScale / 60
            let pan = hypot(panX, panY) * 0.12 * mb
            if zoomAmt > 0.5 {
                screen = screen.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: screenRect.midX, y: screenRect.midY),
                    kCIInputAmountKey: min(zoomAmt, 16 * unit),
                ])
            } else if pan > 0.75 {
                screen = screen.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: min(pan, 14 * unit),
                    kCIInputAngleKey: atan2(-panY, panX),
                ])
            }
            screen = screen.cropped(to: screenRect)
        }

        // Cursor and click effects live on the screen layer so rounded corners clip them.
        if st.style.cursor.visible, st.timeline != nil {
            let pxPerPoint = screenRect.width / (st.pointSize.width / m.camScale)
            func toCanvas(_ nx: Double, _ ny: Double) -> CGPoint {
                CGPoint(x: screenRect.minX + (nx * src.width - vx) * k,
                        y: screenRect.maxY - (ny * src.height - vyTop) * k)
            }
            screen = drawClicks(on: screen, st: st, t: t, pxPerPoint: pxPerPoint, toCanvas: toCanvas)
            if m.curAlpha > 0.01 {
                let sprite = st.timeline?.cursorID(at: t).flatMap { st.sprites[$0] } ?? st.fallback
                screen = drawCursor(sprite, on: screen, st: st, m: m, at: toCanvas(m.curX, m.curY),
                                    pxPerPoint: pxPerPoint, srcSize: src.size, k: k)
            }
        }

        let radius = fs.cornerRadius * unit
        let mask = Self.roundedRect(screenRect, radius: radius, color: .white)
        screen = screen.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])

        var out = background.image(style: st.style.background, size: st.canvas, time: t)
        if fs.shadowEnabled, fs.shadowOpacity > 0.01, fs.padding > 0.001 {
            out = shadow(for: screenRect, radius: radius, canvas: st.canvas, frame: fs, unit: unit).composited(over: out)
        }
        out = screen.composited(over: out)
        if fs.border {
            let stroke = CIFilter(name: "CIRoundedRectangleStrokeGenerator", parameters: [
                "inputExtent": CIVector(cgRect: screenRect.insetBy(dx: 0.5, dy: 0.5)),
                "inputRadius": max(0, radius - 0.5),
                "inputWidth": max(1, unit),
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 0.14),
            ])?.outputImage
            if let stroke { out = stroke.composited(over: out) }
        }
        if let camera, st.camera.visible {
            out = CameraLayer.draw(camera, style: st.camera, over: out, canvas: st.canvas, unit: unit)
        }
        return out.cropped(to: canvas)
    }

    private func drawCursor(_ sprite: CursorSprite, on screen: CIImage, st: RenderState, m: MotionSample,
                            at p: CGPoint, pxPerPoint: Double, srcSize: CGSize, k: Double) -> CIImage {
        let cs = st.style.cursor
        let press = 1 - (1 - cs.pressScale) * m.curPress
        let s = pxPerPoint * cs.size * press / sprite.density
        var img = sprite.image
            .transformed(by: CGAffineTransform(translationX: -sprite.hot.x, y: -sprite.hot.y))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        if cs.rotateWhileMoving {
            let tilt = (m.curVX * 0.04).clamped(-0.15, 0.15)
            img = img.transformed(by: CGAffineTransform(rotationAngle: -tilt))
        }
        img = img.transformed(by: CGAffineTransform(translationX: p.x, y: p.y))
        if cs.motionBlur > 0.01 {
            let vx = m.curVX * srcSize.width * k / 60, vy = -m.curVY * srcSize.height * k / 60
            let len = min(hypot(vx, vy), 480 * k)
            let r = len * 0.25 * cs.motionBlur
            if r > 1 {
                img = img.applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: min(r, 40), kCIInputAngleKey: atan2(vy, vx),
                ])
            }
        }
        if m.curAlpha < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m.curAlpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: m.curAlpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: m.curAlpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: m.curAlpha),
            ])
        }
        return img.composited(over: screen)
    }

    private func drawClicks(on screen: CIImage, st: RenderState, t: Double, pxPerPoint: Double,
                            toCanvas: (Double, Double) -> CGPoint) -> CIImage {
        let cs = st.style.cursor
        guard cs.clickEffect != .none, let tl = st.timeline else { return screen }
        var out = screen
        let base = cs.clickEffect == .ripple ? CursorArt.ring : CursorArt.halo
        let c = cs.clickColor
        for (click, p) in tl.activeClicks(at: t, duration: 0.6) {
            let ease = 1 - pow(1 - p, 3)
            let radius = 20 * 1.25 * cs.size * pxPerPoint * (0.25 + 0.75 * ease)
            let alpha = (1 - p) * (cs.clickEffect == .ripple ? 0.75 : 0.45) * c.a
            let pt = toCanvas(click.x, click.y)
            let s = radius * 2 / 256
            let tinted = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: c.r * alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: c.g * alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: c.b * alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
            out = tinted
                .transformed(by: CGAffineTransform(translationX: -128, y: -128))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: pt.x, y: pt.y))
                .composited(over: out)
        }
        return out
    }

    static func screenRect(canvas: CGRect, sourceAspect: Double, padding: Double) -> CGRect {
        let pad = padding * min(canvas.width, canvas.height)
        let avail = canvas.insetBy(dx: pad, dy: pad)
        var w = avail.width, h = w / sourceAspect
        if h > avail.height { h = avail.height; w = h * sourceAspect }
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h).integral
    }

    static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color,
        ])!.outputImage!
    }

    // MARK: Stills

    /// Beautifies a screenshot with the same background and frame as recordings.
    static func beautify(_ image: CGImage, style: StyleSettings, minimumPadding: Double = 0) -> CGImage? {
        var style = style
        style.frame.aspect = .auto
        style.frame.padding = max(style.frame.padding, minimumPadding)
        let src = CIImage(cgImage: image)
        let short = min(src.extent.width, src.extent.height)
        let canvasShort = short / max(0.4, 1 - 2 * style.frame.padding)
        var canvas = RenderState.canvasSize(source: src.extent.size, style: style, shortSide: canvasShort)
        // Keep the screenshot at 1:1 pixel scale.
        let rect = screenRect(canvas: CGRect(origin: .zero, size: canvas), sourceAspect: src.extent.width / src.extent.height,
                              padding: style.frame.padding)
        let fix = src.extent.width / rect.width
        canvas = CGSize(width: (canvas.width * fix).rounded(), height: (canvas.height * fix).rounded())
        let state = RenderState(style: style, canvas: canvas, pointSize: src.extent.size, timeline: nil,
                                cursors: [:], timeOffset: 0)
        let comp = Compositor(state: state)
        let out = comp.render(source: src, time: 0)
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return ctx.createCGImage(out, from: CGRect(origin: .zero, size: canvas),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
