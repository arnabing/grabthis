import AppKit
import Foundation
import Combine

@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case review
        case processing
        case response
        case error(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var screenshot: ScreenshotCaptureResult?
    @Published var transcriptDraft: String = ""
    @Published private(set) var appContext: ActiveAppContext?

    private let overlay: OverlayPanelController
    private let transcription: TranscriptionService
    private let aiService = AIService()
    private let history = SessionHistoryStore.shared
    private var transcriptionTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var targetPIDForInsert: pid_t?
    private var listeningStartedAt: Date?
    private var currentSessionId: UUID?
    private var sessionStartedAt: Date?
    private var didSaveCurrentSession: Bool = false

    /// Local tracking of conversation turns for multi-turn context
    private var conversationTurns: [ConversationTurn] = []
    /// Whether we're in a follow-up flow (continue existing session instead of starting new)
    private var isFollowUp: Bool = false

    init(overlay: OverlayPanelController) {
        self.overlay = overlay
        self.transcription = TranscriptionService()
        self.overlay.presentIdleChip()

        // Listen for "continue session" requests from History
        NotificationCenter.default.addObserver(
            forName: .continueSession,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let record = notification.object as? SessionRecord else { return }
            Task { @MainActor in
                self?.continueSession(from: record)
            }
        }
    }

    func begin() {
        // If in response mode AND notch is expanded, start voice follow-up
        // If notch is retracted (closed), start a new session instead
        if phase == .response && currentSessionId != nil && overlay.model.isOpen {
            beginFollowUp()
            return
        }

        // If user starts a new thought while a previous session is still on-screen,
        // archive the old one and start immediately (Wispr-like).
        if phase != .idle {
            archiveCurrent(endReason: .interrupted)
            resetToIdle()
        }
        Log.session.info("begin()")
        listeningStartedAt = Date()
        sessionStartedAt = Date()
        currentSessionId = UUID()
        didSaveCurrentSession = false
        conversationTurns = []  // Clear for new conversation
        isFollowUp = false
        overlay.model.conversationTurns = []

        // Prevent the “Screen Recording” system dialog from spamming by never attempting capture
        // unless the user has granted permission in System Settings.
        guard PermissionsService.hasScreenRecordingPermission() else {
            phase = .error(message: "Screen Recording permission is required.")
            overlay.presentError("Enable Screen Recording in System Settings → Privacy & Security → Screen Recording, then quit & relaunch grabthis.")
            Log.capture.error("screen recording permission missing; blocked capture")
            return
        }

        appContext = ActiveAppContextProvider.current()
        targetPIDForInsert = appContext?.pid
        screenshot = nil
        transcriptDraft = ""
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil

        overlay.presentListening(
            appName: appContext?.appName ?? "Unknown",
            screenshot: nil,
            transcript: ""
        )
        phase = .listening

        Task { @MainActor in
            do {
                // Use the PID we captured BEFORE showing overlay to avoid race conditions
                guard let targetPID = self.targetPIDForInsert else {
                    throw CaptureService.CaptureError.noFrontmostApp
                }
                let shot = try await CaptureService.captureWindow(forPID: targetPID)
                self.screenshot = shot
                self.overlay.updateListening(screenshot: shot)
                Log.capture.info("captured window for PID \(targetPID) \(shot.pixelWidth)x\(shot.pixelHeight) scale=\(shot.scale, privacy: .public)")
            } catch {
                self.phase = .error(message: "Screenshot failed: \(error.localizedDescription)")
                self.overlay.presentError("Screenshot failed")
                Log.capture.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Start transcription after the overlay is already visible; this yields back to the run loop,
        // reducing the "fn → listening" perceived latency.
        Task { @MainActor in
            do {
                try await self.transcription.start()
                FeedbackSoundService.playStart()
                if let listeningStartedAt {
                    let ms = Int(Date().timeIntervalSince(listeningStartedAt) * 1000.0)
                    Log.stt.info("listening cue played latencyMs=\(ms, privacy: .public)")
                }
            } catch {
                self.phase = .error(message: "Transcription failed: \(error.localizedDescription)")
                self.overlay.presentError("Transcription failed")
                Log.stt.error("transcription start threw: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Stream partial updates into overlay (real time).
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await text in self.transcription.$partialText.values {
                guard self.phase == .listening else { break }
                self.overlay.updateListening(transcript: text)
            }
        }

        // Stream mic level updates into overlay.
        levelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await lvl in AudioLevelService.shared.$level.values {
                guard self.phase == .listening else { break }
                self.overlay.model.audioLevel = lvl
            }
        }
    }

    func end() {
        guard phase == .listening else { return }

        // If in follow-up mode, delegate to endFollowUp
        if isFollowUp {
            endFollowUp()
            return
        }

        Log.session.info("end()")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil
        Task { @MainActor in
            await self.transcription.stopAndFinalize()
            self.transcriptDraft = self.transcription.finalText.isEmpty ? self.transcription.partialText : self.transcription.finalText
            // FIX: Update overlay transcript IMMEDIATELY to prevent blank state during auto-insert delay
            self.overlay.updateListening(transcript: self.transcriptDraft)
            self.overlay.setAccessibilityTrusted(AutoInsertService.isAccessibilityTrusted())
            self.overlay.model.audioLevel = 0.0

            if !self.transcriptDraft.isEmpty {
                // Don't hide overlay - let it transition smoothly from listening → review
                // The presentReview() call below will update the mode with animation

                let targetPID = self.targetPIDForInsert
                let targetAppName = self.appContext?.appName ?? "Unknown"
                let frontmostBefore = NSWorkspace.shared.frontmostApplication
                Log.autoInsert.info("start target=\(targetAppName, privacy: .public) pid=\(targetPID ?? -1, privacy: .public) frontmostBefore=\(frontmostBefore?.localizedName ?? "nil", privacy: .public) bundle=\(frontmostBefore?.bundleIdentifier ?? "nil", privacy: .public) overlayKey=\(self.overlay.isOverlayKeyWindow, privacy: .public)")

                // Wispr-like smoothness: avoid activation churn if we're already in the target app.
                let frontmostPid = frontmostBefore?.processIdentifier
                if let targetPID,
                   frontmostPid != targetPID,
                   let app = NSRunningApplication(processIdentifier: targetPID) {
                    let ok = app.activate(options: [.activateAllWindows])
                    Log.autoInsert.info("activate targetPid=\(targetPID, privacy: .public) ok=\(ok, privacy: .public) isActive=\(app.isActive, privacy: .public)")
                } else {
                    Log.autoInsert.info("skip activation (already frontmost)")
                }

                // Let focus settle (especially for Electron apps like Cursor).
                // If we didn't activate, this should be fast; if we activated, allow more time.
                let settleBudget: TimeInterval = (frontmostPid == targetPID) ? 0.35 : 1.10
                let settleDeadline = Date().addingTimeInterval(settleBudget)
                while Date() < settleDeadline {
                    if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                        // Also wait for a focused element to exist (Cursor can be "frontmost" before editor focus is ready).
                        if AutoInsertService.isAccessibilityTrusted() {
                            var focusedObj: CFTypeRef?
                            let sys = AXUIElementCreateSystemWide()
                            let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedObj)
                            if err == .success, focusedObj != nil {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    try? await Task.sleep(nanoseconds: 45_000_000)
                }

                let frontmostAtPaste = NSWorkspace.shared.frontmostApplication
                let axTrusted = AutoInsertService.isAccessibilityTrusted()
                self.overlay.setAccessibilityTrusted(axTrusted)
                Log.autoInsert.info("paste frontmostAtPaste=\(frontmostAtPaste?.localizedName ?? "nil", privacy: .public) pid=\(frontmostAtPaste?.processIdentifier ?? -1, privacy: .public) bundle=\(frontmostAtPaste?.bundleIdentifier ?? "nil", privacy: .public) axTrusted=\(axTrusted, privacy: .public)")

                if axTrusted {
                    let result = AutoInsertService.autoInsert(self.transcriptDraft, targetPID: targetPID)
                    Log.autoInsert.info("autoInsert result success=\(result.success, privacy: .public) strategy=\(result.strategy?.rawValue ?? "nil", privacy: .public) details=\(result.details, privacy: .public)")
                } else {
                    // Copy only (so manual ⌘V works) and prompt for Accessibility.
                    AutoInsertService.copyToClipboardKeeping(_text: self.transcriptDraft)
                    AutoInsertService.requestAccessibilityPermissionPrompt()
                    Log.autoInsert.info("axTrusted=false; copied only; prompted for Accessibility")
                }
            }

            // Persist the session to History (once).
            self.archiveCurrent(endReason: .completed)

            // Show review overlay after paste attempt (non-activating).
            self.overlay.presentReview(
                appName: self.appContext?.appName ?? "Unknown",
                screenshot: self.screenshot,
                transcript: self.transcriptDraft
            )
            self.phase = .review
        }

    }

    func cancel() {
        archiveCurrent(endReason: .cancelled)
        transcription.reset()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil
        targetPIDForInsert = nil
        phase = .idle
        overlay.presentIdleChip()
        Log.app.info("session cancel()")
    }

    func removeScreenshot() {
        screenshot = nil
        overlay.model.screenshot = nil
        Log.app.info("Screenshot removed by user")
    }

    func updateTranscript(_ text: String) {
        transcriptDraft = text
        Log.app.debug("Transcript edited by user: \(text.prefix(50))...")
    }

    func sendToAI() {
        overlay.presentProcessing()
        phase = .processing
        Log.app.info("sendToAI started with transcript: \(self.transcriptDraft.prefix(50), privacy: .public)... isFollowUp=\(self.isFollowUp) historyTurns=\(self.conversationTurns.count)")

        // Build the history to send (for follow-ups, this includes all previous turns)
        // The current prompt is sent separately, not in history
        let historyToSend = conversationTurns

        // Add user turn to our local tracking (not yet sent to AI)
        if !isFollowUp {
            let userTurn = ConversationTurn(role: .user, content: transcriptDraft, timestamp: Date())
            conversationTurns.append(userTurn)
        }
        // Note: For follow-ups, the turn was already added in endFollowUp()

        // Update overlay immediately with user turn
        self.overlay.model.conversationTurns = self.conversationTurns

        Task { @MainActor in
            do {
                // Add placeholder for streaming response
                let placeholderTurn = ConversationTurn(role: .assistant, content: "...", timestamp: Date())
                self.conversationTurns.append(placeholderTurn)
                self.overlay.model.conversationTurns = self.conversationTurns

                // Transition to response mode early to show streaming
                self.overlay.presentResponse("...")
                self.phase = .response

                // Use non-streaming API (more reliable)
                Log.app.info("Starting AI request...")
                let response = try await aiService.analyzeWithHistory(
                    screenshot: screenshot?.image,
                    prompt: transcriptDraft,
                    conversationHistory: historyToSend
                )
                Log.app.info("AI request completed with \(response.count) chars")

                // Final update with complete response
                if !self.conversationTurns.isEmpty {
                    self.conversationTurns[self.conversationTurns.count - 1] = ConversationTurn(
                        role: .assistant,
                        content: response,
                        timestamp: Date()
                    )
                }
                self.overlay.model.conversationTurns = self.conversationTurns
                self.overlay.model.responseText = response
                self.isFollowUp = false  // Reset follow-up state
                Log.app.info("AI streaming complete: \(response.prefix(100), privacy: .public)... totalTurns=\(self.conversationTurns.count)")

                // Save AI response to history
                if let sessionId = self.currentSessionId {
                    self.history.addResponse(sessionId: sessionId, response: response)
                }
            } catch {
                // Remove placeholder on error
                if !self.conversationTurns.isEmpty && self.conversationTurns.last?.role == .assistant {
                    self.conversationTurns.removeLast()
                    self.overlay.model.conversationTurns = self.conversationTurns
                }
                let errorMessage = (error as? AIService.AIError)?.localizedDescription ?? error.localizedDescription
                self.overlay.presentError(errorMessage)
                self.phase = .error(message: errorMessage)
                self.isFollowUp = false  // Reset follow-up state on error
                Log.app.error("AI request failed: \(errorMessage, privacy: .public)")
            }
        }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptDraft, forType: .string)
    }

    func insertTranscript() {
        guard !transcriptDraft.isEmpty else { return }
        if AutoInsertService.isAccessibilityTrusted() {
            AutoInsertService.copyAndPasteKeepingClipboard(transcriptDraft)
            Log.autoInsert.info("manual insert transcript len=\(self.transcriptDraft.count, privacy: .public) keepClipboard=true")
        } else {
            AutoInsertService.requestAccessibilityPermissionPrompt()
            Log.autoInsert.info("accessibility not trusted; prompted")
        }
    }

    /// Start a follow-up question flow (continue existing conversation)
    /// Streams live transcription into the text input field
    func beginFollowUp() {
        guard currentSessionId != nil else {
            Log.session.warning("beginFollowUp called without active session")
            return
        }

        Log.session.info("beginFollowUp() - voice follow-up with live transcription")
        isFollowUp = true
        listeningStartedAt = Date()
        transcriptDraft = ""
        overlay.model.followUpInputText = ""  // Clear text field
        overlay.model.isRecordingFollowUp = true  // Show recording state in UI

        // Stay in response mode visually - just update the input area
        phase = .listening

        // Start transcription for follow-up
        Task { @MainActor in
            do {
                try await self.transcription.start()
                FeedbackSoundService.playStart()
                if let listeningStartedAt {
                    let ms = Int(Date().timeIntervalSince(listeningStartedAt) * 1000.0)
                    Log.stt.info("follow-up listening cue played latencyMs=\(ms, privacy: .public)")
                }
            } catch {
                self.overlay.model.isRecordingFollowUp = false
                self.phase = .response  // Go back to response mode on error
                Log.stt.error("follow-up transcription start threw: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Stream partial text INTO the text field (live transcription)
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await text in self.transcription.$partialText.values {
                guard self.phase == .listening, self.isFollowUp else { break }
                self.overlay.model.followUpInputText = text  // Live update text field!
            }
        }

        // Stream mic level updates (for potential visualizer)
        levelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await lvl in AudioLevelService.shared.$level.values {
                guard self.phase == .listening else { break }
                self.overlay.model.audioLevel = lvl
            }
        }
    }

    /// End follow-up recording and send to AI
    func endFollowUp() {
        guard phase == .listening, isFollowUp else { return }
        Log.session.info("endFollowUp()")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil
        overlay.model.isRecordingFollowUp = false  // Stop recording state

        Task { @MainActor in
            await self.transcription.stopAndFinalize()
            let finalText = self.transcription.finalText.isEmpty
                ? self.transcription.partialText
                : self.transcription.finalText

            // Update text field with final text (may have improved from partial)
            self.overlay.model.followUpInputText = finalText
            self.transcriptDraft = finalText
            self.overlay.model.audioLevel = 0.0

            if !finalText.isEmpty {
                // Add follow-up turn to history
                if let sessionId = self.currentSessionId {
                    self.history.addFollowUp(sessionId: sessionId, question: finalText)
                }

                // Add to local turns
                let followUpTurn = ConversationTurn(role: .user, content: finalText, timestamp: Date())
                self.conversationTurns.append(followUpTurn)

                // Clear text field after sending
                self.overlay.model.followUpInputText = ""

                // Send to AI with full conversation context
                self.sendToAI()
            } else {
                // No transcript - stay in response mode
                self.isFollowUp = false
                self.phase = .response
            }
        }
    }

    /// Send a typed follow-up (from text field)
    func sendTextFollowUp(_ text: String) {
        guard currentSessionId != nil else {
            Log.session.warning("sendTextFollowUp called without active session")
            return
        }
        Log.session.info("sendTextFollowUp: \(text.prefix(50), privacy: .public)...")

        transcriptDraft = text
        isFollowUp = true  // Mark as follow-up for sendToAI logic

        // Add to history
        if let sessionId = currentSessionId {
            history.addFollowUp(sessionId: sessionId, question: text)
        }

        // Add to conversation turns
        let turn = ConversationTurn(role: .user, content: text, timestamp: Date())
        conversationTurns.append(turn)

        // Send to AI
        sendToAI()
    }

    /// Continue a conversation from History
    /// Loads the existing turns and presents the overlay in response mode
    func continueSession(from record: SessionRecord) {
        Log.session.info("continueSession from history id=\(record.id.uuidString, privacy: .public) turns=\(record.turns.count)")

        // If there's an active session, archive it first
        if phase != .idle {
            archiveCurrent(endReason: .interrupted)
            resetToIdle()
        }

        // Set up session state from the record
        currentSessionId = record.id
        sessionStartedAt = record.startedAt
        didSaveCurrentSession = true  // Already in history, don't re-save
        conversationTurns = record.turns
        isFollowUp = false
        transcriptDraft = record.transcript

        // Load screenshot if available
        if let screenshotPath = record.screenshotPath,
           let nsImage = NSImage(contentsOfFile: screenshotPath),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            screenshot = ScreenshotCaptureResult(
                image: cgImage,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                scale: 2.0  // Assume retina
            )
        }

        // Set up app context from record
        appContext = ActiveAppContext(
            appName: record.appName,
            bundleIdentifier: record.bundleIdentifier ?? "",
            pid: pid_t(record.targetPID ?? 0)
        )

        // Update overlay model
        overlay.model.conversationTurns = conversationTurns
        overlay.model.appName = record.appName
        overlay.model.screenshot = screenshot
        overlay.model.followUpInputText = ""

        // Present in response mode with last AI response (this also shows the overlay)
        let lastResponse = record.aiResponse ?? ""
        overlay.presentResponse(lastResponse)
        phase = .response
    }
}

private extension SessionController {
    func archiveCurrent(endReason: SessionRecord.EndReason) {
        guard !didSaveCurrentSession else { return }
        guard let currentSessionId, let sessionStartedAt else { return }

        // Only save sessions that have something meaningful.
        let transcript = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty, screenshot == nil { return }

        let endedAt = Date()
        let screenshotPath = history.saveScreenshotIfNeeded(screenshot, sessionId: currentSessionId)
        let record = SessionRecord(
            id: currentSessionId,
            startedAt: sessionStartedAt,
            endedAt: endedAt,
            endReason: endReason,
            appName: appContext?.appName ?? "Unknown",
            bundleIdentifier: appContext?.bundleIdentifier,
            targetPID: appContext.map { Int($0.pid) },
            transcript: transcript,
            screenshotPath: screenshotPath
        )
        history.add(record)
        didSaveCurrentSession = true
        Log.session.info("history saved id=\(record.id.uuidString, privacy: .public) reason=\(String(describing: endReason), privacy: .public)")
    }

    func resetToIdle() {
        transcription.reset()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil
        targetPIDForInsert = nil
        screenshot = nil
        transcriptDraft = ""
        appContext = nil
        phase = .idle
        overlay.presentIdleChip()
    }
}


