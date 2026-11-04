import AppKit
import QuartzCore

/// Records cursor motion, clicks, keystroke timing (never key contents) and cursor shapes
/// while a recording runs, so effects can be applied afterwards.
final class InputTracker {
    /// Capture area in global display coordinates (points, top-left origin).
    var areaProvider: () -> CGRect
    private(set) var log = InputLog()
    private var images: [Int: CGImage] = [:]
    private var cursorKeys: [Int: Int] = [:]
    private var startHost: Double = 0
    private var timer: DispatchSourceTimer?
    private var cursorTimer: Timer?
    private var monitors: [Any] = []
    private let queue = DispatchQueue(label: "capture.input", qos: .userInteractive)
    private let lock = NSLock()
    private var cachedArea: CGRect
    /// Offset from NSEvent timestamps (system uptime) to the host clock used by video frames.
    private let uptimeToHost = CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime
    private var lastEventMove = 0.0
    private var lastAreaRefresh = 0.0

    init(area: @escaping () -> CGRect) {
        areaProvider = area
        cachedArea = area()
    }

    /// `hostStart` is the host-clock time of the first video frame.
    func setStart(_ hostStart: Double) {
        lock.lock()
        let shift = hostStart - startHost
        startHost = hostStart
        // Re-base anything captured before the first frame arrived.
        log.moves = log.moves.map { MoveSample(t: $0.t - shift, x: $0.x, y: $0.y) }
        log.clicks = log.clicks.map { var c = $0; c.t -= shift; return c }
        log.keys = log.keys.map { $0 - shift }
        log.scrolls = log.scrolls.map { $0 - shift }
        log.cursorChanges = log.cursorChanges.map { CursorChange(t: $0.t - shift, id: $0.id) }
        lock.unlock()
    }

    func start() {
        startHost = CACurrentMediaTime()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Real mouse events carry exact timestamps; this timer only fills gaps (e.g. when the
        // pointer is moved by something that doesn't emit events).
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.sampleCursor() }
        t.resume()
        timer = t

        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] e in self?.click(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] e in self?.click(e); return e }) {
            monitors.append(m)
        }
        let motion: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: motion, handler: { [weak self] e in self?.moved(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: motion, handler: { [weak self] e in self?.moved(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in self?.stamp(\.scrolls) }) {
            monitors.append(m)
        }
        // Key events require Accessibility permission; without it this monitor simply receives nothing.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.stamp(\.keys) }) {
            monitors.append(m)
        }

        let ct = Timer(timeInterval: 1.0 / 10, repeats: true) { [weak self] _ in self?.sampleCursorShape() }
        RunLoop.main.add(ct, forMode: .common)
        cursorTimer = ct
        sampleCursorShape()
    }

    func stop() -> (InputLog, [Int: CGImage]) {
        timer?.cancel(); timer = nil
        cursorTimer?.invalidate(); cursorTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        lock.lock(); defer { lock.unlock() }
        log.moves.sort { $0.t < $1.t }
        log.clicks.sort { $0.t < $1.t }
        return (log, images)
    }

    private var now: Double { CACurrentMediaTime() - startHost }

    private func normalized(_ p: CGPoint) -> (Double, Double) {
        let a = cachedArea
        return ((p.x - a.minX) / max(a.width, 1), (p.y - a.minY) / max(a.height, 1))
    }

    private func sampleCursor() {
        let t = now
        if t - lastAreaRefresh > 0.1 {
            lastAreaRefresh = t
            cachedArea = areaProvider()
        }
        guard t - lastEventMove > 0.05, let loc = CGEvent(source: nil)?.location else { return }
        let (x, y) = normalized(loc)
        lock.lock()
        if let last = log.moves.last, last.x == x, last.y == y, t - last.t < 0.25 {
            lock.unlock(); return
        }
        log.moves.append(MoveSample(t: t, x: x, y: y))
        lock.unlock()
    }

    private func moved(_ e: NSEvent) {
        guard let loc = e.cgEvent?.location else { return }
        let t = e.timestamp + uptimeToHost - startHost
        let (x, y) = normalized(loc)
        lock.lock()
        lastEventMove = t
        log.moves.append(MoveSample(t: t, x: x, y: y))
        lock.unlock()
    }

    private func click(_ e: NSEvent) {
        let t = now
        guard let loc = CGEvent(source: nil)?.location else { return }
        let (x, y) = normalized(loc)
        let right = e.type == .rightMouseDown || e.type == .rightMouseUp
        let up = e.type == .leftMouseUp || e.type == .rightMouseUp
        lock.lock()
        log.clicks.append(ClickEvent(t: t, x: x, y: y, right: right, up: up))
        lock.unlock()
    }

    private func stamp(_ key: WritableKeyPath<InputLog, [Double]>) {
        let t = now
        lock.lock()
        log[keyPath: key].append(t)
        lock.unlock()
    }

    private func sampleCursorShape() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let img = cursor.image
        let key = Self.fingerprint(img, hot: cursor.hotSpot)
        let id: Int
        if let existing = cursorKeys[key] {
            id = existing
        } else {
            id = cursorKeys.count
            cursorKeys[key] = id
            if let cg = CursorArt.render(img, size: img.size) {
                images[id] = cg
                lock.lock()
                log.cursorImages.append(CursorImageInfo(
                    id: id, width: img.size.width, height: img.size.height,
                    hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y, file: "cursor-\(id).png"))
                lock.unlock()
            }
        }
        lock.lock()
        if log.cursorChanges.last?.id != id {
            log.cursorChanges.append(CursorChange(t: now, id: id))
        }
        lock.unlock()
    }

    /// Cheap identity for a cursor image: size, hot spot and a tiny thumbnail.
    private static func fingerprint(_ image: NSImage, hot: NSPoint) -> Int {
        var h = Hasher()
        h.combine(Int(image.size.width * 10)); h.combine(Int(image.size.height * 10))
        h.combine(Int(hot.x * 10)); h.combine(Int(hot.y * 10))
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        if let ctx = CGContext(data: &bytes, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        h.combine(bytes)
        return h.finalize()
    }
}
