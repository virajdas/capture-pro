import Foundation

/// The shape of a zoom transition. Curves are cubic Béziers (like CSS `cubic-bezier`),
/// plus a lightly-damped spring for a playful settle.
enum ZoomCurve: String, Codable, CaseIterable, Identifiable {
    case smooth, gentle, cinematic, snappy, bouncy, linear
    var id: String { rawValue }

    var label: String {
        switch self {
        case .smooth: "Smooth"
        case .gentle: "Gentle"
        case .cinematic: "Cinematic"
        case .snappy: "Snappy"
        case .bouncy: "Springy"
        case .linear: "Linear"
        }
    }

    var detail: String {
        switch self {
        case .smooth: "Eases in, then glides to a soft stop."
        case .gentle: "Symmetric and calm, like a slow breath."
        case .cinematic: "Slow, deliberate start with a long glide."
        case .snappy: "Quick to respond, settles softly."
        case .bouncy: "Settles with a tiny, natural overshoot."
        case .linear: "Constant speed. Mechanical; rarely ideal."
        }
    }

    private var bezier: (Double, Double, Double, Double)? {
        switch self {
        case .smooth: (0.42, 0, 0.18, 1)
        case .gentle: (0.37, 0, 0.63, 1)
        case .cinematic: (0.7, 0, 0.12, 1)
        case .snappy: (0.2, 0.7, 0.25, 1)
        case .linear: (0, 0, 1, 1)
        case .bouncy: nil
        }
    }

    /// Progress 0…1 → eased value (may slightly exceed 1 for `.bouncy`).
    func value(_ t: Double) -> Double {
        let t = t.clamped(0, 1)
        guard let b = bezier else {
            // Damped spring step response, nudged so it lands exactly on 1 at t = 1.
            let zeta = 0.55, omega = 11.0
            let wd = omega * sqrt(1 - zeta * zeta)
            func f(_ x: Double) -> Double {
                1 - exp(-zeta * omega * x) * (cos(wd * x) + zeta * omega / wd * sin(wd * x))
            }
            return f(t) + (1 - f(1)) * t
        }
        return Self.cubicBezier(b.0, b.1, b.2, b.3, t)
    }

    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func coord(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        func slope(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
        }
        // Newton's method, falling back to bisection where the slope is flat.
        var t = x
        for _ in 0..<8 {
            let d = slope(t, x1, x2)
            guard abs(d) > 1e-6 else { break }
            t -= (coord(t, x1, x2) - x) / d
        }
        if abs(coord(t, x1, x2) - x) > 1e-4 || t < 0 || t > 1 {
            var lo = 0.0, hi = 1.0
            t = x
            for _ in 0..<40 {
                if coord(t, x1, x2) < x { lo = t } else { hi = t }
                t = (lo + hi) / 2
            }
        }
        return coord(t, y1, y2)
    }
}
