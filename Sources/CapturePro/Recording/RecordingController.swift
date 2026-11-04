import AppKit
import Observation

/// Orchestrates a recording: pick a target, count down, record, then hand off to the editor.
@MainActor
@Observable
final class RecordingController {
    static let shared = RecordingController()

    enum Phase { case idle, preparing, recording, finishing }
    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private var recorder: Recorder?
    private let frame = AreaFrame()

    var isBusy: Bool { phase != .idle }

    func toggle() {
        switch phase {
        case .idle: Task { await start(start: .area) }
        case .recording: Task { await stop() }
        default: break
        }
    }

    /// `start == nil` records the whole display under the mouse without the picker.
    func start(start: SelectionStart?) async {
        guard phase == .idle else { return }
        guard Permissions.requestScreenRecording() else {
            Permissions.showScreenRecordingHelp()
            return
        }
        phase = .preparing
        let picked: CaptureTarget?
        if let start {
            picked = await SelectionController(purpose: .recording).run(start: start)
        } else {
            picked = await ScreenshotService.displayUnderMouse().map { .display($0) }
        }
        guard let target = picked else {
            phase = .idle
            return
        }
        let prefs = Preferences.shared.stored
        let cocoaRect = SelectionController.cocoaRect(target.globalRect)
        guard await Countdown.run(seconds: prefs.countdown, over: cocoaRect) else {
            phase = .idle
            return
        }

        let options = RecordingOptions(fps: prefs.fps, hideSystemCursor: prefs.hideSystemCursor,
                                       systemAudio: prefs.systemAudio, microphone: prefs.microphone,
                                       microphoneID: prefs.microphoneID)
        let url = RecordingProject.newURL(in: Preferences.shared.recordingFolderURL)
        let rec = Recorder(target: target, options: options, projectURL: url)
        rec.onError = { [weak self] error in
            NSLog("Recording stopped: \(error)")
            Task { await self?.stop() }
        }
        do {
            try await rec.start()
        } catch {
            phase = .idle
            try? FileManager.default.removeItem(at: url)
            presentError("Couldn’t start recording", error)
            return
        }
        recorder = rec
        if case .area = target { frame.show(cocoaRect) }
        startedAt = Date()
        phase = .recording
        if prefs.playSounds { NSSound(named: "Pop")?.play() }
    }

    func stop() async {
        guard phase == .recording, let rec = recorder else { return }
        phase = .finishing
        frame.hide()
        recorder = nil
        do {
            let project = try await rec.stop()
            phase = .idle
            startedAt = nil
            if Preferences.shared.stored.playSounds { NSSound(named: "Bottle")?.play() }
            await handOff(project)
        } catch {
            phase = .idle
            startedAt = nil
            presentError("Couldn’t save the recording", error)
        }
    }

    private func handOff(_ project: RecordingProject) async {
        switch Preferences.shared.stored.afterRecording {
        case .editor:
            EditorWindowController.open(project)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        case .export:
            let out = Preferences.shared.exportFolderURL
                .appendingPathComponent(project.name + "." + (project.edit.export.format == .gif ? "gif" : project.edit.export.format.rawValue))
            do {
                try await Exporter().export(project: project, to: out) { _ in }
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                presentError("Export failed", error)
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
