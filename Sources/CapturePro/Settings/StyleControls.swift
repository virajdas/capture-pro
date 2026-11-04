import SwiftUI
import UniformTypeIdentifiers

/// Background, frame, cursor and zoom controls — shared by Settings (defaults) and the editor.
struct BackgroundControls: View {
    @Binding var style: BackgroundStyle

    var body: some View {
        Picker("Type", selection: $style.kind) {
            ForEach(BackgroundKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch style.kind {
        case .mesh, .linear:
            PaletteGrid(selection: $style.paletteID, custom: $style.useCustomColors)
            Toggle("Custom colors", isOn: $style.useCustomColors)
            if style.useCustomColors {
                HStack {
                    ForEach(style.customColors.indices, id: \.self) { i in
                        ColorPicker("", selection: colorBinding(i)).labelsHidden()
                    }
                    Spacer()
                    Button { style.customColors.append(style.customColors.last ?? RGBA(1, 1, 1)) } label: { Image(systemName: "plus") }
                        .disabled(style.customColors.count >= 5)
                    Button { style.customColors.removeLast() } label: { Image(systemName: "minus") }
                        .disabled(style.customColors.count <= 2)
                }
            }
            if style.kind == .linear {
                LabeledSlider("Angle", value: $style.angle, in: 0...360, format: "%.0f°")
            }
            Toggle("Gently animate", isOn: $style.animated)
            if style.animated {
                LabeledSlider("Drift cycle", value: $style.cycleSeconds, in: 6...90, format: "%.0f s")
            }
        case .solid:
            ColorPicker("Color", selection: Binding(get: { Color(rgba: style.solid) }, set: { style.solid = RGBA($0) }))
        case .wallpaper:
            Text("Uses your current desktop picture.").foregroundStyle(.secondary).font(.callout)
            LabeledSlider("Blur", value: $style.imageBlur, in: 0...60, format: "%.0f")
        case .image:
            HStack {
                Text(style.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image chosen")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK { style.imagePath = panel.url?.path }
                }
            }
            LabeledSlider("Blur", value: $style.imageBlur, in: 0...60, format: "%.0f")
        }
        LabeledSlider("Grain", value: $style.grain, in: 0...0.2, format: "%.0f%%", scale: 100)
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(rgba: style.customColors[i]) }, set: { style.customColors[i] = RGBA($0) })
    }
}

struct PaletteGrid: View {
    @Binding var selection: String
    @Binding var custom: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 8), count: 6), spacing: 8) {
            ForEach(Palette.all) { p in
                let selected = !custom && p.id == selection
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: p.colors.map { Color(rgba: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                    .help(p.name)
                    .onTapGesture { selection = p.id; custom = false }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FrameControls: View {
    @Binding var style: FrameStyle
    var showAspect = true

    var body: some View {
        if showAspect {
            Picker("Aspect ratio", selection: $style.aspect) {
                ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
            }
        }
        LabeledSlider("Padding", value: $style.padding, in: 0...0.25, format: "%.0f%%", scale: 100)
        LabeledSlider("Corner radius", value: $style.cornerRadius, in: 0...48, format: "%.0f")
        LabeledSlider("Shadow", value: $style.shadowOpacity, in: 0...1, format: "%.0f%%", scale: 100)
        LabeledSlider("Shadow softness", value: $style.shadowRadius, in: 0...120, format: "%.0f")
        Toggle("Subtle edge highlight", isOn: $style.border)
    }
}

struct CursorControls: View {
    @Binding var style: CursorStyle

    var body: some View {
        Toggle("Show cursor", isOn: $style.visible)
        if style.visible {
            LabeledSlider("Size", value: $style.size, in: 0.6...4, format: "%.1f×")
            LabeledSlider("Smoothing", value: $style.smoothing, in: 0...1, format: "%.0f%%", scale: 100)
            Picker("Click effect", selection: $style.clickEffect) {
                ForEach(CursorEffect.allCases) { Text($0.label).tag($0) }
            }
            if style.clickEffect != .none {
                ColorPicker("Effect color", selection: Binding(get: { Color(rgba: style.clickColor) }, set: { style.clickColor = RGBA($0) }))
            }
            LabeledSlider("Press depth", value: Binding(get: { 1 - style.pressScale }, set: { style.pressScale = 1 - $0 }),
                          in: 0...0.4, format: "%.0f%%", scale: 100)
            LabeledSlider("Motion blur", value: $style.motionBlur, in: 0...1, format: "%.0f%%", scale: 100)
            Toggle("Hide when idle", isOn: $style.hideWhenIdle)
            if style.hideWhenIdle {
                LabeledSlider("Idle after", value: $style.idleSeconds, in: 0.5...8, format: "%.1f s")
            }
            Toggle("Soft shadow", isOn: $style.shadow)
            Toggle("Tilt while moving", isOn: $style.rotateWhileMoving)
        }
    }
}

struct ZoomControls: View {
    @Binding var style: ZoomStyle

    var body: some View {
        Toggle("Automatic zoom on clicks", isOn: $style.auto)
        Toggle("Zoom while typing", isOn: $style.zoomOnTyping).disabled(!style.auto)
        LabeledSlider("Zoom level", value: $style.scale, in: 1.1...4, format: "%.1f×")
        Toggle("Follow the cursor", isOn: $style.followCursor)
        LabeledSlider("Lead-in", value: $style.leadIn, in: 0...1.5, format: "%.2f s")
        LabeledSlider("Hold after", value: $style.hold, in: 0.5...5, format: "%.1f s")
        LabeledSlider("Camera speed", value: Binding(get: { 1.6 - style.response }, set: { style.response = 1.6 - $0 }),
                      in: 0.2...1.3, format: "%.0f%%", scale: 100 / 1.3)
        LabeledSlider("Motion blur", value: $style.motionBlur, in: 0...1, format: "%.0f%%", scale: 100)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let scale: Double

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String, scale: Double = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.scale = scale
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                Text(String(format: format, value * scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

extension Color {
    init(rgba: RGBA) { self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a) }
}

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
