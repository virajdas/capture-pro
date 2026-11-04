import Foundation
import AppKit

/// Cursor position in capture space: normalized 0…1, origin top-left.
struct MoveSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

struct ClickEvent: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
    var right = false
    var up = false
}

struct CursorChange: Codable, Hashable {
    var t: Double
    var id: Int
}

struct CursorImageInfo: Codable, Hashable {
    var id: Int
    /// Logical size in points.
    var width: Double
    var height: Double
    /// Hot spot in points from the top-left.
    var hotX: Double
    var hotY: Double
    var file: String
}

struct InputLog: Codable {
    var moves: [MoveSample] = []
    var clicks: [ClickEvent] = []
    var keys: [Double] = []
    var scrolls: [Double] = []
    var cursorChanges: [CursorChange] = []
    var cursorImages: [CursorImageInfo] = []
}

struct ZoomSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
    /// When nil the camera follows the cursor; otherwise it holds this normalized focus point.
    var focusX: Double? = nil
    var focusY: Double? = nil

    var duration: Double { end - start }
}

struct RecordingInfo: Codable {
    var version = 1
    var createdAt = Date()
    var duration: Double = 0
    /// Capture area size in points.
    var pointWidth: Double = 0
    var pointHeight: Double = 0
    var pixelWidth: Double = 0
    var pixelHeight: Double = 0
    var mode = "display"
    var hasSystemAudio = false
    var hasMicrophone = false
    /// Audio start relative to the first video frame.
    var systemAudioOffset: Double = 0
    var microphoneOffset: Double = 0
}

struct EditState: Codable {
    var style: StyleSettings
    var export: ExportSettings
    var segments: [ZoomSegment] = []
    var segmentsEdited = false
    var trimStart: Double = 0
    var trimEnd: Double? = nil
}

/// A recording on disk: `Name.capturepro/` with `raw.mov`, `project.json` and `cursors/`.
final class RecordingProject {
    let url: URL
    var info: RecordingInfo
    var input: InputLog
    var edit: EditState

    var videoURL: URL { url.appendingPathComponent("raw.mov") }
    var systemAudioURL: URL { url.appendingPathComponent("system.m4a") }
    var microphoneURL: URL { url.appendingPathComponent("mic.m4a") }
    var cursorsURL: URL { url.appendingPathComponent("cursors", isDirectory: true) }
    var name: String { url.deletingPathExtension().lastPathComponent }

    private struct Document: Codable {
        var info: RecordingInfo
        var input: InputLog
        var edit: EditState
    }

    init(url: URL, info: RecordingInfo, input: InputLog, edit: EditState) {
        self.url = url
        self.info = info
        self.input = input
        self.edit = edit
    }

    static func load(_ url: URL) throws -> RecordingProject {
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let doc = try JSONDecoder().decode(Document.self, from: data)
        return RecordingProject(url: url, info: doc.info, input: doc.input, edit: doc.edit)
    }

    func save() {
        let doc = Document(info: info, input: input, edit: edit)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(doc) {
            try? data.write(to: url.appendingPathComponent("project.json"), options: .atomic)
        }
    }

    func cursorImages() -> [Int: (CGImage, CursorImageInfo)] {
        var out: [Int: (CGImage, CursorImageInfo)] = [:]
        for info in input.cursorImages {
            let file = cursorsURL.appendingPathComponent(info.file)
            if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                out[info.id] = (img, info)
            }
        }
        return out
    }

    /// Hand-edited segments win; otherwise auto zoom regenerates them from the input log.
    func effectiveSegments() -> [ZoomSegment] {
        if edit.segmentsEdited { return edit.segments }
        guard edit.style.zoom.auto else { return [] }
        return ZoomPlanner.generate(input: input, duration: info.duration, style: edit.style.zoom)
    }

    var trimEnd: Double { min(edit.trimEnd ?? info.duration, info.duration) }

    static func newURL(in folder: URL) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Recording \(f.string(from: Date()))"
        var url = folder.appendingPathComponent(base + ".capturepro", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).capturepro", isDirectory: true)
            n += 1
        }
        return url
    }

    /// All projects in a folder, newest first.
    static func list(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items
            .filter { $0.pathExtension == "capturepro" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
    }
}
