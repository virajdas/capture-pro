import AVFoundation
import SwiftUI

/// The first-run walkthrough. Replayable from the menu bar ("Welcome Tour…").
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindowController?
    private let window: NSWindow

    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: "onboardedV2") }

    static func show() {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = OnboardingWindowController()
        current = c
        AppWindows.opened()
        c.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(finish: { [weak self] in self?.window.close() }))
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "onboardedV2")
        UserDefaults.standard.set(true, forKey: "onboarded")
        Self.current = nil
        AppWindows.closed()
    }
}

private enum Step: Int, CaseIterable {
    case welcome, permissions, screenshots, recording, look, shortcuts, ready
}

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step: Step = .welcome
    @State private var forward = true

    var body: some View {
        ZStack {
            FlowingBackdrop(palette: step == .welcome || step == .ready ? "candy" : "lavender",
                            intensity: step == .welcome || step == .ready ? 1 : 0.35)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    page
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .frame(width: 780, height: 560)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .permissions: PermissionsPage()
        case .screenshots: ScreenshotsPage()
        case .recording: RecordingPage()
        case .look: LookPage()
        case .shortcuts: ShortcutsPage()
        case .ready: ReadyPage(finish: finish)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .ready {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if step == .welcome {
                Button("Skip tour") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
            Spacer()
            if step != .ready {
                Button(step == .welcome ? "Get Started" : "Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Color.clear.frame(width: 80, height: 1)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { step = next }
    }
}

// MARK: Pages

private struct PageScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            content
        }
        .padding(.horizontal, 48)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct WelcomePage: View {
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                .scaleEffect(appear ? 1 : 0.85)
                .opacity(appear ? 1 : 0)
            Text("Capture Pro")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            Text("Calm screenshots and beautiful recordings,\nright from your menu bar.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
        .offset(y: appear ? 0 : 12)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { appear = true } }
    }
}

private struct PermissionsPage: View {
    @State private var screen = Permissions.screenRecording
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var ax = Permissions.accessibility
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PageScaffold(symbol: "lock.shield", title: "A few permissions",
                     subtitle: "macOS asks you to allow these once. Everything stays on your Mac — Capture Pro never connects to the internet.") {
            VStack(spacing: 10) {
                row("Screen Recording", "Required to take screenshots and recordings.", "rectangle.dashed.badge.record", screen, required: true) {
                    if !Permissions.requestScreenRecording() { Permissions.openSettings("Privacy_ScreenCapture") }
                }
                row("Microphone", "Optional — only used when you turn on the mic for a recording.", "mic", mic) {
                    Task { mic = await AVCaptureDevice.requestAccess(for: .audio) }
                }
                row("Accessibility", "Optional — lets auto-zoom notice typing. Only timing is stored, never keys.", "keyboard", ax) {
                    Permissions.requestAccessibility()
                }
            }
            .frame(maxWidth: 560)
            if !screen {
                Text("After allowing Screen Recording, macOS may ask you to reopen Capture Pro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(poll) { _ in
            screen = Permissions.screenRecording
            mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ax = Permissions.accessibility
        }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ granted: Bool, required: Bool = false,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if required { Text("Required").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…", action: action)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: granted)
    }
}

private struct FeatureTile: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ScreenshotsPage: View {
    var body: some View {
        let k = Preferences.shared.stored.shortcuts
        PageScaffold(symbol: "camera.viewfinder", title: "Screenshots, then polish",
                     subtitle: "Click the menu bar icon or press a shortcut. Your capture is copied to the clipboard and opens in a quiet editor.") {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    FeatureTile(symbol: "viewfinder", title: "Area  \(k[.captureArea]?.display ?? "")",
                                detail: "Drag to select. Hold ⇧ for a square, press Space to pick a window.")
                    FeatureTile(symbol: "macwindow", title: "Window  \(k[.captureWindow]?.display ?? "")",
                                detail: "Hover a window and click. Its shadow comes along if you like.")
                    FeatureTile(symbol: "display", title: "Screen  \(k[.captureScreen]?.display ?? "")",
                                detail: "Captures the whole display under your pointer.")
                }
                GridRow {
                    FeatureTile(symbol: "pencil.tip.crop.circle", title: "Annotate",
                                detail: "Arrows, shapes, text, numbered steps, highlights, callouts and stamps.")
                    FeatureTile(symbol: "eye.slash", title: "Hide what's private",
                                detail: "Blur, pixelate or redact anything. Spotlight and magnify what matters.")
                    FeatureTile(symbol: "sparkles", title: "Beautify",
                                detail: "One switch adds a soft gradient, padding, rounded corners and shadow.")
                }
            }
            .frame(maxWidth: 680, maxHeight: 250)
        }
    }
}

private struct RecordingPage: View {
    var body: some View {
        PageScaffold(symbol: "record.circle", title: "Recordings that look produced",
                     subtitle: "Record an area, a window or your whole screen. Capture Pro does the editing for you — and every bit of it stays adjustable.") {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    FeatureTile(symbol: "plus.magnifyingglass", title: "Automatic zoom",
                                detail: "Glides in where you click or type, then gently back out.")
                    FeatureTile(symbol: "cursorarrow.motionlines", title: "Silky cursor",
                                detail: "Smoothed, enlarged, with soft click ripples. Hides when idle.")
                    FeatureTile(symbol: "paintpalette", title: "Gorgeous frame",
                                detail: "Flowing gradients behind a rounded, shadowed screen.")
                }
                GridRow {
                    FeatureTile(symbol: "waveform", title: "Audio when you want it",
                                detail: "Toggle microphone and system audio right before each take.")
                    FeatureTile(symbol: "timeline.selection", title: "Simple editor",
                                detail: "Trim, switch individual zooms on or off, tweak the look.")
                    FeatureTile(symbol: "square.and.arrow.up", title: "Export anywhere",
                                detail: "MP4, MOV or GIF up to 4K60 — saved to the folder you choose.")
                }
            }
            .frame(maxWidth: 680, maxHeight: 250)
        }
    }
}

private struct LookPage: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        PageScaffold(symbol: "sparkles", title: "Choose your look",
                     subtitle: "Pick a starting style for recordings and beautified screenshots. You can change it anytime, even per recording.") {
            ScrollView {
                PresetGallery(style: $prefs.stored.style, columns: 4)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 660, maxHeight: 260)
        }
    }
}

private struct ShortcutsPage: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        PageScaffold(symbol: "command", title: "Your shortcuts",
                     subtitle: "These work from anywhere. Click one to change it.") {
            VStack(spacing: 0) {
                ForEach(HotKeyAction.allCases) { action in
                    HStack {
                        Text(action.label)
                        Spacer()
                        ShortcutField(shortcut: Binding(
                            get: { prefs.stored.shortcuts[action] },
                            set: { prefs.stored.shortcuts[action] = $0 }))
                    }
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    if action != HotKeyAction.allCases.last { Divider().padding(.horizontal, 16) }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 460)
        }
    }
}

private struct ReadyPage: View {
    let finish: () -> Void
    @State private var launch = Preferences.shared.launchAtLogin
    @State private var bob = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.up")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: bob ? -6 : 4)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: bob)
                .padding(.top, 36)
            Text("You're all set")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Capture Pro lives in your menu bar. Click its icon whenever you need it.")
                .font(.title3).foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
            Toggle("Open Capture Pro at login", isOn: $launch)
                .toggleStyle(.switch)
                .foregroundStyle(.white)
                .onChange(of: launch) { _, v in Preferences.shared.launchAtLogin = v }
                .padding(.top, 6)
            HStack(spacing: 12) {
                Button {
                    finish()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Actions.captureArea() }
                } label: { Label("Try a Screenshot", systemImage: "viewfinder").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Done") { finish() }.controlSize(.large).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
            Spacer()
        }
        .onAppear { bob = true }
    }
}

/// A slowly flowing mesh gradient behind the onboarding pages.
struct FlowingBackdrop: View {
    let palette: String
    let intensity: Double

    var body: some View {
        let colors = Palette.named(palette).colors.map { Color(rgba: $0) }
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate / 6
            let mid = SIMD2<Float>(Float(0.5 + 0.18 * sin(t)), Float(0.5 + 0.15 * cos(t * 0.8)))
            let points: [SIMD2<Float>] = [
                SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
                SIMD2(0, 0.5), mid, SIMD2(1, 0.5),
                SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
            ]
            MeshGradient(width: 3, height: 3, points: points, colors: [
                colors[0], colors[1], colors[2],
                colors[3], colors[4 % colors.count], colors[0],
                colors[2], colors[3], colors[1],
            ])
            .opacity(intensity)
        }
        .background(.background)
        .animation(.easeInOut(duration: 0.6), value: intensity)
    }
}
