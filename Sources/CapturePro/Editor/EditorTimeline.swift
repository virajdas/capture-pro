import SwiftUI
import AVFoundation

/// Ruler, filmstrip with trim handles, and the zoom track.
struct EditorTimeline: View {
    @Bindable var model: EditorModel
    @State private var thumbs: [NSImage] = []
    @State private var dragOrigin: ZoomSegment?

    private let pad = 16.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - pad * 2
            let x = { (t: Double) in pad + t / max(model.duration, 0.01) * w }
            let time = { (px: Double) in ((px - pad) / w * model.duration).clamped(0, model.duration) }

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    ruler(time: time).frame(height: 18)
                    filmstrip(w: w, x: x, time: time).frame(height: 44)
                    zoomTrack(x: x, time: time).frame(height: 30)
                }
                .padding(.top, 10)

                // Playhead
                let px = x(model.currentTime)
                Rectangle().fill(Color.accentColor).frame(width: 2, height: geo.size.height - 14)
                    .offset(x: px - 1, y: 8)
                    .allowsHitTesting(false)
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    .offset(x: px - 5, y: 4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "timeline")
        }
        .background(.regularMaterial)
        .task { await loadThumbs() }
    }

    private func ruler(time: @escaping (Double) -> Double) -> some View {
        Canvas { ctx, size in
            let w = size.width - pad * 2
            let x = { (t: Double) in pad + t / max(model.duration, 0.01) * w }
            let d = model.duration
            let step: Double = d > 600 ? 60 : d > 120 ? 10 : d > 30 ? 5 : 1
            var t = 0.0
            while t <= d {
                let px = x(t)
                ctx.fill(Path(CGRect(x: px, y: size.height - 5, width: 1, height: 5)), with: .color(.secondary.opacity(0.5)))
                let label = Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)).font(.system(size: 9)).foregroundStyle(.secondary)
                ctx.draw(label, at: CGPoint(x: px + 2, y: 5), anchor: .leading)
                t += step
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
            model.seek(to: time(v.location.x))
        })
    }

    private func filmstrip(w: Double, x: @escaping (Double) -> Double, time: @escaping (Double) -> Double) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(thumbs.indices, id: \.self) { i in
                    Image(nsImage: thumbs[i]).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: w / Double(max(thumbs.count, 1)), height: 44).clipped()
                }
            }
            .frame(width: w, height: 44, alignment: .leading)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .offset(x: pad)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in model.seek(to: time(v.location.x)) })

            // Dim trimmed-away regions.
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, x(model.trimStart) - pad), height: 44)
                .offset(x: pad).allowsHitTesting(false)
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, x(model.duration) - x(model.trimEnd)), height: 44)
                .offset(x: x(model.trimEnd)).allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 2)
                .frame(width: max(4, x(model.trimEnd) - x(model.trimStart)), height: 44)
                .offset(x: x(model.trimStart)).allowsHitTesting(false)

            trimHandle(at: x(model.trimStart)) { px in
                model.trimStart = min(time(px), model.trimEnd - 0.5)
                model.seek(to: model.trimStart)
            }
            trimHandle(at: x(model.trimEnd) - 10) { px in
                model.trimEnd = max(time(px + 10), model.trimStart + 0.5)
                model.seek(to: model.trimEnd)
            }
        }
    }

    private func trimHandle(at px: Double, onDrag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
            .frame(width: 10, height: 44)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 16))
            .offset(x: px)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in onDrag(v.location.x) })
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }

    private func zoomTrack(x: @escaping (Double) -> Double, time: @escaping (Double) -> Double) -> some View {
        let active = model.style.zoom.auto || model.segmentsEdited
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: x(model.duration) - x(0), height: 30)
                .offset(x: pad)
                .onTapGesture(count: 2, coordinateSpace: .named("timeline")) { loc in model.addSegment(at: time(loc.x)) }
                .onTapGesture { model.selectedSegment = nil }

            // Click markers
            ForEach(Array(model.project.input.clicks.filter { !$0.up }.enumerated()), id: \.offset) { _, c in
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 4)
                    .offset(x: x(c.t) - 2, y: 11).allowsHitTesting(false)
            }

            if active {
                ForEach(model.segments) { seg in
                    segmentView(seg, x: x, time: time)
                }
            }
        }
    }

    private func segmentView(_ seg: ZoomSegment, x: @escaping (Double) -> Double, time: @escaping (Double) -> Double) -> some View {
        let selected = model.selectedSegment == seg.id
        let width = max(16, x(seg.end) - x(seg.start))
        let on = seg.enabled
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on
                      ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1), Color(red: 0.62, green: 0.48, blue: 0.98)],
                                                     startPoint: .leading, endPoint: .trailing).opacity(selected ? 1 : 0.75))
                      : AnyShapeStyle(Color.secondary.opacity(selected ? 0.3 : 0.18)))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(on ? Color.white.opacity(selected ? 0.9 : 0.25) : Color.secondary.opacity(selected ? 0.9 : 0.5),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: on ? [] : [4, 3]))
            HStack(spacing: 4) {
                Button {
                    model.updateSegment(seg.id) { $0.enabled.toggle() }
                } label: {
                    Image(systemName: on ? "eye" : "eye.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .help(on ? "Turn this zoom off" : "Turn this zoom on")
                Text(on ? String(format: "%.1f×", seg.scale) : "Off").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(on ? Color.white : Color.secondary)
            .opacity(width > 64 ? 1 : 0)
            HStack {
                edge(seg, leading: true, time: time)
                Spacer(minLength: 0)
                edge(seg, leading: false, time: time)
            }
        }
        .contextMenu {
            Button(on ? "Turn Zoom Off" : "Turn Zoom On") { model.updateSegment(seg.id) { $0.enabled.toggle() } }
            Button("Delete Zoom", role: .destructive) { model.deleteSegment(seg.id) }
        }
        .frame(width: width, height: 26)
        .offset(x: x(seg.start), y: 0)
        .onTapGesture {
            model.selectedSegment = seg.id
            model.seek(to: seg.start + min(0.6, seg.duration / 2))
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if dragOrigin?.id != seg.id { dragOrigin = seg }
                guard let o = dragOrigin else { return }
                let dt = time(v.location.x) - time(v.startLocation.x)
                let s = (o.start + dt).clamped(0, model.duration - o.duration)
                model.selectedSegment = seg.id
                model.updateSegment(seg.id) { $0.start = s; $0.end = s + o.duration }
            }
            .onEnded { _ in dragOrigin = nil })
    }

    private func edge(_ seg: ZoomSegment, leading: Bool, time: @escaping (Double) -> Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline")).onChanged { v in
                let t = time(v.location.x)
                model.selectedSegment = seg.id
                model.updateSegment(seg.id) { s in
                    if leading { s.start = min(t, s.end - 0.3) } else { s.end = max(t, s.start + 0.3) }
                }
            })
    }

    private func loadThumbs() async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: model.project.videoURL))
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.appliesPreferredTrackTransform = true
        let n = 16
        var out: [NSImage] = []
        for i in 0..<n {
            let t = model.duration * (Double(i) + 0.5) / Double(n)
            if let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                out.append(NSImage(cgImage: img, size: .zero))
            }
        }
        thumbs = out
    }
}
