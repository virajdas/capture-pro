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
        Toggle("Shadow", isOn: $style.shadowEnabled)
        if style.shadowEnabled {
            HStack(spacing: 6) {
                ForEach(Self.shadowPresets, id: \.0) { name, apply in
                    Button(name) { apply(&style) }.controlSize(.small)
                }
            }
            ColorPicker("Shadow color", selection: Binding(
                get: { Color(rgba: style.shadowColor) }, set: { style.shadowColor = RGBA($0) }), supportsOpacity: false)
            LabeledSlider("Opacity", value: $style.shadowOpacity, in: 0...1, format: "%.0f%%", scale: 100)
            LabeledSlider("Softness", value: $style.shadowRadius, in: 0...150, format: "%.0f")
            LabeledSlider("Spread", value: $style.shadowSpread, in: -20...60, format: "%.0f")
            LabeledSlider("Offset X", value: $style.shadowOffsetX, in: -80...80, format: "%.0f")
            LabeledSlider("Offset Y", value: $style.shadowOffset, in: -80...80, format: "%.0f")
            if style.padding < 0.001 {
                Text("Add some padding to see the shadow.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("Subtle edge highlight", isOn: $style.border)
    }
}

extension FrameControls {
    static let shadowPresets: [(String, (inout FrameStyle) -> Void)] = [
        ("Soft", { $0.shadowOpacity = 0.35; $0.shadowRadius = 60; $0.shadowOffset = 18; $0.shadowOffsetX = 0; $0.shadowSpread = 0 }),
        ("Crisp", { $0.shadowOpacity = 0.5; $0.shadowRadius = 14; $0.shadowOffset = 6; $0.shadowOffsetX = 0; $0.shadowSpread = 0 }),
        ("Floating", { $0.shadowOpacity = 0.45; $0.shadowRadius = 90; $0.shadowOffset = 40; $0.shadowOffsetX = 0; $0.shadowSpread = -10 }),
        ("Glow", { $0.shadowOpacity = 0.6; $0.shadowRadius = 70; $0.shadowOffset = 0; $0.shadowOffsetX = 0; $0.shadowSpread = 10 }),
    ]
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
        if style.followCursor {
            LabeledSlider("Pan softness", value: $style.response, in: 0.3...2, format: "%.1f s")
        }

        VStack(alignment: .leading, spacing: 10) {
            Picker("Animation", selection: $style.curve) {
                ForEach(ZoomCurve.allCases) { Text($0.label).tag($0) }
            }
            HStack(alignment: .top, spacing: 12) {
                CurveGraph(curve: style.curve)
                    .frame(width: 92, height: 64)
                Text(style.curve.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledSlider("Zoom in", value: $style.zoomInDuration, in: 0.3...2.5, format: "%.1f s")
        LabeledSlider("Zoom out", value: $style.zoomOutDuration, in: 0.3...2.5, format: "%.1f s")
        LabeledSlider("Lead-in", value: $style.leadIn, in: 0...2, format: "%.2f s")
        LabeledSlider("Hold after click", value: $style.hold, in: 1...6, format: "%.1f s")
        LabeledSlider("Motion blur", value: $style.motionBlur, in: 0...1, format: "%.0f%%", scale: 100)
    }
}

/// A small plot of the easing curve, with a dot that rides along it.
struct CurveGraph: View {
    let curve: ZoomCurve
    @State private var start = Date()

    var body: some View {
        SwiftUI.TimelineView(.animation) { ctx in
            Canvas { g, size in
                let inset: CGFloat = 6
                let w = size.width - inset * 2, h = size.height - inset * 2
                func point(_ x: Double) -> CGPoint {
                    CGPoint(x: inset + x * w, y: inset + h - curve.value(x) * h * 0.86 - h * 0.07)
                }
                let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
                g.fill(frame, with: .color(.secondary.opacity(0.08)))
                var guide = Path()
                guide.move(to: point(0)); guide.addLine(to: CGPoint(x: inset + w, y: point(0).y))
                g.stroke(guide, with: .color(.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                var path = Path()
                path.move(to: point(0))
                for i in 1...60 { path.addLine(to: point(Double(i) / 60)) }
                g.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // 1.6 s loop: animate across, rest at the end.
                let phase = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.6) / 1.2
                let p = point(min(1, phase))
                g.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
            }
        }
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

/// A grid of rendered look presets. Tapping one replaces the look (auto-zoom choices are kept).
struct PresetGallery: View {
    @Binding var style: StyleSettings
    var columns = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
            ForEach(LookPreset.all) { preset in
                PresetCard(preset: preset, selected: preset.style(keepingAutoZoom: style) == style) {
                    withAnimation(.easeOut(duration: 0.2)) { style = preset.style(keepingAutoZoom: style) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PresetCard: View {
    let preset: LookPreset
    let selected: Bool
    let action: () -> Void
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.secondary.opacity(0.1))
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.25 : 0.08),
                                  lineWidth: selected ? 2.5 : 1))
                .scaleEffect(hovering ? 1.02 : 1)
                Text(preset.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(preset.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .task {
            let img = await LookPreset.thumbnail(for: preset)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
    }
}
