import Foundation

/// Turns clicks and typing into zoom segments.
///
/// Heuristics follow what Cap and Screen Studio do: each click opens a window from a short
/// lead-in before it to a hold after it, windows closer than `mergeGap` merge, and
/// typing bursts zoom on where the user last clicked. See docs/RESEARCH.md.
enum ZoomPlanner {
    static func generate(input: InputLog, duration: Double, style: ZoomStyle) -> [ZoomSegment] {
        guard duration > 1.5 else { return [] }

        struct Activity { var start: Double; var end: Double; var x: Double; var y: Double }
        var acts: [Activity] = []

        // Left-button presses, double-clicks collapsed, nothing in the last second.
        var lastClick = -10.0
        for c in input.clicks where !c.up && !c.right {
            guard c.t < duration - 1.0 else { continue }
            if c.t - lastClick < 0.4 { continue }
            lastClick = c.t
            acts.append(Activity(start: c.t, end: c.t, x: c.x, y: c.y))
        }

        if style.zoomOnTyping, !input.keys.isEmpty {
            var burstStart = input.keys[0], prev = input.keys[0], count = 1
            func flush() {
                guard prev - burstStart >= 1.0, count >= 4, burstStart < duration - 1.0 else { return }
                let p = input.clicks.last(where: { !$0.up && $0.t <= burstStart })
                    .map { (x: $0.x, y: $0.y) } ?? cursor(input.moves, at: burstStart)
                acts.append(Activity(start: burstStart, end: prev, x: p.x, y: p.y))
            }
            for k in input.keys.dropFirst() {
                if k - prev < 1.5 { count += 1 } else { flush(); burstStart = k; count = 1 }
                prev = k
            }
            flush()
        }
        acts.sort { $0.start < $1.start }

        var segs: [(s: Double, e: Double, pts: [(Double, Double)])] = []
        for a in acts {
            let s = max(0, a.start - style.leadIn)
            let e = min(duration - 0.3, a.end + style.hold)
            if let last = segs.last, s - last.e <= style.mergeGap {
                segs[segs.count - 1].e = max(last.e, e)
                segs[segs.count - 1].pts.append((a.x, a.y))
            } else {
                segs.append((s, e, [(a.x, a.y)]))
            }
        }

        return segs.compactMap { seg in
            guard seg.e - seg.s >= 1.0 else { return nil }
            // A cluster spread across most of the screen would make a tight zoom feel frantic.
            let xs = seg.pts.map(\.0), ys = seg.pts.map(\.1)
            let spread = max((xs.max()! - xs.min()!), (ys.max()! - ys.min()!))
            var scale = style.scale
            if spread > 0.7 { scale = max(1.5, scale * 0.8) }
            return ZoomSegment(start: seg.s, end: seg.e, scale: scale)
        }
    }

    static func cursor(_ moves: [MoveSample], at t: Double) -> (x: Double, y: Double) {
        guard let first = moves.first else { return (0.5, 0.5) }
        if t <= first.t { return (first.x, first.y) }
        guard let last = moves.last, t < last.t else { return (moves.last!.x, moves.last!.y) }
        var lo = 0, hi = moves.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if moves[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = moves[lo], b = moves[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return (lerp(a.x, b.x, f), lerp(a.y, b.y, f))
    }
}

/// The camera and cursor state at one moment.
struct MotionSample {
    var camScale = 1.0
    var camX = 0.5, camY = 0.5
    var camVScale = 0.0, camVX = 0.0, camVY = 0.0
    var curX = 0.5, curY = 0.5
    var curVX = 0.0, curVY = 0.0
    var curAlpha = 1.0
    var curPress = 0.0
}

/// Deterministic, pre-simulated motion for the whole recording, sampled at 120 Hz.
/// Building it once makes scrubbing free and guarantees preview == export.
final class MotionTimeline {
    static let rate = 120.0
    let samples: [MotionSample]
    let clicks: [ClickEvent]
    private let cursorChanges: [CursorChange]

    init(input: InputLog, duration: Double, segments: [ZoomSegment], style: StyleSettings, aspect: Double) {
        let n = max(2, Int(ceil(duration * Self.rate)) + 1)
        let dt = 1 / Self.rate
        let moves = input.moves
        let downs = input.clicks.filter { !$0.up }
        clicks = downs
        cursorChanges = Self.debounce(input.cursorChanges)

        var out = [MotionSample](repeating: MotionSample(), count: n)

        // Cursor: spring with lag compensation; stiffer just before clicks so it lands on target.
        let s = style.cursor.smoothing.clamped(0, 1)
        let mellow = Spring(response: lerp(0.08, 0.9, pow(s, 1.3)), dampingFraction: 0.95)
        let snappy = Spring(response: 0.18, dampingFraction: 1)
        let start = ZoomPlanner.cursor(moves, at: 0)
        var cx = start.x, cy = start.y, cvx = 0.0, cvy = 0.0
        var clickIdx = 0
        var prevRaw = start
        // Times when the cursor genuinely moved (for idle hiding).
        var moveTimes = [Double]()
        moveTimes.reserveCapacity(n / 4)

        for i in 0..<n {
            let t = Double(i) * dt
            while clickIdx < downs.count && downs[clickIdx].t < t { clickIdx += 1 }
            let nearClick = clickIdx < downs.count && downs[clickIdx].t - t < 0.2
            let spring = nearClick ? snappy : mellow
            let target = ZoomPlanner.cursor(moves, at: t + spring.lag)
            if s < 0.02 {
                let raw = ZoomPlanner.cursor(moves, at: t)
                cvx = (raw.x - cx) / dt; cvy = (raw.y - cy) / dt
                cx = raw.x; cy = raw.y
            } else {
                spring.step(&cx, &cvx, target: target.x, dt: dt)
                spring.step(&cy, &cvy, target: target.y, dt: dt)
            }
            out[i].curX = cx; out[i].curY = cy
            out[i].curVX = cvx; out[i].curVY = cvy

            let raw = ZoomPlanner.cursor(moves, at: t)
            if hypot(raw.x - prevRaw.x, raw.y - prevRaw.y) > 0.0006 {
                moveTimes.append(t)
            }
            prevRaw = raw
        }

        // Idle fade: out after `idleSeconds`, back in 0.25 s before the next movement.
        if style.cursor.hideWhenIdle {
            var activity = moveTimes + downs.map(\.t)
            activity.sort()
            var j = 0
            for i in 0..<n {
                let t = Double(i) * dt
                while j < activity.count && activity[j] <= t { j += 1 }
                let prev = j > 0 ? activity[j - 1] : 0
                let next = j < activity.count ? activity[j] : .infinity
                let out1 = smoothstep(style.cursor.idleSeconds, style.cursor.idleSeconds + 0.4, t - prev)
                let back = 1 - smoothstep(0, 0.25, next - t)
                out[i].curAlpha = 1 - out1 * (1 - back)
            }
        }

        // Click press: dip over 130 ms, recover over 200 ms.
        for c in downs {
            let i0 = max(0, Int(c.t * Self.rate)), i1 = min(n - 1, Int((c.t + 0.35) * Self.rate))
            guard i0 <= i1 else { continue }
            for i in i0...i1 {
                let d = Double(i) * dt - c.t
                let p = d < 0.13 ? smoothstep(0, 0.13, d) : 1 - smoothstep(0.13, 0.33, d)
                out[i].curPress = max(out[i].curPress, p)
            }
        }

        // Camera: one spring per channel chasing step targets, carrying velocity across retargets.
        let z = style.zoom
        let cam = Spring(response: z.response, dampingFraction: z.damping)
        let segs = segments.sorted { $0.start < $1.start }
        var sc = 1.0, svel = 0.0
        var ax = 0.5, ay = 0.5, avx = 0.0, avy = 0.0
        var aimX = 0.5, aimY = 0.5
        var segIdx = 0
        var activeSeg: Int? = nil

        func lookahead(_ t: Double) -> (Double, Double) {
            var x = 0.0, y = 0.0
            for k in 0..<6 {
                let p = ZoomPlanner.cursor(moves, at: t + Double(k) * 0.1)
                x += p.x; y += p.y
            }
            return (x / 6, y / 6)
        }
        func entryAim(_ seg: ZoomSegment) -> (Double, Double) {
            if let fx = seg.focusX, let fy = seg.focusY { return (fx, fy) }
            if let c = downs.first(where: { $0.t >= seg.start && $0.t <= seg.end }) { return (c.x, c.y) }
            return lookahead(seg.start + min(z.leadIn, seg.duration / 2))
        }

        var prevRendered = (s: 1.0, x: 0.5, y: 0.5)
        for i in 0..<n {
            let t = Double(i) * dt
            while segIdx < segs.count && segs[segIdx].end <= t { segIdx += 1 }
            let inside = segIdx < segs.count && segs[segIdx].start <= t
            let seg = inside ? segs[segIdx] : nil
            if inside, activeSeg != segIdx {
                activeSeg = segIdx
                (aimX, aimY) = entryAim(segs[segIdx])
            } else if !inside {
                activeSeg = nil
            }

            let targetScale = seg?.scale ?? 1
            if let seg {
                if seg.focusX == nil, z.followCursor {
                    // Re-aim only when the cursor leaves the central 70% of the zoomed view.
                    let (fx, fy) = lookahead(t)
                    let half = 0.5 / seg.scale * 0.7
                    if abs(fx - aimX) > half || abs(fy - aimY) > half {
                        aimX = fx; aimY = fy
                    }
                }
            } else if sc <= 1.0005, segIdx < segs.count {
                // Pre-aim while unzoomed so the next zoom scales straight toward its focus.
                (aimX, aimY) = entryAim(segs[segIdx])
                ax = aimX; ay = aimY; avx = 0; avy = 0
            }

            let h = 0.5 / targetScale
            let tx = aimX.clamped(h, 1 - h), ty = aimY.clamped(h, 1 - h)
            cam.step(&sc, &svel, target: targetScale, dt: dt)
            cam.step(&ax, &avx, target: tx, dt: dt)
            cam.step(&ay, &avy, target: ty, dt: dt)

            let rs = max(1, sc)
            let rh = 0.5 / rs
            let rx = ax.clamped(rh, 1 - rh), ry = ay.clamped(rh, 1 - rh)
            out[i].camScale = rs
            out[i].camX = rx
            out[i].camY = ry
            if i > 0 {
                out[i].camVScale = (rs - prevRendered.s) / dt
                out[i].camVX = (rx - prevRendered.x) / dt
                out[i].camVY = (ry - prevRendered.y) / dt
            }
            prevRendered = (rs, rx, ry)
        }
        samples = out
    }

    func sample(at t: Double) -> MotionSample {
        let f = max(0, t) * Self.rate
        let i = min(Int(f), samples.count - 1)
        let j = min(i + 1, samples.count - 1)
        let w = f - Double(i)
        let a = samples[i], b = samples[j]
        guard w > 0, i != j else { return a }
        var m = MotionSample()
        m.camScale = lerp(a.camScale, b.camScale, w)
        m.camX = lerp(a.camX, b.camX, w); m.camY = lerp(a.camY, b.camY, w)
        m.camVScale = lerp(a.camVScale, b.camVScale, w)
        m.camVX = lerp(a.camVX, b.camVX, w); m.camVY = lerp(a.camVY, b.camVY, w)
        m.curX = lerp(a.curX, b.curX, w); m.curY = lerp(a.curY, b.curY, w)
        m.curVX = lerp(a.curVX, b.curVX, w); m.curVY = lerp(a.curVY, b.curVY, w)
        m.curAlpha = lerp(a.curAlpha, b.curAlpha, w)
        m.curPress = lerp(a.curPress, b.curPress, w)
        return m
    }

    func cursorID(at t: Double) -> Int? {
        guard !cursorChanges.isEmpty else { return nil }
        var lo = 0, hi = cursorChanges.count - 1, ans: Int? = cursorChanges[0].id
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cursorChanges[mid].t <= t { ans = cursorChanges[mid].id; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// Clicks whose effect is still animating at `t`, with progress 0…1.
    func activeClicks(at t: Double, duration: Double) -> [(ClickEvent, Double)] {
        var out: [(ClickEvent, Double)] = []
        for c in clicks.reversed() where c.t <= t {
            let p = (t - c.t) / duration
            if p > 1 { break }
            out.append((c, p))
            if out.count >= 6 { break }
        }
        return out
    }

    /// Drop cursor shapes that flash for less than 80 ms (e.g. passing over a link).
    private static func debounce(_ changes: [CursorChange]) -> [CursorChange] {
        var out: [CursorChange] = []
        for (i, c) in changes.enumerated() {
            let next = i + 1 < changes.count ? changes[i + 1].t : .infinity
            if next - c.t < 0.08 && i > 0 { continue }
            if out.last?.id == c.id { continue }
            out.append(c)
        }
        return out
    }
}
