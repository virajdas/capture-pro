import AppKit
import SwiftUI

/// The quiet floating thumbnail that slides in after a capture.
@MainActor
final class ScreenshotPreview {
    private static var current: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(image: CGImage, file: URL?) {
        dismiss(animated: false)
        let thumbWidth = 220.0
        let aspect = Double(image.height) / Double(image.width)
        let size = NSSize(width: thumbWidth, height: min(260, max(90, thumbWidth * aspect)))

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        let view = PreviewView(image: NSImage(cgImage: image, size: .zero), cgImage: image, file: file,
                               onHover: { hovering in hovering ? cancelTimer() : scheduleDismiss() },
                               onClose: { dismiss(animated: true) })
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let final = NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20)
        panel.setFrameOrigin(NSPoint(x: screen.maxX + 10, y: final.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrameOrigin(final)
            panel.animator().alphaValue = 1
        }
        current = panel
        scheduleDismiss()
    }

    private static func cancelTimer() { dismissWork?.cancel() }

    private static func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.shared.stored.previewSeconds, execute: work)
    }

    static func dismiss(animated: Bool) {
        guard let panel = current else { return }
        current = nil
        dismissWork?.cancel()
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX + 40, y: panel.frame.minY))
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct PreviewView: View {
    let image: NSImage
    let cgImage: CGImage
    let file: URL?
    let onHover: (Bool) -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .onTapGesture {
                    AnnotationEditor.open(image: cgImage, file: file)
                    onClose()
                }
                .onDrag {
                    if let file { return NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                    return NSItemProvider(object: image)
                }

            if hovering {
                HStack(spacing: 6) {
                    if let file {
                        button("folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                            onClose()
                        }
                        button("trash") {
                            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                            onClose()
                        }
                    }
                    button("xmark") { onClose() }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
            onHover(h)
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
