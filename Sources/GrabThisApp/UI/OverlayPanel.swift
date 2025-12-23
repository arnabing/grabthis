import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    enum Mode: Equatable {
        case hidden
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

        // Actions (wired by SessionController)
        var onSend: (() -> Void)?
        var onCopy: (() -> Void)?
        var onInsert: (() -> Void)?
        var onClose: (() -> Void)?
    }

    let model = Model()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayRootView>?

    var isOverlayKeyWindow: Bool { panel?.isKeyWindow ?? false }

    func hide() {
        model.mode = .hidden
        panel?.orderOut(nil)
    }

    func presentListening(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        model.mode = .listening
        show(size: NSSize(width: 420, height: 120))
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
    }

    func presentProcessing() {
        model.mode = .processing
        show(size: NSSize(width: 360, height: 110))
    }

    func presentResponse(_ text: String) {
        model.responseText = text
        model.mode = .response
        show(size: NSSize(width: 520, height: 320))
    }

    func presentError(_ message: String) {
        model.responseText = message
        model.mode = .error
        show(size: NSSize(width: 420, height: 140))
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
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.styleMask = [.nonactivatingPanel, .borderless]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true

            self.hostingController = hosting
            self.panel = p
        }

        // In the listening/processing states, the overlay should never steal focus.
        // (For review/response, we allow interaction.)
        panel?.ignoresMouseEvents = (model.mode == .listening || model.mode == .processing)

        positionPanel(size: size)
        panel?.orderFrontRegardless()
    }

    func positionPanel(size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let p = panel else { return }

        p.setContentSize(size)

        // Top-center, slightly below menu bar.
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 18
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private struct OverlayRootView: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        Group {
            switch model.mode {
            case .hidden:
                EmptyView()
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

private struct ListeningCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: model.screenshot?.image)

            VStack(alignment: .leading, spacing: 4) {
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
                    Text("Listening…")
                        .font(.headline)
                    Text(model.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(model.transcript.isEmpty ? "Speak what you want…" : model.transcript)
                    .font(.callout)
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .cardBackground()
        .padding(10)
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


