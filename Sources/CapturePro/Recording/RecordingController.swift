import AppKit
import AVFoundation
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
    private let bubble = CameraBubble()

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
        let url = RecordingProject.newURL(in: Preferences.shared.recordingFolderURL)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // The camera starts before the countdown so you can frame yourself in the bubble.
        var camera: CameraRecorder?
        if prefs.camera, await CameraRecorder.requestAccess() {
            camera = try? CameraRecorder(url: url.appendingPathComponent("camera.mov"), deviceID: prefs.cameraID)
            if let camera {
                camera.startPreview()
                bubble.show(session: camera.session)
            }
        }
        guard await Countdown.run(seconds: prefs.countdown, over: cocoaRect) else {
            bubble.hide()
            _ = await camera?.stop()
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return
        }

        // Ask for the microphone the first time; if refused, record without it.
        var micAllowed = false
        if prefs.microphone {
            micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let options = RecordingOptions(fps: prefs.fps, hideSystemCursor: prefs.hideSystemCursor,
                                       systemAudio: prefs.systemAudio, microphone: micAllowed,
                                       microphoneID: prefs.microphoneID, camera: camera)
        let rec = Recorder(target: target, options: options, projectURL: url)
        rec.onError = { [weak self] error in
            NSLog("Recording stopped: \(error)")
            Task { await self?.stop() }
        }
        do {
            try await rec.start()
        } catch {
            phase = .idle
            bubble.hide()
            _ = await camera?.stop()
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
        bubble.hide()
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
            let out = ExportSheet.uniqueURL(in: Preferences.shared.exportFolderURL, name: project.name,
                                            ext: project.edit.export.format == .gif ? "gif" : project.edit.export.format.rawValue)
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
