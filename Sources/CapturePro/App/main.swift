import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Actions.registerHotKeys()
        NotificationCenter.default.addObserver(forName: .preferencesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Actions.registerHotKeys() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
           let p = try? RecordingProject.load(URL(fileURLWithPath: CommandLine.arguments[i + 1])) {
            EditorWindowController.open(p)
        } else if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.show()
        }
        if OnboardingWindowController.needsOnboarding || CommandLine.arguments.contains("--onboarding") {
            OnboardingWindowController.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "capturepro" {
                if let p = try? RecordingProject.load(url) { EditorWindowController.open(p) }
            } else {
                ImageOpener.annotate(url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// "Open With › Capture Pro" and the "Annotate with Capture Pro" Finder service both land here.
@MainActor
enum ImageOpener {
    static func annotate(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        else { NSSound.beep(); return }
        AnnotationEditor.open(image: image, file: url)
    }
}

final class ServiceProvider: NSObject {
    @objc func annotateImage(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DispatchQueue.main.async {
            for url in urls { ImageOpener.annotate(url) }
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-demo"), i + 1 < args.count {
    // Headless self-test: synthesizes a recording and renders it through the full pipeline.
    DemoRenderer.run(output: URL(fileURLWithPath: args[i + 1]))
} else if let i = args.firstIndex(of: "--record-test"), i + 1 < args.count {
    // Headless check of the capture path: records the main display for 3 s, then exports it.
    DemoRenderer.recordTest(output: URL(fileURLWithPath: args[i + 1]))
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
