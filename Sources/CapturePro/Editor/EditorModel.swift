import AVFoundation
import AppKit
import Observation

@MainActor
@Observable
final class EditorModel {
    let project: RecordingProject
    let player = AVPlayer()
    let duration: Double

    var style: StyleSettings { didSet { changed(regenerate: oldValue.zoom != style.zoom) } }
    var export: ExportSettings { didSet { project.edit.export = export; scheduleSave() } }
    var segments: [ZoomSegment] { didSet { changed(regenerate: false) } }
    var segmentsEdited: Bool
    var trimStart: Double { didSet { project.edit.trimStart = trimStart; scheduleSave() } }
    var trimEnd: Double { didSet { project.edit.trimEnd = trimEnd; scheduleSave() } }
    var selectedSegment: UUID?
    var camera: CameraStyle { didSet { project.edit.camera = camera; scheduleSave(); cameraChanged() } }
    var systemVolume: Double { didSet { project.edit.systemVolume = systemVolume; applyAudio() } }
    var microphoneVolume: Double { didSet { project.edit.microphoneVolume = microphoneVolume; applyAudio() } }
    private var audioTracks: [(CMPersistentTrackID, Bool)] = []

    var currentTime: Double = 0
    var isPlaying = false
    var exportProgress: Double?
    var exportResult: URL?
    var exportError: String?

    private var compositor: Compositor?
    private var video: AVMutableVideoComposition?
    private var timeObserver: Any?
    private var rebuildGeneration = 0
    private var saveWork: DispatchWorkItem?
    private var exporter: Exporter?
    private let cursors: [Int: (CGImage, CursorImageInfo)]

    init(project: RecordingProject) {
        self.project = project
        duration = project.info.duration
        style = project.edit.style
        export = project.edit.export
        segments = project.edit.segments
        segmentsEdited = project.edit.segmentsEdited
        trimStart = project.edit.trimStart
        trimEnd = project.trimEnd
        camera = project.edit.camera
        systemVolume = project.edit.systemVolume
        microphoneVolume = project.edit.microphoneVolume
        cursors = project.cursorImages()
        Task { await setUpPlayer() }
    }

    var sourceSize: CGSize { CGSize(width: project.info.pixelWidth, height: project.info.pixelHeight) }

    var previewSize: CGSize { previewCanvas() }

    /// Samples the camera frame at the playhead and picks its backdrop colour as the key.
    func detectKeyColor() async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.cameraURL))
        gen.maximumSize = CGSize(width: 640, height: 640)
        let t = max(0, currentTime - project.info.cameraOffset)
        guard let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)),
              let color = ChromaKey.detect(in: CIImage(cgImage: img)) else { return }
        camera.keyColor = color
        camera.chromaKey = true
    }

    private func previewCanvas() -> CGSize {
        // The preview pane is rarely wider than ~1600 px; rendering more just costs frames.
        RenderState.canvasSize(source: sourceSize, style: style, shortSide: min(900, export.resolution.shortSide))
    }

    /// Motion only depends on these; colour and frame tweaks reuse the existing timeline.
    private struct MotionKey: Equatable {
        let segments: [ZoomSegment], cursor: CursorStyle, zoom: ZoomStyle
    }
    private var motionCache: (MotionKey, MotionTimeline)?

    private func makeState(canvas: CGSize) async -> RenderState {
        let key = MotionKey(segments: activeSegments, cursor: style.cursor, zoom: style.zoom)
        let timeline: MotionTimeline
        if let c = motionCache, c.0 == key {
            timeline = c.1
        } else {
            let (input, duration, style, aspect) = (project.input, duration, style, sourceSize.width / max(sourceSize.height, 1))
            timeline = await Task.detached(priority: .userInitiated) {
                MotionTimeline(input: input, duration: duration, segments: key.segments, style: style, aspect: aspect)
            }.value
            motionCache = (key, timeline)
        }
        let (style, camera, cursors) = (style, camera, cursors)
        let point = CGSize(width: project.info.pointWidth, height: project.info.pointHeight)
        return await Task.detached(priority: .userInitiated) {
            RenderState(style: style, canvas: canvas, pointSize: point, timeline: timeline, cursors: cursors,
                        timeOffset: 0, preview: true, camera: camera)
        }.value
    }

    private var activeSegments: [ZoomSegment] {
        (style.zoom.auto || segmentsEdited) ? segments : []
    }

    private func setUpPlayer() async {
        let comp = Compositor(state: await makeState(canvas: previewCanvas()))
        compositor = comp
        // Preview always shows the whole recording; trim is applied on export.
        var fullEdit = project.edit
        fullEdit.trimStart = 0
        fullEdit.trimEnd = nil
        let full = RecordingProject(url: project.url, info: project.info, input: project.input, edit: fullEdit)
        guard let built = try? await CompositionBuilder.build(project: full, compositor: comp, fps: 60) else { return }
        video = built.video
        audioTracks = built.audioTracks
        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.video
        item.audioMix = built.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds
                if self.isPlaying, t.seconds >= self.trimEnd - 0.02 {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
        seek(to: trimStart)
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart { seek(to: trimStart) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to t: Double) {
        let c = t.clamped(0, duration)
        currentTime = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Editing

    private func changed(regenerate: Bool) {
        project.edit.style = style
        if regenerate && !segmentsEdited {
            segments = ZoomPlanner.generate(input: project.input, duration: duration, style: style.zoom)
            return
        }
        project.edit.segments = segments
        project.edit.segmentsEdited = segmentsEdited
        scheduleSave()
        rebuild()
    }

    private var rebuildTask: Task<Void, Never>?

    /// Coalesces rapid edits (slider drags) and does the heavy lifting off the main thread.
    private func rebuild() {
        guard compositor != nil else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, !Task.isCancelled else { return }
            let canvas = self.previewCanvas()
            let state = await self.makeState(canvas: canvas)
            guard !Task.isCancelled, let compositor = self.compositor else { return }
            compositor.state = state
            guard let item = self.player.currentItem, let video = self.video else { return }
            if video.renderSize != canvas { video.renderSize = canvas }
            // Re-assigning the composition makes AVPlayer re-render the paused frame.
            item.videoComposition = video.mutableCopy() as? AVVideoComposition
            if !self.isPlaying { self.seek(to: self.currentTime) }
        }
    }

    private var lastFrameRefresh = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?

    /// Camera tweaks only swap the camera settings on the live renderer, then redraw the
    /// paused frame at most ~30×/s — so dragging the camera follows the pointer.
    private func cameraChanged() {
        guard let compositor else { return }
        compositor.state = compositor.state.replacing(camera: camera)
        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in self?.redrawFrame() }
        pendingRefresh = refresh
        let wait = max(0, 1.0 / 30 - Date().timeIntervalSince(lastFrameRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: refresh)
    }

    private func redrawFrame() {
        lastFrameRefresh = Date()
        // While playing, the next frames already use the new settings.
        guard !isPlaying, let item = player.currentItem, let video else { return }
        item.videoComposition = video.mutableCopy() as? AVVideoComposition
        if !isPlaying { seek(to: currentTime) }
    }

    private func applyAudio() {
        scheduleSave()
        player.currentItem?.audioMix = CompositionBuilder.audioMix(
            for: player.currentItem!.asset, project: project, tracks: audioTracks)
    }

    func setAllSegments(enabled: Bool) {
        segmentsEdited = true
        segments = segments.map { var s = $0; s.enabled = enabled; return s }
    }

    func regenerateSegments() {
        segmentsEdited = false
        segments = ZoomPlanner.generate(input: project.input, duration: duration, style: style.zoom)
    }

    func addSegment(at t: Double) {
        let start = max(0, t - 0.5)
        let seg = ZoomSegment(start: start, end: min(duration, start + 2.5), scale: style.zoom.scale)
        segmentsEdited = true
        segments.append(seg)
        segments.sort { $0.start < $1.start }
        selectedSegment = seg.id
    }

    func updateSegment(_ id: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        var s = segments[i]
        change(&s)
        s.start = s.start.clamped(0, duration - 0.3)
        s.end = s.end.clamped(s.start + 0.3, duration)
        segmentsEdited = true
        segments[i] = s
    }

    func deleteSegment(_ id: UUID) {
        segmentsEdited = true
        segments.removeAll { $0.id == id }
        if selectedSegment == id { selectedSegment = nil }
    }

    func saveAsDefaultLook() {
        Preferences.shared.stored.style = style
        Preferences.shared.stored.export = export
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.project.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func flush() {
        saveWork?.cancel()
        project.save()
    }

    // MARK: Export

    func startExport(to url: URL) {
        flush()
        exportResult = nil
        exportError = nil
        exportProgress = 0
        let ex = Exporter()
        exporter = ex
        let project = self.project
        Task {
            do {
                try await ex.export(project: project, to: url) { p in
                    DispatchQueue.main.async { if self.exportProgress != nil { self.exportProgress = p } }
                }
                exportProgress = nil
                exportResult = url
                if Preferences.shared.stored.revealAfterExport { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if Preferences.shared.stored.playSounds { NSSound(named: "Glass")?.play() }
            } catch is CancellationError {
                exportProgress = nil
            } catch {
                exportProgress = nil
                exportError = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func tearDown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        flush()
    }
}
