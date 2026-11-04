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
                LabeledSlider("Size", value: $model.camera.size, in: 0.1...0.8, format: "%.0f%%", scale: 100)
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

/// Lets you grab the webcam in the preview and drop it anywhere on the canvas.
struct CameraDragOverlay: View {
    @Bindable var model: EditorModel
    @State private var grabOffset: CGSize?

    var body: some View {
        GeometryReader { geo in
            let canvas = model.previewSize
            let video = AVMakeRect(aspectRatio: canvas, insideRect: CGRect(origin: .zero, size: geo.size))
            let scale = video.width / max(canvas.width, 1)
            let camRect = cameraRect(canvas: canvas, video: video, scale: scale)
            ZStack(alignment: .topLeading) {
                if let camRect {
                    Rectangle().fill(Color.white.opacity(0.001))
                        .frame(width: camRect.width, height: camRect.height)
                        .offset(x: camRect.minX, y: camRect.minY)
                        .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                        .gesture(DragGesture(coordinateSpace: .named("player"))
                            .onChanged { v in
                                if grabOffset == nil {
                                    grabOffset = CGSize(width: v.startLocation.x - camRect.midX, height: v.startLocation.y - camRect.midY)
                                }
                                let g = grabOffset ?? .zero
                                var c = model.camera
                                c.corner = .custom
                                c.x = ((v.location.x - g.width - video.minX) / video.width).clamped(0, 1)
                                c.y = ((v.location.y - g.height - video.minY) / video.height).clamped(0, 1)
                                model.camera = c
                            }
                            .onEnded { _ in grabOffset = nil })
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "player")
        }
    }

    /// The camera's rect in view coordinates (top-left origin).
    private func cameraRect(canvas: CGSize, video: CGRect, scale: Double) -> CGRect? {
        guard model.project.info.hasCamera, model.camera.visible else { return nil }
        let cs = model.camera
        let aspect: Double = switch cs.shape {
        case .circle, .rounded: 1
        case .rectangle: 4.0 / 3
        case .cutout: 16.0 / 9
        }
        let h = cs.size * canvas.height
        let r = CameraLayer.position(cs, size: CGSize(width: h * aspect, height: h), canvas: canvas)
        return CGRect(x: video.minX + r.minX * scale, y: video.minY + (canvas.height - r.maxY) * scale,
                      width: r.width * scale, height: r.height * scale)
    }
}
