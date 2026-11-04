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
        Palette("peach", "Peach", ["#FFDAB9", "#FFB6A3", "#FFC8DD", "#FFE5B4", "#F7A9A8"]),
        Palette("glacier", "Glacier", ["#E0F7FA", "#B2EBF2", "#A7C7E7", "#D6E6F2", "#8FB8DE"]),
        Palette("forest", "Forest", ["#1B4332", "#2D6A4F", "#40916C", "#081C15", "#52B788"]),
        Palette("rose", "Rosé", ["#F4C2C2", "#E8A0BF", "#D5A6BD", "#FADADD", "#C38D9E"]),
        Palette("citrus", "Citrus", ["#FFF176", "#FFD54F", "#AED581", "#FFB74D", "#DCE775"]),
        Palette("nebula", "Nebula", ["#2B1055", "#7597DE", "#D53369", "#3A1C71", "#8E2DE2"]),
        Palette("coral", "Coral Reef", ["#FF7F50", "#FF6F91", "#2EC4B6", "#FFBF69", "#CBF3F0"]),
        Palette("slate", "Slate", ["#5D6D7E", "#85929E", "#AEB6BF", "#34495E", "#99A3A4"]),
        Palette("matcha", "Matcha", ["#C5D86D", "#A3B18A", "#DAD7CD", "#88A47C", "#E9EDC9"]),
        Palette("boulevard", "Boulevard", ["#2E1437", "#C33764", "#1D2671", "#F7797D", "#6A3093"]),
        Palette("cotton", "Cotton Candy", ["#FBC2EB", "#A6C1EE", "#FDCBF1", "#E6DEE9", "#C2E9FB"]),
        Palette("ink", "Ink", ["#0F0F0F", "#1A1A2E", "#16213E", "#0F3460", "#202020"]),
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
    /// Zoom starts this long before the click, so it arrives as the click happens.
    var leadIn: Double = 0.8
    /// How long the zoom lingers after the last click (includes zooming back out).
    var hold: Double = 2.4
    var mergeGap: Double = 2.5
    var curve: ZoomCurve = .smooth
    var zoomInDuration: Double = 0.9
    var zoomOutDuration: Double = 1.1
    /// How softly the camera pans to follow the cursor while zoomed (spring response, seconds).
    var response: Double = 1.0
    var followCursor = true
    var zoomOnTyping = true
    var motionBlur: Double = 0
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
    var shadowEnabled = true
    var shadowColor: RGBA = RGBA(0, 0, 0)
    var shadowRadius: Double = 40
    var shadowOpacity: Double = 0.45
    var shadowOffsetX: Double = 0
    /// Vertical offset (positive = down).
    var shadowOffset: Double = 14
    /// Grows (or shrinks) the shadow's shape before blurring.
    var shadowSpread: Double = 0
    var border = true
    var aspect: AspectRatio = .auto
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded, rectangle, cutout
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: "Circle"
        case .rounded: "Rounded"
        case .rectangle: "Rectangle"
        case .cutout: "Cutout"
        }
    }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        case .topRight: "Top right"
        case .topLeft: "Top left"
        case .custom: "Custom"
        }
    }
}

/// How the webcam appears over a recording.
struct CameraStyle: Codable, Hashable {
    var visible = true
    var shape: CameraShape = .circle
    /// Height as a fraction of the canvas height.
    var size: Double = 0.26
    /// Width ÷ height for rounded and rectangle shapes (circles are always 1).
    var aspect: Double = 1
    /// Corner radius as a fraction of the shorter side (0 = square corners, 0.5 = pill).
    var cornerRadius: Double = 0.18
    var corner: CameraCorner = .bottomRight
    /// Centre for `.custom`, normalized with a top-left origin.
    var x: Double = 0.84
    var y: Double = 0.78
    var margin: Double = 0.035
    var mirror = true
    var border: Double = 3
    var borderColor: RGBA = RGBA(1, 1, 1, 0.9)
    var shadow = true
    var chromaKey = false
    var keyColor: RGBA = RGBA(hex: "#00B140")
    var threshold: Double = 0.1
    var softness: Double = 0.08
    var spill: Double = 0.6
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
