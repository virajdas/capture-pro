import Foundation

/// A damped harmonic spring, integrated with fixed sub-steps so results are deterministic
/// (preview and export always produce identical motion).
struct Spring {
    var stiffness: Double
    var damping: Double
    var mass: Double

    init(stiffness: Double, damping: Double, mass: Double = 1) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    /// SwiftUI-style parameters: `response` is the period of the undamped oscillation in seconds,
    /// `dampingFraction` is 1 for critical damping.
    init(response: Double, dampingFraction: Double) {
        let omega = 2 * Double.pi / max(response, 0.001)
        self.mass = 1
        self.stiffness = omega * omega
        self.damping = 2 * dampingFraction * omega
    }

    /// The steady-state lag (seconds) of this spring chasing a target moving at constant velocity.
    var lag: Double { damping / stiffness }

    func step(_ value: inout Double, _ velocity: inout Double, target: Double, dt: Double) {
        let sub = 4
        let h = dt / Double(sub)
        for _ in 0..<sub {
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force / mass * h
            value += velocity * h
        }
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = ((x - e0) / (e1 - e0)).clamped(0, 1)
    return t * t * (3 - 2 * t)
}
