import AppKit
import SwiftUI

/// A small floating bar shown while choosing what to record, so audio can be set per recording.
@MainActor
final class RecordOptionsBar {
    private var panel: NSPanel?

    func show(on screen: NSScreen) {
        let size = NSSize(width: 600, height: 52)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 36,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = FirstClickHostingView(rootView: RecordOptionsView())
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordOptionsView: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("Include").font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 6)
            chip("System Audio", on: "speaker.wave.2.fill", off: "speaker.slash", value: $prefs.stored.systemAudio)
            chip("Microphone", on: "mic.fill", off: "mic.slash", value: $prefs.stored.microphone)
            chip("Camera", on: "video.fill", off: "video.slash", value: $prefs.stored.camera)
            if prefs.stored.camera {
                chip("Preview", on: "eye.fill", off: "eye.slash", value: $prefs.stored.showCameraPreview)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(8)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ title: String, on: String, off: String, value: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { value.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: value.wrappedValue ? on : off)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(value.wrappedValue ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08), in: Capsule())
                .foregroundStyle(value.wrappedValue ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(value.wrappedValue ? "\(title) will be recorded" : "\(title) is off")
    }
}
