import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
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
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            SettingsWindowController.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "capturepro" {
            if let p = try? RecordingProject.load(url) { EditorWindowController.open(p) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
