import CoreGraphics
import Foundation

/// One captured frame of 32-bit pixels (BGRA, premultiplied first, little-endian).
struct StitchFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data
}

/// Builds one tall image from frames of a scrolling area.
///
/// Every row is fingerprinted in four vertical bands (so a macOS overlay scroller, a blinking
/// caret or a hover effect only spoils part of a row). Rows that appear in both frames vote for
/// how far the content moved; rows that stay put at the top and bottom are sticky headers and
/// footers, which are kept once instead of repeating down the image.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case started
        case unchanged
        case appended(Int)
        case scrolledBack
        /// Moved too far between frames to find the overlap; scroll a little slower.
        case lost
        case full
    }

    static let bands = 4

    let maxHeight: Int
    private(set) var width = 0
    private(set) var height = 0
    private var frameHeight = 0
    private var output = Data()
    private var prev: [[UInt64]] = []
    /// The output currently covers the previous frame's rows up to this one (exclusive).
    private var coveredEnd = 0

    init(maxHeight: Int = 20_000) {
        self.maxHeight = maxHeight
    }

    var isEmpty: Bool { height == 0 }

    func add(_ f: StitchFrame) -> Outcome {
        let hashes = Self.rowHashes(f)
        if width == 0 {
            width = f.width
            frameHeight = f.height
            append(f, from: 0, to: f.height)
            coveredEnd = f.height
            prev = hashes
            return .started
        }
        guard f.width == width, f.height == frameHeight else { return .lost }
        if height >= maxHeight { return .full }

        let H = frameHeight
        let shift = Self.shift(from: prev, to: hashes, height: H)
        switch shift {
        case .none: return .lost
        case .some(0): return .unchanged
        case .some(let s) where s < 0: return .scrolledBack
        case .some(let s):
            // Sticky footer: rows identical at the same position at the bottom of both frames.
            var footer = 0
            while footer < H / 3, Self.sameRow(prev, hashes, H - 1 - footer, H - 1 - footer) { footer += 1 }
            let keepEnd = H - footer
            if coveredEnd > keepEnd {
                truncate(rows: coveredEnd - keepEnd)
                coveredEnd = keepEnd
            }
            let start = coveredEnd - s
            guard start >= 0 else { return .lost }
            let before = height
            append(f, from: start, to: H)
            coveredEnd = H
            prev = hashes
            return height >= maxHeight ? .full : .appended(height - before)
        }
    }

    /// The stitched image so far.
    func image(colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage? {
        guard height > 0, let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Internals

    private func append(_ f: StitchFrame, from: Int, to: Int) {
        let rowBytes = width * 4
        let end = min(to, from + (maxHeight - height))
        guard end > from else { return }
        f.data.withUnsafeBytes { raw in
            for r in from..<end {
                output.append(raw.baseAddress!.advanced(by: r * f.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: rowBytes)
            }
        }
        height += end - from
    }

    private func truncate(rows: Int) {
        let n = min(rows, height)
        output.removeLast(n * width * 4)
        height -= n
    }

    private static func sameRow(_ a: [[UInt64]], _ b: [[UInt64]], _ i: Int, _ j: Int) -> Bool {
        var same = 0
        for band in 0..<bands where a[band][i] == b[band][j] { same += 1 }
        return same >= bands - 1
    }

    /// Positive when the content moved up (the user scrolled down), in rows.
    static func shift(from prev: [[UInt64]], to cur: [[UInt64]], height H: Int) -> Int? {
        var votes: [Int: Int] = [:]
        var nonBlank = 0
        for band in 0..<bands {
            var index: [UInt64: [Int]] = [:]
            for (j, h) in prev[band].enumerated() where h != 0 { index[h, default: []].append(j) }
            for (i, h) in cur[band].enumerated() where h != 0 {
                nonBlank += 1
                // Rows repeated many times (rules, empty lines) carry no position information.
                // Short runs (a block or a line of text) still vote: the true shift wins because
                // every row in the run agrees on it, while the off-by-n votes scatter.
                guard let js = index[h], js.count <= 24 else { continue }
                for j in js { votes[j - i, default: 0] += 1 }
            }
        }
        guard nonBlank > 0 else { return 0 }
        // Every row votes for the true shift, so it has the most votes — including "didn't move".
        guard let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && abs($0.key) > abs($1.key)) }),
              best.value >= 8 else { return nil }
        if best.key == 0 { return 0 }
        // Confirm: most overlapping rows must actually agree at this shift.
        let s = best.key
        var checked = 0, agree = 0
        let range = s > 0 ? 0..<(H - s) : (-s)..<H
        for i in range where cur[0][i] != 0 || cur[1][i] != 0 {
            checked += 1
            var same = 0
            for band in 0..<bands where cur[band][i] == prev[band][i + s] { same += 1 }
            if same >= 2 { agree += 1 }
        }
        guard checked > 0, Double(agree) / Double(checked) >= 0.55 else { return nil }
        return s
    }

    /// Per-band row fingerprints; 0 marks a blank (uniform) segment.
    static func rowHashes(_ f: StitchFrame) -> [[UInt64]] {
        var out = [[UInt64]](repeating: [UInt64](repeating: 0, count: f.height), count: bands)
        let words = f.width / 2 // two 32-bit pixels per 64-bit word
        let per = max(1, words / bands)
        f.data.withUnsafeBytes { raw in
            for r in 0..<f.height {
                let row = raw.baseAddress!.advanced(by: r * f.bytesPerRow)
                for band in 0..<bands {
                    let start = band * per
                    let end = band == bands - 1 ? words : start + per
                    var h: UInt64 = 0xcbf29ce484222325
                    let first = row.loadUnaligned(fromByteOffset: start * 8, as: UInt64.self)
                    var uniform = true
                    for w in start..<end {
                        let v = row.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
                        if v != first { uniform = false }
                        h = (h ^ v) &* 0x100000001b3
                        h ^= h >> 29
                    }
                    out[band][r] = uniform ? 0 : (h == 0 ? 1 : h)
                }
            }
        }
        return out
    }
}
