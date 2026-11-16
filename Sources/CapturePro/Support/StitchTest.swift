import CoreGraphics
import Foundation

/// `CapturePro --stitch-test`: scrolls a synthetic long page (sticky header and footer, an overlay
/// scroller, uneven steps, pauses and a scroll back) through the stitcher and compares the result
/// with the page itself, pixel for pixel (ignoring the scroller strip).
enum StitchTest {
    static func run() -> Bool {
        let W = 1200, H = 900, header = 80, footer = 60, docH = 6000
        let view = H - header - footer
        var rng = SystemRandomNumberGenerator()
        _ = rng
        let doc = makeDocument(width: W, height: docH)

        var offsets = [0]
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        while offsets.last! < docH - view {
            let step = next(5) == 0 ? 0 : 15 + next(320)
            offsets.append(min(docH - view, offsets.last! + step))
            if next(9) == 0 { offsets.append(max(0, offsets.last! - 60)) } // scroll back a little
        }

        let stitcher = ScrollStitcher()
        var outcomes: [ScrollStitcher.Outcome] = []
        var deepest = 0
        for (k, y) in offsets.enumerated() {
            let frame = makeFrame(doc: doc, width: W, height: H, header: header, footer: footer, offset: y,
                                  scroller: k % 3 != 0, docHeight: docH)
            let o = stitcher.add(frame)
            outcomes.append(o)
            if case .appended = o { deepest = max(deepest, y) }
            if case .started = o { deepest = y }
        }
        guard let image = stitcher.image(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { print("No image"); return false }

        // Expected: header + page[0 ..< deepest + view] + footer.
        let expectedH = header + deepest + view + footer
        let counts = Dictionary(grouping: outcomes.map { "\($0)".components(separatedBy: "(")[0] }, by: { $0 }).mapValues(\.count)
        print("Frames: \(offsets.count)  outcomes: \(counts)")
        print("Stitched \(image.width)×\(image.height), expected \(W)×\(expectedH)")
        guard image.height == expectedH, deepest > docH / 2 else { print("FAIL: height or too few frames stitched"); return false }

        let got = pixels(image)
        let expected = makeExpected(doc: doc, width: W, header: header, footer: footer, body: deepest + view)
        var bad = 0
        for r in 0..<expectedH {
            for c in 0..<(W - 24) where got[r * W + c] != expected[r * W + c] { bad += 1 }
        }
        print(bad == 0 ? "PASS: stitched image matches the page exactly" : "FAIL: \(bad) pixels differ")

        // Speed at full Retina size (frames arrive at 15 fps, so the budget is ~66 ms).
        let big = makeFrame(doc: makeDocument(width: 2940, height: 4000), width: 2940, height: 1912, header: 0, footer: 0,
                            offset: 0, scroller: false, docHeight: 4000)
        let big2 = makeFrame(doc: makeDocument(width: 2940, height: 4000), width: 2940, height: 1912, header: 0, footer: 0,
                             offset: 300, scroller: false, docHeight: 4000)
        let bench = ScrollStitcher()
        _ = bench.add(big)
        let t0 = Date()
        let o = bench.add(big2)
        print(String(format: "Full-screen frame (2940×1912): %.1f ms, outcome %@", Date().timeIntervalSince(t0) * 1000, "\(o)"))
        return bad == 0
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    /// A page of "text lines", blocks and some repeated blank gaps. Top-left origin via flipping.
    private static func makeDocument(width W: Int, height H: Int) -> CGImage {
        let ctx = context(W, H)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        var seed: UInt64 = 7
        func r(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        var y = 20
        while y < H - 30 {
            if r(6) == 0 { y += 40 + r(60); continue } // blank gap
            if r(8) == 0 {
                ctx.setFillColor(CGColor(srgbRed: Double(r(100)) / 100, green: Double(r(100)) / 100, blue: 0.8, alpha: 1))
                let h = 60 + r(120)
                ctx.fill(CGRect(x: 40 + r(200), y: H - y - h, width: 300 + r(500), height: h))
                y += h + 16
                continue
            }
            ctx.setFillColor(CGColor(gray: Double(r(50)) / 100, alpha: 1))
            var x = 40
            while x < W - 120 {
                let w = 20 + r(90)
                ctx.fill(CGRect(x: x, y: H - y - 12, width: w, height: 12))
                x += w + 8 + r(10)
            }
            y += 22 + r(8)
        }
        return ctx.makeImage()!
    }

    private static func makeFrame(doc: CGImage, width W: Int, height H: Int, header: Int, footer: Int, offset: Int,
                                  scroller: Bool, docHeight: Int) -> StitchFrame {
        let ctx = context(W, H)
        let view = H - header - footer
        // Page slice (CG origin bottom-left, so flip the y offset).
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: footer, width: W, height: view))
        ctx.draw(doc, in: CGRect(x: 0, y: footer + view + offset - docHeight, width: W, height: docHeight))
        ctx.restoreGState()
        drawChrome(ctx, width: W, height: H, header: header, footer: footer)
        if scroller {
            let knob = Double(offset) / Double(docHeight) * Double(view)
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 0.6))
            ctx.fill(CGRect(x: W - 14, y: Int(Double(H - header) - knob - 80), width: 8, height: 80))
        }
        let data = Data(bytes: ctx.data!, count: W * H * 4)
        return StitchFrame(width: W, height: H, bytesPerRow: W * 4, data: data)
    }

    private static func drawChrome(_ ctx: CGContext, width W: Int, height H: Int, header: Int, footer: Int) {
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: H - header, width: W, height: header))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 30, y: H - header + 25, width: 160, height: 30))
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: footer))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: W / 2 - 100, y: 20, width: 200, height: 20))
    }

    private static func makeExpected(doc: CGImage, width W: Int, header: Int, footer: Int, body: Int) -> [UInt32] {
        let H = header + body + footer
        let ctx = context(W, H)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: footer, width: W, height: body))
        ctx.draw(doc, in: CGRect(x: 0, y: footer + body - doc.height, width: W, height: doc.height))
        ctx.restoreGState()
        drawChrome(ctx, width: W, height: H, header: header, footer: footer)
        return pixels(ctx.makeImage()!)
    }

    private static func pixels(_ img: CGImage) -> [UInt32] {
        let ctx = context(img.width, img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: p, count: img.width * img.height))
    }
}
