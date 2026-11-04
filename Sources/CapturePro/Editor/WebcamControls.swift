import AVFoundation
import SwiftUI

struct WebcamControls: View {
    @Bindable var model: EditorModel
    @State private var detecting = false

    var body: some View {
        if !model.project.info.hasCamera {
            Section("Webcam") {
                Text("This recording has no camera. Turn on Camera in the bar that appears when you choose what to record, or in the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Section("Webcam") {
                Toggle("Show camera", isOn: $model.camera.visible)
                Picker("Shape", selection: $model.camera.shape) {
                    ForEach(CameraShape.allCases) { Text($0.label).tag($0) }
                }
                CameraDimensions(camera: $model.camera)
                Picker("Position", selection: $model.camera.corner) {
                    ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
                }
                Text("Tip: drag the camera in the preview to place it anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mirror", isOn: $model.camera.mirror)
                if model.camera.shape != .cutout {
                    LabeledSlider("Border", value: $model.camera.border, in: 0...12, format: "%.0f")
                    if model.camera.border > 0.1 {
                        ColorPicker("Border color", selection: Binding(
                            get: { Color(rgba: model.camera.borderColor) }, set: { model.camera.borderColor = RGBA($0) }))
                    }
                }
                Toggle("Shadow", isOn: $model.camera.shadow)
            }
            Section("Background removal") {
                Toggle("Chroma key (green / blue screen)", isOn: $model.camera.chromaKey)
                if model.camera.chromaKey {
                    HStack(spacing: 8) {
                        keySwatch("Green", RGBA(hex: "#00B140"))
                        keySwatch("Blue", RGBA(hex: "#0047BB"))
                        ColorPicker("", selection: Binding(
                            get: { Color(rgba: model.camera.keyColor) }, set: { model.camera.keyColor = RGBA($0) }))
                            .labelsHidden()
                        Spacer()
                        Button {
                            detecting = true
                            Task { await model.detectKeyColor(); detecting = false }
                        } label: {
                            Label(detecting ? "Detecting…" : "Auto-detect", systemImage: "eyedropper")
                        }
                        .disabled(detecting)
                    }
                    LabeledSlider("Tolerance", value: $model.camera.threshold, in: 0.01...0.4, format: "%.0f%%", scale: 250)
                    LabeledSlider("Edge softness", value: $model.camera.softness, in: 0...0.3, format: "%.0f%%", scale: 333)
                    LabeledSlider("Spill removal", value: $model.camera.spill, in: 0...1, format: "%.0f%%", scale: 100)
                    Text("Auto-detect samples the backdrop at the playhead. Raise Tolerance until the screen disappears, then add a touch of softness for natural edges. Cutout shape shows the whole keyed frame.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keySwatch(_ name: String, _ color: RGBA) -> some View {
        Button { model.camera.keyColor = color } label: {
            Circle().fill(Color(rgba: color)).frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(model.camera.keyColor == color ? Color.primary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

struct CameraDimensions: View {
    @Binding var camera: CameraStyle

    private static let ratios: [(String, Double)] = [("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]

    var body: some View {
        switch camera.shape {
        case .circle:
            LabeledSlider("Diameter", value: $camera.size, in: 0.06...0.8, format: "%.0f%%", scale: 100)
        case .cutout:
            LabeledSlider("Size", value: $camera.size, in: 0.1...1, format: "%.0f%%", scale: 100)
        case .rounded, .rectangle:
            LabeledSlider("Height", value: $camera.size, in: 0.06...0.9, format: "%.0f%%", scale: 100)
            LabeledSlider("Width", value: Binding(
                get: { camera.size * camera.aspect },
                set: { camera.aspect = ($0 / max(camera.size, 0.01)).clamped(0.3, 3.5) }),
                          in: 0.06...1.4, format: "%.0f%%", scale: 100)
            HStack(spacing: 6) {
                Text("Ratio").foregroundStyle(.secondary)
                Spacer()
                ForEach(Self.ratios, id: \.0) { name, r in
                    Button(name) { camera.aspect = r }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(abs(camera.aspect - r) < 0.01 ? .accentColor : nil)
                }
            }
            if camera.shape == .rounded {
                LabeledSlider("Corner radius", value: $camera.cornerRadius, in: 0...0.5, format: "%.0f%%", scale: 200)
            }
        }
    }
}

/// Lets you grab the webcam in the preview and drop it anywhere, or resize it from its corner.
/// The outline follows the pointer instantly; the rendered frame catches up a beat later.
struct CameraDragOverlay: View {
    @Bindable var model: EditorModel
    @State private var live: CGRect?
    @State private var grab: CGSize?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let canvas = model.previewSize
            let video = AVMakeRect(aspectRatio: canvas, insideRect: CGRect(origin: .zero, size: geo.size))
            let scale = video.width / max(canvas.width, 1)
            if let rest = cameraRect(canvas: canvas, video: video, scale: scale) {
                let r = live ?? rest
                let radius = CameraLayer.cornerRadius(model.camera, size: r.size)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: live == nil ? [] : [6, 4]))
                        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.accentColor.opacity(live == nil ? 0.001 : 0.12)))
                        .opacity(hovering || live != nil ? 1 : 0.001)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .onHover { h in
                            hovering = h
                            h ? NSCursor.openHand.push() : NSCursor.pop()
                        }
                        .gesture(move(rest: rest, video: video, canvas: canvas))

                    // Resize handle (bottom-right corner).
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                        .opacity(hovering || live != nil ? 1 : 0)
                        .offset(x: r.maxX - 7, y: r.maxY - 7)
                        .onHover { h in
                            if h { hovering = true }
                            h ? NSCursor.crosshair.push() : NSCursor.pop()
                        }
                        .gesture(resize(rest: rest, video: video, canvas: canvas))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .coordinateSpace(name: "player")
    }

    private func move(rest: CGRect, video: CGRect, canvas: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("player"))
            .onChanged { v in
                if grab == nil { grab = CGSize(width: v.startLocation.x - rest.midX, height: v.startLocation.y - rest.midY) }
                let g = grab ?? .zero
                let c = CGPoint(x: (v.location.x - g.width).clamped(video.minX, video.maxX),
                                y: (v.location.y - g.height).clamped(video.minY, video.maxY))
                live = CGRect(x: c.x - rest.width / 2, y: c.y - rest.height / 2, width: rest.width, height: rest.height)
                commit(video: video)
            }
            .onEnded { _ in commit(video: video); grab = nil; live = nil }
    }

    private func resize(rest: CGRect, video: CGRect, canvas: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("player"))
            .onChanged { v in
                var w = max(24, v.location.x - rest.minX)
                var h = max(24, v.location.y - rest.minY)
                if model.camera.shape == .circle || model.camera.shape == .cutout {
                    // Uniform scale for shapes with a fixed aspect.
                    let a = rest.width / max(rest.height, 1)
                    h = max(h, w / a); w = h * a
                }
                live = CGRect(x: rest.minX, y: rest.minY, width: w, height: h)
                commit(video: video)
            }
            .onEnded { _ in commit(video: video); live = nil }
    }

    /// Writes the live rect back into the camera settings.
    private func commit(video: CGRect) {
        guard let r = live else { return }
        var c = model.camera
        c.corner = .custom
        c.x = ((r.midX - video.minX) / video.width).clamped(0, 1)
        c.y = ((r.midY - video.minY) / video.height).clamped(0, 1)
        c.size = (r.height / video.height).clamped(0.04, 1)
        if c.shape == .rounded || c.shape == .rectangle { c.aspect = (r.width / max(r.height, 1)).clamped(0.3, 3.5) }
        model.camera = c
    }

    /// The camera's rect in view coordinates (top-left origin).
    private func cameraRect(canvas: CGSize, video: CGRect, scale: Double) -> CGRect? {
        guard model.project.info.hasCamera, model.camera.visible else { return nil }
        let cs = model.camera
        let h = cs.size * canvas.height
        let w = h * CameraLayer.aspect(cs, frame: CGSize(width: 16, height: 9))
        let r = CameraLayer.position(cs, size: CGSize(width: w, height: h), canvas: canvas)
        return CGRect(x: video.minX + r.minX * scale, y: video.minY + (canvas.height - r.maxY) * scale,
                      width: r.width * scale, height: r.height * scale)
    }
}
