import CoreGraphics
import Foundation

/// Complete, curated looks: background, frame, cursor and camera feel in one tap.
struct LookPreset: Identifiable {
    let id: String
    let name: String
    let note: String
    let make: (inout StyleSettings) -> Void

    /// The preset applied on top of the defaults (so nothing from the previous look leaks through).
    func style(keepingAutoZoom current: StyleSettings? = nil) -> StyleSettings {
        var s = StyleSettings()
        make(&s)
        if let current {
            s.zoom.auto = current.zoom.auto
            s.zoom.zoomOnTyping = current.zoom.zoomOnTyping
        }
        return s
    }

    static func mesh(_ s: inout StyleSettings, _ palette: String) {
        s.background.kind = .mesh
        s.background.paletteID = palette
        s.background.useCustomColors = false
    }

    static let all: [LookPreset] = [
        LookPreset(id: "studio", name: "Studio", note: "The balanced default") { s in mesh(&s, "candy") },
        LookPreset(id: "minimal", name: "Minimal", note: "Quiet light canvas") { s in
            s.background.kind = .solid
            s.background.solid = RGBA(hex: "#EEEEF1")
            s.background.grain = 0
            s.frame.padding = 0.06; s.frame.cornerRadius = 12; s.frame.shadowOpacity = 0.22; s.frame.border = false
        },
        LookPreset(id: "midnight", name: "Midnight", note: "Deep, focused, dark") { s in
            mesh(&s, "midnight"); s.frame.shadowOpacity = 0.6
        },
        LookPreset(id: "keynote", name: "Keynote", note: "Stage-ready graphite") { s in
            s.background.kind = .linear; s.background.paletteID = "graphite"; s.background.angle = 120
            s.frame.padding = 0.1; s.frame.cornerRadius = 18
            s.zoom.curve = .cinematic; s.zoom.scale = 1.8; s.zoom.zoomInDuration = 1.2; s.zoom.zoomOutDuration = 1.3
        },
        LookPreset(id: "calm", name: "Calm", note: "Slow, gentle camera") { s in
            mesh(&s, "sage"); s.background.cycleSeconds = 45
            s.zoom.curve = .gentle; s.zoom.scale = 1.6; s.zoom.zoomInDuration = 1.4; s.zoom.zoomOutDuration = 1.5
            s.zoom.response = 1.6; s.cursor.smoothing = 0.75
        },
        LookPreset(id: "cinematic", name: "Cinematic", note: "Long glides, soft blur") { s in
            mesh(&s, "ink"); s.frame.shadowOpacity = 0.7; s.frame.padding = 0.07
            s.zoom.curve = .cinematic; s.zoom.zoomInDuration = 1.5; s.zoom.zoomOutDuration = 1.6; s.zoom.motionBlur = 0.25
        },
        LookPreset(id: "snappy", name: "Snappy Demo", note: "Quick, energetic product demo") { s in
            mesh(&s, "ember"); s.background.cycleSeconds = 18
            s.zoom.curve = .snappy; s.zoom.scale = 2.2; s.zoom.zoomInDuration = 0.6; s.zoom.zoomOutDuration = 0.7
            s.zoom.response = 0.6; s.cursor.smoothing = 0.4
        },
        LookPreset(id: "springy", name: "Playful", note: "A tiny bounce on every zoom") { s in
            mesh(&s, "sunrise"); s.frame.cornerRadius = 20; s.frame.padding = 0.1
            s.zoom.curve = .bouncy; s.cursor.clickEffect = .halo
        },
        LookPreset(id: "tutorial", name: "Tutorial", note: "Big cursor, clear clicks") { s in
            mesh(&s, "mint"); s.zoom.scale = 2.2; s.cursor.size = 2.1; s.cursor.clickEffect = .halo
            s.cursor.clickColor = RGBA(hex: "#FFB020"); s.cursor.hideWhenIdle = false
        },
        LookPreset(id: "aurora", name: "Aurora", note: "Northern-lights drift") { s in
            mesh(&s, "aurora"); s.background.cycleSeconds = 20
        },
        LookPreset(id: "paper", name: "Paper", note: "Warm, tactile neutral") { s in
            mesh(&s, "sand"); s.background.grain = 0.09
            s.frame.cornerRadius = 10; s.frame.shadowOpacity = 0.3
        },
        LookPreset(id: "ocean", name: "Ocean", note: "Cool blues and teal") { s in mesh(&s, "ocean") },
        LookPreset(id: "glass", name: "Glass", note: "Airy, extra padding") { s in
            mesh(&s, "cotton"); s.frame.padding = 0.14; s.frame.cornerRadius = 24; s.frame.shadowOpacity = 0.35
        },
        LookPreset(id: "neon", name: "Neon", note: "Vivid night gradient") { s in
            mesh(&s, "nebula"); s.frame.shadowOpacity = 0.7; s.background.cycleSeconds = 16
        },
        LookPreset(id: "glacier", name: "Glacier", note: "Crisp icy light") { s in mesh(&s, "glacier") },
        LookPreset(id: "forest", name: "Forest", note: "Deep greens") { s in mesh(&s, "forest"); s.frame.shadowOpacity = 0.55 },
        LookPreset(id: "rose", name: "Rosé", note: "Soft pinks") { s in mesh(&s, "rose") },
        LookPreset(id: "desktop", name: "Desktop", note: "Your wallpaper, softly blurred") { s in
            s.background.kind = .wallpaper; s.background.imageBlur = 24
        },
        LookPreset(id: "vertical", name: "Vertical", note: "9:16 for Shorts, Reels, TikTok") { s in
            mesh(&s, "dusk"); s.frame.aspect = .vertical; s.frame.padding = 0.05
            s.zoom.scale = 2.4; s.cursor.size = 2.0
        },
        LookPreset(id: "square", name: "Square", note: "1:1 for social feeds") { s in
            mesh(&s, "lavender"); s.frame.aspect = .square; s.frame.padding = 0.06; s.zoom.scale = 2.2
        },
        LookPreset(id: "edge", name: "Edge to Edge", note: "No frame — just camera and cursor polish") { s in
            s.frame.padding = 0; s.frame.cornerRadius = 0; s.frame.shadowOpacity = 0; s.frame.border = false
        },
    ]

    /// Small rendered previews, cached per preset.
    @MainActor static var thumbnails: [String: CGImage] = [:]

    @MainActor static func thumbnail(for preset: LookPreset) async -> CGImage? {
        if let t = thumbnails[preset.id] { return t }
        let style = preset.style()
        let img = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let window = placeholderWindow(aspect: style.frame.aspect.value) else { return nil }
            return Compositor.beautify(window, style: style, minimumPadding: 0.05)
        }.value
        thumbnails[preset.id] = img
        return img
    }

    /// A tiny stand-in app window used to preview looks.
    static func placeholderWindow(aspect: Double?) -> CGImage? {
        let w = 320, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: h))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 10 + i * 12, y: h - 16, width: 8, height: 8))
        }
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        for i in 0..<5 { ctx.fill(CGRect(x: 12, y: h - 40 - i * 20, width: 50, height: 6)) }
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 120, width: 150, height: 10))
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 96, width: 190, height: 8)); ctx.fill(CGRect(x: 100, y: 80, width: 160, height: 8))
        return ctx.makeImage()
    }
}
