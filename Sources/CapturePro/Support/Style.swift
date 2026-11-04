import Foundation
import CoreGraphics

/// An sRGB color that survives JSON round-trips.
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct Palette: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [RGBA]

    init(_ id: String, _ name: String, _ hex: [String]) {
        self.id = id; self.name = name; self.colors = hex.map(RGBA.init(hex:))
    }

    /// Calm, curated palettes. Adjacent hues blend softly without muddy midpoints.
    static let all: [Palette] = [
        Palette("candy", "Cool Candy", ["#7DDCF9", "#6F9BF5", "#6B6FE8", "#9A7FF5", "#C0A6F7"]),
        Palette("dusk", "Dusk", ["#FF9A8B", "#FF6A88", "#C86DD7", "#7B6CF6", "#FFB88C"]),
        Palette("sage", "Sage", ["#A8C3A0", "#6E9F8D", "#D8E2C8", "#4F7A6B", "#C9D8B6"]),
        Palette("ocean", "Ocean", ["#0F2D52", "#1E6091", "#168AAD", "#52B69A", "#1A4E80"]),
        Palette("lavender", "Lavender Mist", ["#E0C3FC", "#B8B5FF", "#8EC5FC", "#F3D7F5", "#A79BFF"]),
        Palette("sunrise", "Sunrise", ["#FFD3A5", "#FD6585", "#FFA07A", "#FFE29F", "#F78CA0"]),
        Palette("midnight", "Midnight", ["#0B0B1A", "#1C1F4A", "#3A2C6B", "#141E30", "#243B55"]),
        Palette("aurora", "Aurora", ["#00C9A7", "#845EC2", "#2C73D2", "#008F7A", "#4FFBDF"]),
        Palette("sand", "Sand", ["#EFE6DA", "#D9C3A5", "#C8A27C", "#F5EFE6", "#B98B5E"]),
        Palette("graphite", "Graphite", ["#2B2D31", "#3D4048", "#1E1F22", "#53565F", "#2F3237"]),
        Palette("mint", "Mint", ["#D4FC79", "#96E6A1", "#5EE7DF", "#B4F8C8", "#7FD8BE"]),
        Palette("ember", "Ember", ["#F83600", "#F9D423", "#FF4E50", "#FC913A", "#E1306C"]),
    ]

    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? all[0] }
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case mesh, linear, solid, wallpaper, image
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mesh: "Flow"
        case .linear: "Gradient"
        case .solid: "Solid"
        case .wallpaper: "Desktop"
        case .image: "Image"
        }
    }
}

struct BackgroundStyle: Codable, Hashable {
    var kind: BackgroundKind = .mesh
    var paletteID: String = "candy"
    var useCustomColors = false
    var customColors: [RGBA] = [RGBA(hex: "#8EC5FC"), RGBA(hex: "#E0C3FC")]
    var solid: RGBA = RGBA(hex: "#1C1C1E")
    var angle: Double = 135
    var animated = true
    /// Seconds per full drift cycle.
    var cycleSeconds: Double = 28
    var grain: Double = 0.05
    var imagePath: String? = nil
    var imageBlur: Double = 0

    var colors: [RGBA] {
        useCustomColors ? customColors : Palette.named(paletteID).colors
    }
}

enum CursorEffect: String, Codable, CaseIterable, Identifiable {
    case none, ripple, halo
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct CursorStyle: Codable, Hashable {
    var visible = true
    /// Multiplier on the recorded cursor's logical size.
    var size: Double = 1.6
    /// 0 = raw, 1 = very smooth. Maps onto Cap-style spring presets.
    var smoothing: Double = 0.55
    var hideWhenIdle = true
    var idleSeconds: Double = 2.0
    var clickEffect: CursorEffect = .ripple
    var clickColor: RGBA = RGBA(hex: "#5B8CFF")
    var pressScale: Double = 0.82
    var motionBlur: Double = 0.4
    var shadow = true
    var rotateWhileMoving = false
}

struct ZoomStyle: Codable, Hashable {
    var auto = true
    var scale: Double = 2.0
    var leadIn: Double = 0.45
    var hold: Double = 2.0
    var mergeGap: Double = 2.5
    /// Camera spring response in seconds (Cap "ScreenMovementSpring" ≈ 0.67 s / ζ 0.94).
    var response: Double = 0.7
    var damping: Double = 0.95
    var followCursor = true
    var zoomOnTyping = true
    var motionBlur: Double = 0.5
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto, wide = "16:9", vertical = "9:16", square = "1:1", classic = "4:3", portrait = "4:5"
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : rawValue }
    var value: Double? {
        switch self {
        case .auto: nil
        case .wide: 16.0 / 9
        case .vertical: 9.0 / 16
        case .square: 1
        case .classic: 4.0 / 3
        case .portrait: 4.0 / 5
        }
    }
}

struct FrameStyle: Codable, Hashable {
    /// Fraction of the shorter canvas side.
    var padding: Double = 0.08
    /// Pixels at a 1080p reference canvas; scaled with output size.
    var cornerRadius: Double = 14
    var shadowRadius: Double = 40
    var shadowOpacity: Double = 0.45
    var shadowOffset: Double = 14
    var border = true
    var aspect: AspectRatio = .auto
}

/// Everything that controls how a recording (or a beautified screenshot) looks.
struct StyleSettings: Codable, Hashable {
    var background = BackgroundStyle()
    var frame = FrameStyle()
    var cursor = CursorStyle()
    var zoom = ZoomStyle()
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case mp4, mov, gif
    var id: String { rawValue }
    var label: String { self == .gif ? "GIF" : rawValue.uppercased() }
}

enum ExportCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264 (compatible)" : "HEVC (smaller)" }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case p720 = "720p", p1080 = "1080p", p1440 = "1440p", p2160 = "4K"
    var id: String { rawValue }
    var shortSide: Double {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        }
    }
}

enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    case web = "Web", social = "High", maximum = "Maximum"
    var id: String { rawValue }
    /// Bits per pixel per frame.
    var bpp: Double {
        switch self {
        case .web: 0.08
        case .social: 0.16
        case .maximum: 0.3
        }
    }
}

struct ExportSettings: Codable, Hashable {
    var format: ExportFormat = .mp4
    var codec: ExportCodec = .h264
    var resolution: ExportResolution = .p1440
    var fps: Int = 60
    var quality: ExportQuality = .social
    var gifFPS: Int = 15
    var gifWidth: Int = 960
}
