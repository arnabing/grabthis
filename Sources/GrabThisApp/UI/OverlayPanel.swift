import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayPanelController {
    enum Mode: Equatable {
        case hidden
        case idleChip
        case listening
        case review
        case processing
        case response
        case error
    }

    @MainActor
    final class Model: ObservableObject {
        @Published var mode: Mode = .hidden
        @Published var appName: String = "grabthis"
        @Published var transcript: String = ""
        @Published var screenshot: ScreenshotCaptureResult?
        @Published var responseText: String = ""
        @Published var accessibilityTrusted: Bool = true
        @Published var audioLevel: Double = 0.0 // 0...1
        @Published var isHovering: Bool = false
        @Published var centerReserveWidth: Double = 220

        // Actions (wired by SessionController)
        var onSend: (() -> Void)?
        var onCopy: (() -> Void)?
        var onInsert: (() -> Void)?
        var onClose: (() -> Void)?
    }

    let model = Model()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayRootView>?
    private var autoDismissWork: DispatchWorkItem?
    private var hoverCancellable: AnyCancellable?

    var isOverlayKeyWindow: Bool { panel?.isKeyWindow ?? false }

    func hide() {
        model.mode = .hidden
        panel?.orderOut(nil)
    }

    func presentIdleChip() {
        model.mode = .idleChip
        model.transcript = ""
        model.screenshot = nil
        model.responseText = ""
        model.audioLevel = 0.0
        cancelAutoDismiss()
        show(size: NSSize(width: 560, height: 54))
    }

    func presentListening(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        model.mode = .listening
        cancelAutoDismiss()
        show(size: NSSize(width: 560, height: 70))
    }

    func updateListening(screenshot: ScreenshotCaptureResult? = nil, transcript: String? = nil) {
        if let screenshot { model.screenshot = screenshot }
        if let transcript { model.transcript = transcript }
    }

    func presentReview(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        model.mode = .review
        show(size: NSSize(width: 520, height: 260))
        scheduleAutoDismiss(seconds: 3.0)
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        model.accessibilityTrusted = trusted
    }

    func presentProcessing() {
        model.mode = .processing
        show(size: NSSize(width: 360, height: 110))
    }

    func presentResponse(_ text: String) {
        model.responseText = text
        model.mode = .response
        show(size: NSSize(width: 520, height: 320))
        scheduleAutoDismiss(seconds: 3.0)
    }

    func presentError(_ message: String) {
        model.responseText = message
        model.mode = .error
        show(size: NSSize(width: 420, height: 140))
        scheduleAutoDismiss(seconds: 3.0)
    }
}

private extension OverlayPanelController {
    func show(size: NSSize) {
        if panel == nil {
            let root = OverlayRootView(model: model)
            let hosting = NSHostingController(rootView: root)

            let p = NSPanel(
                contentViewController: hosting
            )
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.styleMask = [.nonactivatingPanel, .borderless]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true

            self.hostingController = hosting
            self.panel = p

            // Cancel auto-dismiss while hovering/interacting; reschedule when hover ends.
            hoverCancellable = model.$isHovering.sink { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.cancelAutoDismiss()
                } else if self.model.mode == .review || self.model.mode == .response || self.model.mode == .error {
                    self.scheduleAutoDismiss(seconds: 3.0)
                }
            }
        }

        // In the listening/processing states, the overlay should never steal focus.
        // (For review/response, we allow interaction.)
        panel?.ignoresMouseEvents = (model.mode == .listening || model.mode == .processing)

        // Use statusBar level for notch-attached states; float for bigger cards to avoid covering menus.
        if model.mode == .idleChip || model.mode == .listening {
            panel?.level = .statusBar
        } else {
            panel?.level = .floating
        }

        positionPanel(size: size)
        panel?.orderFrontRegardless()
    }

    func positionPanel(size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let p = panel else { return }

        // Clamp width to screen so the island is always “deliberate” on external displays.
        let full = screen.frame
        let clampedWidth = min(size.width, max(320, full.width - 60))
        let clampedSize = NSSize(width: clampedWidth, height: size.height)
        p.setContentSize(clampedSize)

        // Reserve space in the center so content doesn't get eaten by the notch cutout.
        model.centerReserveWidth = centerReserveWidth(for: screen)

        // Notch-ish positioning: top-center, anchored near the menu bar / safe area inset.
        // We avoid exact notch geometry (not public) and approximate using safe area inset.
        let topInset = screen.safeAreaInsets.top
        let x = full.midX - clampedSize.width / 2
        // Place within the menu bar/safe-area region, with a small downward offset so it “hugs” the notch.
        let y = full.maxY - topInset + 6 - clampedSize.height
        p.setFrame(NSRect(x: x, y: y, width: clampedSize.width, height: clampedSize.height), display: true)
    }

    func centerReserveWidth(for screen: NSScreen) -> Double {
        // Heuristic: built-in displays with notch need a larger reserved center area.
        // External displays still reserve a little, but less (the bar is decorative there).
        let name = screen.localizedName.lowercased()
        let isBuiltIn = name.contains("built") || name.contains("color lcd") || name.contains("retina")
        return isBuiltIn ? 240 : 120
    }

    func scheduleAutoDismiss(seconds: TimeInterval) {
        cancelAutoDismiss()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Return to idle chip instead of disappearing completely.
                self.presentIdleChip()
            }
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancelAutoDismiss() {
        autoDismissWork?.cancel()
        autoDismissWork = nil
    }
}

private struct OverlayRootView: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        Group {
            switch model.mode {
            case .hidden:
                EmptyView()
            case .idleChip:
                IdleChip(model: model)
            case .listening:
                ListeningCard(model: model)
            case .review:
                ReviewCard(model: model)
            case .processing:
                ProcessingCard()
            case .response:
                ResponseCard(model: model, isError: false)
            case .error:
                ResponseCard(model: model, isError: true)
            }
        }
    }
}

private struct IdleChip: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        NotchIsland(
            centerReserveWidth: model.centerReserveWidth,
            left: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.cyan.opacity(0.9))
                        .frame(width: 6, height: 6)
                    Text(model.isHovering ? "Hold fn to talk" : "grabthis")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            },
            right: {
                // Keep right side extremely quiet in idle.
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        )
        .scaleEffect(model.isHovering ? 1.03 : 1.0)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .onHover { isHovering in
            model.isHovering = isHovering
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isHovering)
    }
}

private struct ListeningCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false

    var body: some View {
        NotchIsland(
            centerReserveWidth: model.centerReserveWidth,
            isActiveGlow: true,
            left: {
                HStack(spacing: 12) {
                    PillVisualizer(level: model.audioLevel)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.cyan.opacity(0.95))
                                .frame(width: 8, height: 8)
                                .scaleEffect(pulse ? 1.6 : 1.0)
                                .opacity(pulse ? 0.55 : 1.0)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                        pulse = true
                                    }
                                }
                            Text("Listening")
                                .font(.callout.weight(.semibold))
                            Text(model.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(model.transcript.isEmpty ? "Speak…" : model.transcript)
                            .font(.callout)
                            .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
            },
            right: {
                // Keep right side minimal while FN is held: subtle mic glyph.
                Image(systemName: "mic.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .scaleEffect(1.02)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.audioLevel)
    }
}

private struct NotchIsland<Left: View, Right: View>: View {
    let centerReserveWidth: Double
    var isActiveGlow: Bool = false
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
                .overlay {
                    if isActiveGlow {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.cyan.opacity(0.55),
                                        Color.blue.opacity(0.22),
                                        Color.purple.opacity(0.18),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 1.2
                            )
                            .blur(radius: 0.7)
                            .opacity(0.95)
                    }
                }
                .shadow(color: isActiveGlow ? Color.cyan.opacity(0.16) : .clear, radius: 14, y: 0)
                .shadow(color: isActiveGlow ? Color.purple.opacity(0.10) : .clear, radius: 18, y: 0)

            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    left()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                Spacer().frame(width: max(90, centerReserveWidth))

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    right()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(height: 44)
    }
}

private struct PillVisualizer: View {
    let level: Double // 0...1

    var body: some View {
        let clamped = min(1.0, max(0.0, level))
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.85),
                            Color.blue.opacity(0.55),
                            Color.purple.opacity(0.45),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .scaleEffect(x: 0.20 + 0.80 * clamped, y: 1.0, anchor: .leading)
                .opacity(0.35 + 0.65 * clamped)
                .animation(.easeOut(duration: 0.10), value: clamped)
        }
        .frame(width: 88, height: 16)
        .accessibilityLabel("Mic level")
    }
}

private struct ReviewCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Thumbnail(image: model.screenshot?.image)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready")
                        .font(.headline)
                    Text(model.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.onClose?() }
                    .buttonStyle(.borderless)
            }

            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .onAppear { draft = model.transcript }
                .onChange(of: draft) { _, newValue in model.transcript = newValue }

            if !model.accessibilityTrusted {
                HStack(spacing: 10) {
                    Text("Auto‑insert is disabled (Accessibility permission needed). Copied to clipboard — press ⌘V.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Enable") {
                        SystemSettingsDeepLinks.openAccessibility()
                        AutoInsertService.requestAccessibilityPermissionPrompt()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
            }

            HStack {
                Button("Insert") { model.onInsert?() }
                Button("Copy") { model.onCopy?() }
                Spacer()
                Button("Send") { model.onSend?() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .cardBackground()
        .padding(10)
    }
}

private struct ProcessingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Processing…").font(.headline)
                Text("Preparing your request").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .cardBackground()
        .padding(10)
    }
}

private struct ResponseCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isError ? "Error" : "Response")
                    .font(.headline)
                Spacer()
                Button("Close") { model.onClose?() }
            }
            ScrollView {
                Text(model.responseText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") { model.onCopy?() }
                Spacer()
            }
        }
        .cardBackground()
        .padding(10)
    }
}

private struct Thumbnail: View {
    let image: CGImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .frame(width: 64, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )

            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
    }
}


