import AppKit
import SwiftUI
import Combine

// MARK: - Constants (from boring.notch)

private let shadowPadding: CGFloat = 20
private let openNotchSize: CGSize = .init(width: 480, height: 210)
private let chatNotchSize: CGSize = .init(width: 480, height: 350)  // Taller for chat mode
private let windowSize: CGSize = .init(width: openNotchSize.width, height: chatNotchSize.height + shadowPadding)
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// Animation springs - OPTIMIZED for faster perceived response
// (Original boring.notch was 0.42/0.45 - felt sluggish when switching from Now Playing)
private let openAnimation = Animation.spring(response: 0.22, dampingFraction: 0.85, blendDuration: 0)
private let closeAnimation = Animation.spring(response: 0.25, dampingFraction: 1.0, blendDuration: 0)
private let animationSpring = Animation.interactiveSpring(response: 0.20, dampingFraction: 0.85, blendDuration: 0)

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
    /// Set to true when the window should accept keyboard input (e.g., chat mode)
    var allowsKeyboardInput: Bool = false

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

        // Enable mouse handling for non-key panel (needed for tap gestures)
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
    }

    // Always allow key status so tap gestures work in the panel
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class OverlayPanelController {
    enum Mode: Equatable {
        case hidden
        case idleChip
        case listening
        case transcribing  // STT processing (WhisperKit batch transcription)
        case review
        case processing    // AI processing
        case response
        case error
    }

    @MainActor
    final class Model: ObservableObject {
        @Published var mode: Mode = .hidden {
            didSet {
                // Set isOpen directly - animation is handled at call sites via withAnimation()
                // This matches boring.notch's pattern where animation context is established BEFORE state changes
                if mode == .listening {
                    // Check if user wants to hide live transcription (minimal Wispr-style UX)
                    let hideLiveTranscription = UserDefaults.standard.bool(forKey: "hideLiveTranscription")
                    // For batch engines (WhisperKit) or when hiding transcription, stay in peek mode
                    // Otherwise streaming engines expand to show live transcript
                    isOpen = isStreamingEngine && !hideLiveTranscription
                } else if mode == .transcribing || mode == .review || mode == .processing || mode == .response || mode == .error {
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
        @Published var accessibilityTrusted: Bool = PermissionMonitor.shared.accessibilityGranted
        @Published var audioLevel: Double = 0.0
        @Published var isHovering: Bool = false
        @Published var isOpen: Bool = false  // Now a stored property
        @Published var closedNotchSize: CGSize = getClosedNotchSize()

        // Startup glow animation (runs every app launch)
        var hasShownGreetingThisSession: Bool = false  // Session-based, not persisted
        @Published var glowAnimationRunning: Bool = false

        // Review glow animation (runs after recording stops)
        @Published var reviewGlowRunning: Bool = false

        // Expanded screenshot overlay
        @Published var showingExpandedScreenshot: Bool = false

        // Last session info (shown on idle hover)
        @Published var lastTranscript: String = ""
        @Published var lastAppName: String = ""
        @Published var lastScreenshot: ScreenshotCaptureResult?
        @Published var lastAIResponse: String?
        @Published var lastConversationTurns: [ConversationTurn] = []

        // Multi-turn conversation state
        @Published var conversationTurns: [ConversationTurn] = []

        var hasPhysicalNotch: Bool {
            guard let screen = NSScreen.main else { return false }
            return screen.safeAreaInsets.top > 0
        }

        /// Dynamic width for closed notch - expands for Now Playing wings (boring.notch pattern)
        var effectiveClosedWidth: CGFloat {
            let baseWidth = closedNotchSize.width
            // Expand for Now Playing album art wing when music is active
            if mode == .idleChip && NowPlayingService.shared.hasActivePlayer && NowPlayingService.shared.isEnabled {
                // Album art (28) + shadow (4 each side) + gap (4) = 40 per wing
                // Symmetric expansion for centered frame: 40 on each side = 80 total
                let wingSize: CGFloat = 40
                return baseWidth + (wingSize * 2)
            }
            return baseWidth
        }

        // Actions (wired by SessionController)
        var onSend: (() -> Void)?
        var onCopy: (() -> Void)?
        var onInsert: (() -> Void)?
        var onClose: (() -> Void)?
        var onExpandScreenshot: (() -> Void)?
        var onFollowUp: (() -> Void)?
        var onTextFollowUp: ((String) -> Void)?
        var onRemoveScreenshot: (() -> Void)?
        var onTranscriptEdit: ((String) -> Void)?
        var onStartDictation: (() -> Void)?  // Tap mic icon to start dictation

        // Chat input state (for live transcription in text field)
        @Published var followUpInputText: String = ""
        @Published var isRecordingFollowUp: Bool = false

        // Batch vs streaming engine state
        @Published var isStreamingEngine: Bool = true  // false for WhisperKit
        @Published var recordingStartTime: Date?
    }

    let model: Model

    /// The screen this panel is assigned to (nil = main screen)
    private(set) var assignedScreen: NSScreen?

    private var panel: GrabThisWindow?
    private var hostingController: NSHostingController<OverlayRootView>?
    private var expandedScreenshotPanel: NSPanel?
    private var autoDismissWork: DispatchWorkItem?
    private var hoverCancellable: AnyCancellable?
    private var escKeyMonitor: Any?
    private var permissionCancellable: AnyCancellable?

    var isOverlayKeyWindow: Bool { panel?.isKeyWindow ?? false }

    /// Create a panel controller for a specific screen with a shared model
    /// - Parameters:
    ///   - model: Shared model (all screens sync to same state)
    ///   - screen: The screen to show the panel on (nil = main screen)
    init(model: Model? = nil, screen: NSScreen? = nil) {
        self.model = model ?? Model()
        self.assignedScreen = screen

        // Subscribe to permission changes to keep accessibility status updated
        permissionCancellable = NotificationCenter.default.publisher(for: PermissionMonitor.accessibilityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let granted = notification.userInfo?["granted"] as? Bool {
                    self?.model.accessibilityTrusted = granted
                }
            }
    }

    func hide() {
        withAnimation(closeAnimation) {
            model.mode = .hidden
        }
        panel?.orderOut(nil)
    }

    func presentIdleChip() {
        // Startup glow animation: runs every app launch (while notch stays closed)
        if !model.hasShownGreetingThisSession && !model.glowAnimationRunning {
            model.glowAnimationRunning = true
            model.hasShownGreetingThisSession = true
            model.mode = .idleChip
            // Keep notch closed - glow traces the outside perimeter
            show()
            return  // Let animation handle the rest
        }

        // Save last session info before clearing (for idle hover display)
        if !model.transcript.isEmpty || !model.conversationTurns.isEmpty {
            model.lastTranscript = model.transcript
            model.lastAppName = model.appName
            model.lastScreenshot = model.screenshot
            model.lastAIResponse = model.responseText.isEmpty ? nil : model.responseText
            model.lastConversationTurns = model.conversationTurns
        }

        withAnimation(closeAnimation) {
            model.mode = .idleChip
        }
        model.transcript = ""
        model.screenshot = nil
        model.responseText = ""
        model.audioLevel = 0.0
        model.followUpInputText = ""
        model.isRecordingFollowUp = false
        model.conversationTurns = []
        // Set onClose to just retract the notch (not cancel a session)
        model.onClose = { [weak self] in
            withAnimation(closeAnimation) {
                self?.model.isOpen = false
            }
        }
        // Disable keyboard input when not in chat mode
        panel?.allowsKeyboardInput = false
        cancelAutoDismiss()
        show()
    }

    func presentListening(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String, isStreaming: Bool = true) {
        model.appName = appName
        model.screenshot = screenshot
        model.transcript = transcript
        // Set isStreamingEngine BEFORE mode change (didSet uses it to decide isOpen)
        model.isStreamingEngine = isStreaming
        model.recordingStartTime = Date()
        // Clear last session info when starting new session
        model.lastTranscript = ""
        model.lastAppName = ""
        model.lastScreenshot = nil
        model.lastConversationTurns = []
        model.lastAIResponse = nil
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
        // model.reviewGlowRunning = true  // Disabled for now - could use for AI loading
        withAnimation(openAnimation) {
            model.mode = .review
        }
        // Enable keyboard input for transcript editing
        panel?.allowsKeyboardInput = true
        show()
        scheduleAutoDismiss(seconds: 3.0)
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        model.accessibilityTrusted = trusted
    }

    func presentTranscribing() {
        cancelAutoDismiss()  // Don't auto-dismiss while transcribing
        withAnimation(openAnimation) {
            model.mode = .transcribing
        }
        show()
    }

    func presentProcessing() {
        cancelAutoDismiss()  // Don't auto-dismiss while AI is processing
        withAnimation(openAnimation) {
            model.mode = .processing
        }
        show()
    }

    func presentResponse(_ text: String) {
        model.responseText = text
        // Update close handler to just dismiss (session is complete, nothing to cancel)
        model.onClose = { [weak self] in
            self?.retractResponse()
        }
        withAnimation(openAnimation) {
            model.mode = .response
        }
        // Enable keyboard input for chat text field
        panel?.allowsKeyboardInput = true
        show()
        // Auto-dismiss (retract) after 3s - hover will bring it back with full chat
        scheduleResponseRetract(seconds: 3.0)
    }

    /// Retract response mode (close visually but keep conversation state for hover)
    func retractResponse() {
        withAnimation(closeAnimation) {
            model.isOpen = false
        }
        // Keep mode as .response so hover shows chat, just disable keyboard while retracted
        panel?.allowsKeyboardInput = false
    }

    func presentError(_ message: String) {
        model.responseText = message
        // Update close handler to just dismiss (nothing to cancel on error)
        model.onClose = { [weak self] in
            withAnimation(closeAnimation) {
                self?.model.isOpen = false
            }
        }
        withAnimation(openAnimation) {
            model.mode = .error
        }
        show()
        scheduleAutoDismiss(seconds: 3.0)
    }

    func showExpandedScreenshot() {
        // Check both current screenshot and last screenshot (for idle/history mode)
        let image = model.screenshot?.image ?? model.lastScreenshot?.image
        guard let image, let screen = assignedScreen ?? NSScreen.main else { return }

        // Cancel auto-dismiss timer while viewing expanded screenshot
        cancelAutoDismiss()

        // Dismiss the existing expanded panel if any
        dismissExpandedScreenshot()

        // Create the expanded screenshot view
        let expandedView = ExpandedScreenshotView(
            image: image,
            onDismiss: { [weak self] in
                self?.dismissExpandedScreenshot()
            }
        )
        let hosting = NSHostingController(rootView: expandedView)

        // Create fullscreen panel
        let screenFrame = screen.frame
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting.view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .mainMenu + 10  // Above everything
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()

        expandedScreenshotPanel = panel
        model.showingExpandedScreenshot = true

        // Add ESC key monitor to dismiss expanded screenshot
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // ESC key
                self?.dismissExpandedScreenshot()
                return nil  // Consume the event
            }
            return event
        }
    }

    func dismissExpandedScreenshot() {
        // Remove ESC key monitor
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }

        expandedScreenshotPanel?.orderOut(nil)
        expandedScreenshotPanel = nil
        model.showingExpandedScreenshot = false

        // Re-schedule auto-dismiss for review/error modes (not response - stays visible)
        if model.mode == .review || model.mode == .error {
            scheduleAutoDismiss(seconds: 3.0)
        }
    }
}

extension OverlayPanelController {
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

            // Cancel auto-dismiss while hovering, re-enable keyboard for editable modes
            hoverCancellable = model.$isHovering.sink { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.cancelAutoDismiss()
                    // Re-enable keyboard when hovering expands response or review mode
                    if self.model.mode == .response || self.model.mode == .review {
                        self.panel?.allowsKeyboardInput = true
                    }
                } else if self.model.mode == .review || self.model.mode == .error {
                    self.scheduleAutoDismiss(seconds: 3.0)
                } else if self.model.mode == .response {
                    // Response mode: retract (but keep state) when hover ends
                    self.scheduleResponseRetract(seconds: 2.0)
                }
            }
        }

        // Update closed notch size for assigned screen
        if let screen = assignedScreen ?? NSScreen.main {
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
        // Use assigned screen, fallback to main, then first available
        guard let screen = assignedScreen ?? NSScreen.main ?? NSScreen.screens.first,
              let p = panel else { return }

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
                // Always go to idleChip after timeout
                // Transcript is saved to history, user can access via Home tab
                // This allows Now Playing wings to show after dictation
                self.presentIdleChip()
            }
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Retract review mode (close visually but keep transcript for hover to restore)
    func retractReview() {
        withAnimation(closeAnimation) {
            model.isOpen = false
        }
        // Keep mode as .review so hover shows editable transcript
        panel?.allowsKeyboardInput = false
    }

    /// Auto-retract for response mode (keeps conversation state, hover brings it back)
    func scheduleResponseRetract(seconds: TimeInterval) {
        cancelAutoDismiss()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only retract if still in response mode and not hovering
                guard self.model.mode == .response, !self.model.isHovering else { return }
                self.retractResponse()
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
    @ObservedObject var nowPlaying = NowPlayingService.shared
    @ObservedObject var coordinator = NotchCoordinator.shared
    @State private var hoverTask: Task<Void, Never>?

    // Temporary peek state (boring.notch style - shows briefly then hides)
    @State private var showPeek: Bool = true
    @State private var peekTask: Task<Void, Never>?
    @State private var showInitialHint: Bool = true  // Show "Hold fn to talk" first on app start
    @State private var lastTrackTitle: String = ""

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
                    // v11 fix: No extra top padding (header is the spacer)
                    // Horizontal padding must be > corner radius to avoid clipping pulsing status dot
                    .padding(.horizontal, model.isOpen ? cornerRadiusInsets.opened.top + 8 : 0)
                    .padding(.bottom, model.isOpen ? 12 : 0)
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
                    .overlay(alignment: .top) {
                        // Startup glow: rainbow trace around the closed notch perimeter
                        if model.glowAnimationRunning {
                            NotchGlowAnimation(
                                topCornerRadius: cornerRadiusInsets.closed.top,
                                bottomCornerRadius: cornerRadiusInsets.closed.bottom,
                                onFinish: {
                                    model.glowAnimationRunning = false
                                }
                            )
                            .frame(width: model.closedNotchSize.width, height: model.closedNotchSize.height)
                        }
                    }
                    .overlay {
                        // Review glow: rainbow trace around expanded notch after recording
                        if model.reviewGlowRunning {
                            NotchGlowAnimation(
                                topCornerRadius: cornerRadiusInsets.opened.top,
                                bottomCornerRadius: cornerRadiusInsets.opened.bottom,
                                duration: 1.5,  // Faster for expanded window
                                lineWidth: 4,
                                blurRadius: 6.0,
                                onFinish: {
                                    model.reviewGlowRunning = false
                                    // Auto-dismiss to idle after glow completes
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        withAnimation(closeAnimation) {
                                            model.mode = .idleChip
                                            model.isOpen = false
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .shadow(color: (model.isOpen || model.isHovering) ? .black.opacity(0.7) : .clear, radius: 6)
                    // Use explicit closed height instead of nil - nil might not animate properly
                    // Use taller height for chat mode (response/error)
                    // v10 fix: Add alignment: .top to anchor content regardless of intrinsic height
                    // Without this, shorter content (listening mode) gets centered, pushing it down
                    .frame(height: model.isOpen
                        ? (model.mode == .response || model.mode == .error ? chatNotchSize.height : openNotchSize.height)
                        : model.closedNotchSize.height,
                        alignment: .top)
                    // Animate for BOTH mode changes AND direct isOpen changes (hover)
                    // boring.notch uses notchState for mode-triggered animations
                    .animation(model.isOpen ? openAnimation : closeAnimation, value: model.mode)
                    .animation(model.isOpen ? openAnimation : closeAnimation, value: model.isOpen)
                    // Use background instead of contentShape for hover - contentShape blocks child button clicks
                    .background(Color.black.opacity(0.001))
                    .onHover { hovering in
                        handleHover(hovering)
                    }
            }
        }
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        // Notify coordinator of hover state change (handles auto-switch to Now Playing)
        coordinator.onHover(hovering)

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
            // Longer delay (300ms) to prevent accidental close when moving between elements
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
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

    // MARK: - Content Views (boring.notch pattern: header always present + body inserted)

    @ViewBuilder
    private var notchContent: some View {
        // boring.notch pattern: header is ALWAYS present, body is ADDED when open
        // This ensures transitions fire correctly on every open/close cycle
        VStack(alignment: .center, spacing: 0) {
            // HEADER - always present, content varies by state
            headerContent
                .zIndex(2)

            // UNDER-NOTCH PEEK - shows track name or hint briefly when closed (boring.notch style)
            // Show on: initial hint OR coordinator.showSneakPeek (song change)
            if !model.isOpen && model.mode == .idleChip && (showPeek || coordinator.showSneakPeek) {
                underNotchPeek
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
                    .onAppear {
                        schedulePeekHide()
                    }
            }

            // BODY - only when open, this gets the transition
            if model.isOpen {
                bodyContent
                    .transition(
                        .scale(scale: 0.8, anchor: .top)
                        .combined(with: .opacity)
                        .animation(.smooth(duration: 0.35))
                    )
                    .zIndex(1)
            }
        }
    }

    /// Schedule the peek to hide after a delay (boring.notch behavior)
    private func schedulePeekHide() {
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showPeek = false
                    // Also clear coordinator's sneak peek flag to fully dismiss
                    coordinator.showSneakPeek = false
                }
                // After initial hint hides, future shows will display track name
                if showInitialHint {
                    showInitialHint = false
                }
            }
        }
    }

    /// Under-notch peek text (boring.notch style) - shows "Hold fn to talk" first, then track name on song change
    @ViewBuilder
    private var underNotchPeek: some View {
        let peekText: String = {
            // On song change (sneak peek), always show track info
            if coordinator.showSneakPeek && nowPlaying.hasActivePlayer && !nowPlaying.title.isEmpty {
                let artistText = nowPlaying.artist.isEmpty ? "" : " – \(nowPlaying.artist)"
                return "\(nowPlaying.title)\(artistText)"
            }
            // Initial hint on app start
            if showInitialHint {
                return "Hold fn to talk"
            }
            // After initial hint dismissed, show track name if music playing
            if nowPlaying.isEnabled && nowPlaying.hasActivePlayer && !nowPlaying.title.isEmpty {
                return nowPlaying.title
            }
            // Fallback
            return "Hold fn to talk"
        }()

        Text(peekText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black)
            )
            .padding(.top, 4)
    }

    @ViewBuilder
    private var headerContent: some View {
        // Header row - always present at notch height, content changes based on state
        switch model.mode {
        case .hidden:
            EmptyView()
        case .idleChip:
            // Show Now Playing peek-through if music is active and enabled, otherwise normal header
            // Use Group + transition to smooth the switch between Now Playing and normal header
            Group {
                if nowPlaying.isEnabled && nowPlaying.hasActivePlayer && !model.isOpen {
                    // Show Now Playing wings with iOS 26 morph (album art → mic when dictating)
                    NowPlayingCompactView(
                        service: nowPlaying,
                        notchWidth: model.closedNotchSize.width,
                        isDictating: model.mode == .listening
                    )
                    .frame(width: model.effectiveClosedWidth, height: model.closedNotchSize.height)
                    .allowsHitTesting(true)  // Ensure controls receive touch events
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                } else {
                    NotchHeader(
                        model: model,
                        statusColor: .cyan,
                        statusText: "Hold fn to talk",
                        showPulse: false,
                        showCloseButton: model.isOpen,
                        rightContent: {
                            // Show mini visualizer if music is playing and enabled
                            if nowPlaying.isEnabled && nowPlaying.hasActivePlayer {
                                AudioSpectrumView(isPlaying: nowPlaying.isPlaying)  // Fixed: was .constant()
                                    .frame(width: 16, height: 14)
                            }
                        }
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
        case .listening:
            // Always show split content on notch Macs - no expansion on hover during recording
            // This prevents the confusing "expanded listening" state
            if model.hasPhysicalNotch {
                ListeningSplitContent(model: model)
            } else {
                // Non-notch Macs: simple header
                NotchHeader(
                    model: model,
                    statusColor: .cyan,
                    statusText: "Listening...",
                    showPulse: true,
                    showCloseButton: false,
                    rightContent: { EmptyView() }
                )
            }
        case .transcribing:
            NotchHeader(
                model: model,
                statusColor: .cyan,
                statusText: "Transcribing...",
                showPulse: true,
                showCloseButton: false,
                rightContent: {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            )
        case .review:
            NotchHeader(
                model: model,
                statusColor: .green,
                statusText: "Done. Press fn to talk again",
                showPulse: false,
                showCloseButton: true,
                rightContent: { EmptyView() }
            )
        case .processing:
            NotchHeader(
                model: model,
                statusColor: .orange,
                statusText: "Processing...",
                showPulse: true,
                showCloseButton: false,
                rightContent: {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            )
        case .response:
            NotchHeader(
                model: model,
                statusColor: .green,
                statusText: "Done",
                showPulse: false,
                showCloseButton: true,
                rightContent: { EmptyView() }
            )
        case .error:
            NotchHeader(
                model: model,
                statusColor: .red,
                statusText: "Error",
                showPulse: false,
                showCloseButton: true,
                rightContent: { EmptyView() }
            )
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        // Body content - only shown when open
        switch model.mode {
        case .hidden:
            EmptyView()
        case .idleChip:
            IdleBodyContent(model: model)
        case .listening, .review:
            ActiveSessionBodyContent(model: model)
        case .transcribing:
            TranscribingBodyContent(model: model)
        case .processing:
            ProcessingBodyContent()
        case .response:
            ChatResponseView(model: model)  // Chat UI with text input + mic
        case .error:
            ResponseBodyContent(model: model, isError: true)
        }
    }
}

// MARK: - Unified Header Component (always present)

private struct NotchHeader<RightContent: View>: View {
    @ObservedObject var model: OverlayPanelController.Model
    let statusColor: Color
    let statusText: String
    let showPulse: Bool
    let showCloseButton: Bool
    @ViewBuilder let rightContent: () -> RightContent

    @State private var pulse = false

    var body: some View {
        HStack(spacing: model.isOpen ? 10 : 8) {
            // Status indicator
            Circle()
                .fill(statusColor.opacity(0.95))
                .frame(width: model.isOpen ? 10 : 6, height: model.isOpen ? 10 : 6)
                .scaleEffect(showPulse && pulse ? 1.4 : 1.0)
                .opacity(showPulse && pulse ? 0.6 : 1.0)
                .onAppear {
                    if showPulse {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                }

            // Status text
            Text(statusText)
                .font(model.isOpen ? .headline : .caption.weight(.semibold))
                .foregroundStyle(.white.opacity(model.isOpen ? 1.0 : 0.92))
                .contentTransition(.interpolate)

            Spacer()

            // Right content (visualizer, progress, etc.)
            rightContent()

            // Close button (only when open and requested)
            if showCloseButton && model.isOpen {
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: model.isOpen ? max(24, model.closedNotchSize.height) : model.closedNotchSize.height)
        .frame(maxWidth: model.isOpen ? .infinity : model.effectiveClosedWidth - 20)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isOpen)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: statusColor)
    }
}

// MARK: - Tab Bar (boring.notch style - only shown in open notch header)

private struct NotchTabBar: View {
    @Binding var currentPage: NotchPage
    @ObservedObject var nowPlaying = NowPlayingService.shared
    @Namespace private var tabAnimation

    private var availablePages: [NotchPage] {
        var pages: [NotchPage] = [.transcription]  // Dictation tab always available
        if nowPlaying.hasActivePlayer && nowPlaying.isEnabled {
            pages.append(.nowPlaying)
        }
        return pages
    }

    var body: some View {
        // Centered segmented control style (iOS standard pattern)
        HStack(spacing: 2) {
            ForEach(availablePages, id: \.self) { page in
                NotchTabButton(
                    page: page,
                    isSelected: currentPage == page,
                    namespace: tabAnimation
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        currentPage = page
                    }
                }
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
        .frame(maxWidth: .infinity, alignment: .center)  // Center under notch
    }
}

private struct NotchTabButton: View {
    let page: NotchPage
    let isSelected: Bool
    var namespace: Namespace.ID

    // Short labels for tabs
    private var label: String {
        switch page {
        case .transcription: return "Voice AI"
        case .nowPlaying: return "Now Playing"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: page.icon)
                .font(.system(size: 11, weight: .medium))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .matchedGeometryEffect(id: "tabBackground", in: namespace)
            }
        }
        .contentShape(Capsule())
    }
}

// MARK: - Body Content Views (only shown when open)

/// Shared component for transcript display with thumbnail and action buttons.
/// Used by both idle hover (showing last session) and active review mode.
private struct TranscriptActionsBody: View {
    @Binding var transcript: String
    let placeholderText: String
    let screenshot: CGImage?
    let showButtons: Bool
    let isEditable: Bool
    let onExpandScreenshot: (() -> Void)?
    let onRemoveScreenshot: (() -> Void)?
    let onInsert: (() -> Void)?
    let onCopy: (() -> Void)?
    let onSend: (() -> Void)?
    var onHover: ((Bool) -> Void)? = nil
    var aiResponse: String? = nil  // Optional AI response for idle hover

    var body: some View {
        VStack(spacing: 12) {
            // Top section: Transcript + thumbnail side by side
            // Fixed height (100pt = screenshot height) ensures consistent layout across modes
            HStack(alignment: .top, spacing: 12) {
                // Left: Transcript (editable in review mode)
                VStack(alignment: .leading, spacing: 8) {
                    if isEditable {
                        // Review mode: Editable TextEditor
                        TextEditor(text: $transcript)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .scrollContentBackground(.hidden)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(minHeight: 70, maxHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                    } else {
                        // Listening mode: Auto-scroll to follow live transcription
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    Text(transcript.isEmpty ? placeholderText : transcript)
                                        .font(.body)
                                        .foregroundStyle(.white.opacity(transcript.isEmpty ? 0.5 : 0.9))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                    Color.clear.frame(height: 1).id("transcriptBottom")
                                }
                            }
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(minHeight: 70, maxHeight: 120)
                            .onChange(of: transcript) { _, _ in
                                proxy.scrollTo("transcriptBottom", anchor: .bottom)
                            }
                        }
                    }

                    // Show AI response if available (for idle hover)
                    if let response = aiResponse, !response.isEmpty {
                        Text(response)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // Right: Screenshot thumbnail
                if screenshot != nil {
                    Button(action: { onExpandScreenshot?() }) {
                        ReviewThumbnail(image: screenshot, onRemove: onRemoveScreenshot)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(height: 120)  // Fixed height ensures consistent layout in all modes

            // Always use spacer to push content to top
            Spacer()

            // Bottom section: Action buttons
            if showButtons {
                HStack(spacing: 12) {
                    Button(action: { onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.8))

                    Spacer()

                    // Send to AI - ChatGPT style (larger)
                    HStack(spacing: 10) {
                        Text("Ask AI")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))

                        Button(action: { onSend?() }) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(
                                    LinearGradient(
                                        colors: [Color.cyan, Color(red: 0.3, green: 0.5, blue: 1.0)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Circle())
                                .shadow(color: .cyan.opacity(0.5), radius: 6, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)  // Keep content top-aligned always
        .padding(.horizontal, 16)
        .padding(.top, 4)  // v11: Tighter spacing like boring.notch
        .padding(.bottom, 12)
        .onHover { hovering in onHover?(hovering) }
    }
}

private struct IdleBodyContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @ObservedObject var nowPlaying = NowPlayingService.shared
    @ObservedObject var coordinator = NotchCoordinator.shared

    private var hasLastSession: Bool { !model.lastTranscript.isEmpty }
    private var hasMusic: Bool { nowPlaying.isEnabled && nowPlaying.hasActivePlayer }

    var body: some View {
        VStack(spacing: 8) {
            // Tab bar only when music is available (switch between dictation and now playing)
            if hasMusic {
                NotchTabBar(currentPage: $coordinator.currentPage)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            // Content based on selected page
            switch coordinator.currentPage {
            case .nowPlaying where hasMusic:
                // Now Playing expanded view
                NowPlayingExpandedView(service: nowPlaying) { hovering in
                    if hovering {
                        model.isHovering = true
                    }
                }
                .allowsHitTesting(true)

            default:
                // Dictation tab: show history if available, otherwise "Hold fn to talk"
                TranscriptActionsBody(
                    transcript: .constant(model.lastTranscript),
                    placeholderText: "Hold fn to start talking",
                    screenshot: model.lastScreenshot?.image,
                    showButtons: hasLastSession,
                    isEditable: false,
                    onExpandScreenshot: model.onExpandScreenshot,
                    onRemoveScreenshot: nil,
                    onInsert: model.onInsert,
                    onCopy: model.onCopy,
                    onSend: model.onSend,
                    onHover: { model.isHovering = $0 },
                    aiResponse: model.lastAIResponse
                )
            }
        }
    }
}

private struct ActiveSessionBodyContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @AppStorage("hideLiveTranscription") private var hideLiveTranscription = false

    private var isListening: Bool { model.mode == .listening }
    private var isReady: Bool { model.mode == .review }

    var body: some View {
        VStack(spacing: 12) {
            // Show audio level visualizer when listening
            if isListening {
                HStack(spacing: 12) {
                    PillVisualizer(level: model.audioLevel)
                    Text(hideLiveTranscription ? "Recording..." : "Speak now...")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // Hide transcript during listening if user enabled "Hide live transcription"
            // Still show in review mode so they can see/edit the result
            if !(hideLiveTranscription && isListening) {
                TranscriptActionsBody(
                    transcript: Binding(
                        get: { model.transcript },
                        set: { newValue in
                            model.transcript = newValue
                            model.onTranscriptEdit?(newValue)
                        }
                    ),
                    placeholderText: isListening ? "" : "No transcript",  // Empty placeholder since we show visualizer above
                    screenshot: isReady ? model.screenshot?.image : nil,
                    showButtons: isReady,
                    isEditable: isReady,  // Editable only in review mode
                    onExpandScreenshot: model.onExpandScreenshot,
                    onRemoveScreenshot: model.onRemoveScreenshot,
                    onInsert: model.onInsert,
                    onCopy: model.onCopy,
                    onSend: model.onSend,
                    onHover: { model.isHovering = $0 }
                )
            } else {
                // Spacer to maintain layout when transcript is hidden
                Spacer()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.mode)
    }
}

/// Body content shown during WhisperKit batch transcription (after recording, before results)
private struct TranscribingBodyContent: View {
    @ObservedObject var model: OverlayPanelController.Model

    var body: some View {
        VStack(spacing: 12) {
            // Simple status message - no screenshot (it's confusing here)
            HStack(spacing: 8) {
                Text("Converting speech to text")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct ProcessingBodyContent: View {
    private static let funMessages = [
        "Summoning the AI spirits...",
        "Consulting the digital oracle...",
        "Crunching pixels...",
        "Teaching robots to see...",
        "Spinning up neural hamsters...",
        "Asking the cloud nicely...",
        "Decoding your brilliance...",
        "Waking up the AI...",
        "Processing at light speed...",
        "Reading the screen tea leaves...",
        "Thinking really hard...",
        "Analyzing with gusto...",
    ]

    @State private var message = funMessages.randomElement() ?? "Processing..."

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct ResponseBodyContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    let isError: Bool

    private var hasMultipleTurns: Bool { model.conversationTurns.count > 1 }

    var body: some View {
        VStack(spacing: 8) {
            // Always show conversation turns if available (including in error mode)
            if !model.conversationTurns.isEmpty {
                ConversationView(
                    turns: model.conversationTurns,
                    compact: true,
                    maxHeight: isError ? 80 : 120
                )

                // Show error message below conversation if in error mode
                if isError {
                    Text(model.responseText)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            } else {
                // Fallback for empty conversation
                Text(model.responseText)
                    .font(.body)
                    .foregroundStyle(isError ? .red.opacity(0.9) : .white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4)
            }

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

                // Follow-up button (only for non-error responses)
                if !isError {
                    Button(action: { model.onFollowUp?() }) {
                        Label("Follow up", systemImage: "text.bubble")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onHover { model.isHovering = $0 }
    }
}

/// Chat-style response view with scrollable conversation and input field
private struct ChatResponseView: View {
    @ObservedObject var model: OverlayPanelController.Model
    @FocusState private var isInputFocused: Bool

    private var hasTextInput: Bool {
        !model.followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable chat bubbles (takes all available space)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // Screenshot - right aligned above first user message
                        if let image = model.screenshot?.image {
                            HStack {
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("Screenshot")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                    Button(action: { model.onExpandScreenshot?() }) {
                                        Image(decorative: image, scale: 1.0)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 4)
                        }

                        // Conversation turns
                        ForEach(Array(model.conversationTurns.enumerated()), id: \.offset) { idx, turn in
                            ChatBubbleView(role: turn.role, content: turn.content, timestamp: nil, compact: true)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.conversationTurns.count) { _, _ in
                    if let last = model.conversationTurns.indices.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.2))

            // Input area with text field + send/mic buttons
            HStack(spacing: 10) {
                TextField("Ask a follow-up...", text: $model.followUpInputText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($isInputFocused)
                    .onSubmit { sendTextFollowUp() }

                // Send button (shows when text field has content)
                if hasTextInput {
                    Button(action: { sendTextFollowUp() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Send message")
                    .transition(.scale.combined(with: .opacity))
                }

                // Mic button (hold or tap to record)
                Button(action: { model.onFollowUp?() }) {
                    Image(systemName: model.isRecordingFollowUp ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(model.isRecordingFollowUp ? .red : .cyan)
                        .frame(width: 36, height: 36)
                        .background(model.isRecordingFollowUp ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Tap or hold fn to speak")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .animation(.easeOut(duration: 0.15), value: hasTextInput)
        }
        .onHover { model.isHovering = $0 }
    }

    private func sendTextFollowUp() {
        let text = model.followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.onTextFollowUp?(text)
        model.followUpInputText = ""
    }
}

// MARK: - Split Content for MacBook with Notch

private struct ListeningSplitContent: View {
    @ObservedObject var model: OverlayPanelController.Model
    @State private var pulse = false
    @State private var elapsedTime: TimeInterval = 0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: Pulsing dot + "Listening" + timer (content-hugging)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.cyan.opacity(0.95))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .opacity(pulse ? 0.6 : 1.0)
                Text("Listening")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text(formatTime(elapsedTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.leading, 6)  // Prevent left dot from being cut off
            .padding(.trailing, 4)

            // CENTER: The notch gap - exact notch width
            Rectangle()
                .fill(.black)
                .frame(width: model.closedNotchSize.width)

            // RIGHT: Waveform visualizer (content-hugging)
            CompactWaveformView(audioLevel: model.audioLevel)
                .padding(.leading, 4)
                .padding(.trailing, 6)  // Balance with left padding
        }
        .frame(height: model.closedNotchSize.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onReceive(timer) { _ in
            if let start = model.recordingStartTime {
                elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Supporting Views

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

// Larger thumbnail for review panel (right side)
private struct ReviewThumbnail: View {
    let image: CGImage?
    var onRemove: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(width: 80, height: 100)

            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        // Expand icon hint
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(4),
                        alignment: .bottomTrailing
                    )
                    .overlay(alignment: .topTrailing) {
                        // X button to remove screenshot
                        if onRemove != nil {
                            Button(action: { onRemove?() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Chat UI Components

/// Animated typing indicator (iMessage-style bouncing dots)
private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .offset(y: animating ? -6 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

/// Helper view for rendering markdown text with clickable links
private struct MarkdownText: View {
    let content: String
    var font: Font = .body
    var color: Color = .white.opacity(0.95)
    var linkColor: Color = .cyan

    var body: some View {
        Text(attributedContent)
            .font(font)
            .tint(linkColor)  // Makes links this color and clickable
    }

    private var attributedContent: AttributedString {
        let processed = preprocessMarkdown(content)
        var result = (try? AttributedString(markdown: processed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)

        // Apply base color to all text, but links will use tint color
        for run in result.runs {
            // Only apply foreground color to non-link runs
            if run.link == nil {
                let range = run.range
                result[range].foregroundColor = color
            }
        }

        return result
    }

    /// Convert block-level markdown (headers, lists) to inline formatting that SwiftUI Text can render
    private func preprocessMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        for i in lines.indices {
            var line = lines[i]

            // Convert headers to bold: ### Header → **Header**
            if line.hasPrefix("### ") {
                line = "**" + line.dropFirst(4) + "**"
            } else if line.hasPrefix("## ") {
                line = "**" + line.dropFirst(3) + "**"
            } else if line.hasPrefix("# ") {
                line = "**" + line.dropFirst(2) + "**"
            }

            // Convert unordered list items: - item → • item
            if line.hasPrefix("- ") {
                line = "• " + line.dropFirst(2)
            } else if line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }

            // Convert numbered lists: 1. item → 1. item (keep as-is, they render fine)

            lines[i] = line
        }

        return lines.joined(separator: "\n")
    }
}

/// Individual message bubble for conversation display
struct ChatBubbleView: View {
    let role: ConversationTurn.Role
    let content: String
    let timestamp: Date?
    var compact: Bool = false  // For inline display in response mode

    private var isUser: Bool { role == .user }
    private var isTypingPlaceholder: Bool { content == "..." && !isUser }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: compact ? 20 : 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if isTypingPlaceholder {
                        // Animated typing indicator
                        TypingIndicator()
                            .frame(height: compact ? 20 : 24)
                    } else {
                        MarkdownText(content: content, font: compact ? .callout : .body)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isUser ? Color.cyan.opacity(0.3) : Color.white.opacity(0.1))
                )
                .textSelection(.enabled)

                if let timestamp, !compact {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            if !isUser { Spacer(minLength: compact ? 20 : 40) }
        }
    }
}

/// Scrollable conversation view for multi-turn display
struct ConversationView: View {
    let turns: [ConversationTurn]
    var compact: Bool = false  // For inline display in response mode
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        ChatBubbleView(
                            role: turn.role,
                            content: turn.content,
                            timestamp: compact ? nil : turn.timestamp,
                            compact: compact
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, compact ? 0 : 4)
                .padding(.vertical, compact ? 4 : 8)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: turns.count) { _, _ in
                // Auto-scroll to latest message
                if let lastIndex = turns.indices.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// Full-screen expanded screenshot view (shown in separate panel)
struct ExpandedScreenshotView: View {
    let image: CGImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Semi-transparent backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            // Screenshot image
            VStack(spacing: 16) {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20)
                    .padding(40)

                // Close hint
                Text("Click anywhere or press ESC to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Close button (top-right)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(24)
        }
        .contentShape(Rectangle())  // Make entire area tappable
        .onTapGesture {
            onDismiss()
        }
    }
}
