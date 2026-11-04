import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum ScreenshotService {
    static func capture(start: SelectionStart?) async {
        guard Permissions.requestScreenRecording() else {
            Permissions.showScreenRecordingHelp()
            return
        }
        let target: CaptureTarget?
        if let start {
            target = await SelectionController(purpose: .screenshot).run(start: start)
        } else {
            target = await displayUnderMouse().map { .display($0) }
        }
        guard let target else { return }

        do {
            let image = try await grab(target)
            await deliver(image, isWindow: { if case .window = target { true } else { false } }())
        } catch {
            NSSound.beep()
            NSLog("Screenshot failed: \(error)")
        }
    }

    static func displayUnderMouse() async -> SCDisplay? {
        guard let content = try? await SCShareableContent.current else { return nil }
        let p = SelectionController.cgPoint(NSEvent.mouseLocation)
        return content.displays.first { $0.frame.contains(p) } ?? content.displays.first
    }

    static func grab(_ target: CaptureTarget) async throws -> CGImage {
        let prefs = Preferences.shared.stored
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.showsCursor = prefs.screenshotCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.displayP3
        let filter: SCContentFilter
        switch target {
        case .display(let d):
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            let s = CaptureTarget.scale(for: d)
            config.width = Int(d.frame.width * s); config.height = Int(d.frame.height * s)
        case .area(let d, let r):
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            let s = CaptureTarget.scale(for: d)
            config.sourceRect = r
            config.width = Int(r.width * s); config.height = Int(r.height * s)
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
            let s = Double(filter.pointPixelScale)
            // With "beautify" our own shadow replaces the system one.
            config.ignoreShadowsSingleWindow = !prefs.windowShadow || prefs.beautifyScreenshots
            let rect = config.ignoreShadowsSingleWindow ? w.frame : filter.contentRect
            config.width = Int(rect.width * s); config.height = Int(rect.height * s)
            config.shouldBeOpaque = false
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func deliver(_ raw: CGImage, isWindow: Bool) async {
        let prefs = Preferences.shared.stored
        var image = raw
        if prefs.beautifyScreenshots, let pretty = Compositor.beautify(raw, style: prefs.style) {
            image = pretty
        }
        if prefs.playSounds { NSSound(named: "Tink")?.play() }

        var saved: URL?
        if prefs.saveScreenshots {
            saved = save(image, format: prefs.imageFormat, folder: Preferences.shared.screenshotFolderURL)
        }
        if prefs.copyScreenshots {
            copy(image, file: saved)
        }
        if prefs.showPreview {
            ScreenshotPreview.show(image: image, file: saved)
        }
    }

    static func filename(_ prefix: String, ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: Date())).\(ext)"
    }

    @discardableResult
    static func save(_ image: CGImage, format: ImageFormat, folder: URL) -> URL? {
        let url = folder.appendingPathComponent(filename("Screenshot", ext: format.ext))
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    static func copy(_ image: CGImage, file: URL?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        var items: [NSPasteboardWriting] = []
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        // Pasting into Finder yields the file; anywhere else, the image.
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        items.append(item)
        pb.writeObjects(items)
    }
}
