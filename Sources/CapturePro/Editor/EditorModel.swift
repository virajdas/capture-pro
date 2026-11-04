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
        cursors = project.cursorImages()
        Task { await setUpPlayer() }
    }

    var sourceSize: CGSize { CGSize(width: project.info.pixelWidth, height: project.info.pixelHeight) }

    private func previewCanvas() -> CGSize {
        RenderState.canvasSize(source: sourceSize, style: style, shortSide: min(1080, export.resolution.shortSide))
    }

    private func makeState(canvas: CGSize) -> RenderState {
        let timeline = MotionTimeline(input: project.input, duration: duration, segments: activeSegments,
                                      style: style, aspect: sourceSize.width / max(sourceSize.height, 1))
        return RenderState(style: style, canvas: canvas,
                           pointSize: CGSize(width: project.info.pointWidth, height: project.info.pointHeight),
                           timeline: timeline, cursors: cursors, timeOffset: 0)
    }

    private var activeSegments: [ZoomSegment] {
        (style.zoom.auto || segmentsEdited) ? segments : []
    }

    private func setUpPlayer() async {
        let comp = Compositor(state: makeState(canvas: previewCanvas()))
        compositor = comp
        // Preview always shows the whole recording; trim is applied on export.
        let full = RecordingProject(url: project.url, info: project.info, input: project.input,
                                    edit: EditState(style: style, export: export, trimStart: 0, trimEnd: nil))
        guard let built = try? await CompositionBuilder.build(project: full, compositor: comp, fps: 60) else { return }
        video = built.video
        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.video
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

    private func rebuild() {
        guard let compositor else { return }
        rebuildGeneration += 1
        let gen = rebuildGeneration
        let canvas = previewCanvas()
        let state = makeState(canvas: canvas)
        guard gen == rebuildGeneration else { return }
        compositor.state = state
        guard let item = player.currentItem, let video else { return }
        if video.renderSize != canvas { video.renderSize = canvas }
        // Re-assigning the composition makes AVPlayer re-render the paused frame.
        item.videoComposition = video.mutableCopy() as? AVVideoComposition
        if !isPlaying { seek(to: currentTime) }
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
