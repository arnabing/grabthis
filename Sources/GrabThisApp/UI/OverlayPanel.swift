import AppKit
import SwiftUI
import Combine

// MARK: - Constants (from boring.notch)

private let shadowPadding: CGFloat = 20
private let openNotchSize: CGSize = .init(width: 640, height: 190)
private let windowSize: CGSize = .init(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// Animation springs (from boring.notch)
private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

@MainActor
private func getClosedNotchSize(screen: NSScreen? = nil) -> CGSize {
    let selectedScreen = screen ?? NSScreen.main
    var notchHeight: CGFloat = 28
    var notchWidth: CGFloat = 185

    if let screen = selectedScreen {
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        }
        if screen.safeAreaInsets.top > 0 {
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
        }
    }
    return CGSize(width: notchWidth, height: notchHeight)
}

// MARK: - Custom Window (from boring.notch)

private class GrabThisWindow: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false

        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

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
        @Published var mode: Mode = .hidden {
            didSet {
                // Set isOpen directly - animation is handled at call sites via withAnimation()
                // This matches boring.notch's pattern where animation context is established BEFORE state changes
                if mode == .listening || mode == .review || mode == .processing || mode == .response || mode == .error {
                    isOpen = true
                }
                if mode == .idleChip || mode == .hidden {
                    isOpen = false
                }
            }
        }
        @Published var appName: String = "grabthis"
        @Published var transcript: String = ""
        @Published var screenshot: ScreenshotCaptureResult?
        @Published var responseText: String = ""
        @Published var accessibilityTrusted: Bool = true
        @Published var audioLevel: Double = 0.0
        @Published var isHovering: Bool = false
        @Published var isOpen: Bool = false  // Now a stored property
        @Published var closedNotchSize: CGSize = getClosedNotchSize()

        var hasPhysicalNotch: Bool {
            guard let screen = NSScreen.main else { return false }
            return screen.safeAreaInsets.top > 0
        }

        // Actions (wired by SessionController)
        var onSend: (() -> Void)?
        var onCopy: (() -> Void)?
        var onInsert: (() -> Void)?
        var onClose: (() -> Void)?
    }

    let model = Model()

    private var panel: GrabThisWindow?
    private var hostingController: NSHostingController<OverlayRootView>?
    private var autoDismissWork: DispatchWorkItem?
    private var hoverCancellable: AnyCancellable?

    var isOverlayKeyWindow: Bool { panel?.isKeyWindow ?? false }

    func hide() {
        withAnimation(closeAnimation) {
            model.mode = .hidden
        }
        panel?.orderOut(nil)
    }

    func presentIdleChip() {
        withAnimation(closeAnimation) {
            model.mode = .idleChip
        }
        model.transcript = ""
        model.screenshot = nil
        model.responseText = ""
        model.audioLevel = 0.0
        cancelAutoDismiss()
        show()
    }

    func presentListening(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        withAnimation(openAnimation) {
            model.mode = .listening
        }
        cancelAutoDismiss()
        show()
    }

    func updateListening(screenshot: ScreenshotCaptureResult? = nil, transcript: String? = nil) {
        if let screenshot { model.screenshot = screenshot }
        if let transcript { model.transcript = transcript }
    }

    func presentReview(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        withAnimation(openAnimation) {
            model.mode = .review
        }
        show()
        scheduleAutoDismiss(seconds: 3.0)
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        model.accessibilityTrusted = trusted
    }

    func presentProcessing() {
        withAnimation(openAnimation) {
            model.mode = .processing
        }
        show()
    }

    func presentResponse(_ text: String) {
        model.responseText = text
        withAnimation(openAnimation) {
            model.mode = .response
        }
        show()
        scheduleAutoDismiss(seconds: 3.0)
    }

    func presentError(_ message: String) {
        model.responseText = message
        withAnimation(openAnimation) {
            model.mode = .error
        }
        show()
        scheduleAutoDismiss(seconds: 3.0)
    }
}

private extension OverlayPanelController {
    func show() {
        let isNewPanel = panel == nil

        if isNewPanel {
            let root = OverlayRootView(model: model)
            let hosting = NSHostingController(rootView: root)

            // Create window at FIXED max size (boring.notch pattern)
            let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
            let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
            let p = GrabThisWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
            p.contentView = hosting.view

            // Start with alpha 0 for fade-in animation (boring.notch pattern)
            p.alphaValue = 0

            self.hostingController = hosting
            self.panel = p

            // Cancel auto-dismiss while hovering
            hoverCancellable = model.$isHovering.sink { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.cancelAutoDismiss()
                } else if self.model.mode == .review || self.model.mode == .response || self.model.mode == .error {
                    self.scheduleAutoDismiss(seconds: 3.0)
                }
            }
        }

        // Update closed notch size for current screen
        if let screen = NSScreen.main {
            model.closedNotchSize = getClosedNotchSize(screen: screen)
        }

        // Position window (fixed position at top of screen)
        positionWindow()
        panel?.orderFrontRegardless()

        // Fade in the window (boring.notch style)
        if isNewPanel {
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.allowsImplicitAnimation = true
                    self.panel?.animator().alphaValue = 1
                }
            }
        }
    }

    func positionWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let p = panel else { return }

        // Update closed notch size for current screen
        model.closedNotchSize = getClosedNotchSize(screen: screen)

        let screenFrame = screen.frame
        p.setFrameOrigin(NSPoint(
            x: screenFrame.origin.x + (screenFrame.width / 2) - p.frame.width / 2,
            y: screenFrame.origin.y + screenFrame.height - p.frame.height
        ))
    }

    func scheduleAutoDismiss(seconds: TimeInterval) {
        cancelAutoDismiss()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
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

// MARK: - Root View (boring.notch layout pattern)

private struct OverlayRootView: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var hoverTask: Task<Void, Never>?

    private var topCornerRadius: CGFloat {
        model.isOpen ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        model.isOpen ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                notchContent
                    .padding(.horizontal, model.isOpen ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.bottom)
                    .padding([.horizontal, .bottom], model.isOpen ? 12 : 0)
                    .background(Color.black)
                    .clipShape(NotchShape(
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius
                    ))
                    .overlay(alignment: .top) {
                        // Top edge line to blend with notch
                        Rectangle()
                            .fill(Color.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(color: (model.isOpen || model.isHovering) ? .black.opacity(0.7) : .clear, radius: 6)
                    // Use explicit closed height instead of nil - nil might not animate properly
                    .frame(height: model.isOpen ? openNotchSize.height : model.closedNotchSize.height)
                    // Animate for BOTH mode changes AND direct isOpen changes (hover)
                    // boring.notch uses notchState for mode-triggered animations
                    .animation(model.isOpen ? openAnimation : closeAnimation, value: model.mode)
                    .animation(model.isOpen ? openAnimation : closeAnimation, value: model.isOpen)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
            }
        }
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                model.isHovering = true
            }

            // After 0.3s delay, expand the notch (copy boring.notch behavior)
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard model.mode != .hidden else { return }
                    withAnimation(openAnimation) {
                        model.isOpen = true
                    }
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(animationSpring) {
                        model.isHovering = false
                    }
                    // Close the expansion (only for idle/listening modes)
                    if model.mode == .idleChip || model.mode == .listening {
                        withAnimation(closeAnimation) {
                            model.isOpen = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content Views (boring.notch pattern: mutually exclusive if/else)

    @ViewBuilder
    private var notchContent: some View {
        // MUTUALLY EXCLUSIVE - only one content tree exists at a time (boring.notch pattern)
        // This prevents dual content conflict where both closed and expanded show simultaneously
        if model.isOpen {
            expandedContent
                .id("expanded")  // Force unique view identity for repeated transitions
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
        } else {
            closedContent
                .id("closed")  // Force unique view identity for repeated transitions
        }
    }

    @ViewBuilder
    private var closedContent: some View {
        switch model.mode {
        case .hidden:
            EmptyView()
        case .idleChip:
            IdleChipContent(model: model)
        case .listening:
            if model.hasPhysicalNotch {
                ListeningSplitContent(model: model)
            } else {
                ListeningContent(model: model)
            }
        case .review, .processing, .response, .error:
            EmptyView()  // Open-only modes have no closed content
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch model.mode {
        case .hidden:
            EmptyView()
        case .idleChip:
            IdleExpandedContent(model: model)
        case .listening, .review:
            // UNIFIED VIEW - seamless transition between listening and ready
            ActiveSessionContent(model: model)
        case .processing:
            ProcessingCard()
        case .response:
            ResponseCard(model: model, isError: false)
        case .error:
            ResponseCard(model: model, isError: true)
        }
    }
}

// MARK: - Closed State Content (no explicit height - sizes naturally)

private struct IdleChipContent: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.cyan.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(model.isHovering ? "Hold fn to talk" : "grabthis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
            // No static icon - idle state is clean (boring.notch pattern)
        }
        .frame(width: model.closedNotchSize.width - 20, height: model.closedNotchSize.height)
    }
}

private struct ListeningContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            AudioBarVisualizer()
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            Image(systemName: "mic.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: model.closedNotchSize.width - 20, height: model.closedNotchSize.height)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.audioLevel)
    }
}

// MARK: - Expanded Content Views (for hover/auto-expand)

private struct IdleExpandedContent: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                Text("GrabThis")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Text("Press fn to start listening")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Unified Active Session Content (Listening + Review)
// This provides seamless transition between listening and ready states
// by keeping the same view identity and animating individual properties

private struct ActiveSessionContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false

    private var isListening: Bool { model.mode == .listening }
    private var isReady: Bool { model.mode == .review }

    private var statusColor: Color {
        isListening ? .cyan : .green
    }

    private var statusText: String {
        isListening ? "Listening..." : "Ready"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header row - elements animate individually
            HStack {
                // Status indicator - color animates, pulse only when listening
                Circle()
                    .fill(statusColor.opacity(0.95))
                    .frame(width: 10, height: 10)
                    .scaleEffect(isListening && pulse ? 1.4 : 1.0)
                    .opacity(isListening && pulse ? 0.6 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }

                // Status text - crossfades between states
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)

                Spacer()

                // Right area - conditional content with crossfade
                ZStack {
                    if isListening {
                        AudioBarVisualizer()
                            .transition(.opacity)
                    }
                    if isReady {
                        Button(action: { model.onClose?() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.mode)
            }

            // Transcript - STAYS IN PLACE (key for seamless feel)
            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4)
            } else {
                Text(isListening ? "Speak now..." : "No transcript")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.interpolate)
            }

            Spacer()

            // Action buttons - fade in when ready
            if isReady {
                HStack(spacing: 12) {
                    Button(action: { model.onInsert?() }) {
                        Label("Insert", systemImage: "text.insert")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.8))

                    Button(action: { model.onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.8))

                    Spacer()

                    Button(action: { model.onSend?() }) {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: statusColor)
        .onHover { model.isHovering = $0 }
    }
}

// MARK: - Split Content for MacBook with Notch

private struct ListeningSplitContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: Expands to left screen edge
            HStack {
                Spacer()
                Circle()
                    .fill(Color.cyan.opacity(0.95))
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .opacity(pulse ? 0.6 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)  // Expand to fill left of notch

            // CENTER: Black spacer (the notch gap) - exact notch width
            Rectangle()
                .fill(.black)
                .frame(width: model.closedNotchSize.width)

            // RIGHT: Expands to right screen edge
            HStack {
                AudioBarVisualizer()
                    .padding(.leading, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity)  // Expand to fill right of notch
        }
        .frame(height: model.closedNotchSize.height)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.audioLevel)
    }
}

// MARK: - Open State Content (explicit heights OK)

private struct ReviewCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 12) {
            // Header row - matches ListeningExpandedContent style
            HStack {
                Circle()
                    .fill(Color.green.opacity(0.95))
                    .frame(width: 10, height: 10)
                Text("Ready")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // Transcript text - same style as listening
            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4)
            } else {
                Text("No transcript")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Action buttons at bottom
            HStack(spacing: 12) {
                Button(action: { model.onInsert?() }) {
                    Label("Insert", systemImage: "text.insert")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))

                Button(action: { model.onCopy?() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))

                Spacer()

                Button(action: { model.onSend?() }) {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { draft = model.transcript }
        .onHover { model.isHovering = $0 }
    }
}

private struct ProcessingCard: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            // Header row - matches other expanded content styles
            HStack {
                Circle()
                    .fill(Color.orange.opacity(0.95))
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .opacity(pulse ? 0.6 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                Text("Processing...")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white)
            }

            Text("Preparing your request")
                .font(.body)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ResponseCard: View {
    @ObservedObject var model: OverlayPanelController.Model
    let isError: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Header row - matches other expanded content styles
            HStack {
                Circle()
                    .fill(isError ? Color.red.opacity(0.95) : Color.green.opacity(0.95))
                    .frame(width: 10, height: 10)
                Text(isError ? "Error" : "Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // Response text - same style as transcript
            Text(model.responseText)
                .font(.body)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(4)

            Spacer()

            // Action buttons at bottom
            HStack(spacing: 12) {
                Button(action: { model.onCopy?() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onHover { model.isHovering = $0 }
    }
}

// MARK: - Supporting Views

// MARK: - Audio Bar Visualizer (boring.notch style)

private struct AudioBarVisualizer: View {
    let barCount = 4
    @State private var scales: [CGFloat] = [0.5, 0.7, 0.4, 0.6]

    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.cyan.opacity(0.9))
                    .frame(width: 3, height: 14)
                    .scaleEffect(y: scales[index], anchor: .bottom)
                    .animation(.easeInOut(duration: 0.25), value: scales[index])
            }
        }
        .onReceive(timer) { _ in
            for i in 0..<barCount {
                scales[i] = CGFloat.random(in: 0.35...1.0)
            }
        }
    }
}

private struct PillVisualizer: View {
    let level: Double

    var body: some View {
        let clamped = min(1.0, max(0.0, level))
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(0.1))
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
        .frame(width: 60, height: 14)
    }
}

private struct Thumbnail: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(width: 64, height: 44)

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
