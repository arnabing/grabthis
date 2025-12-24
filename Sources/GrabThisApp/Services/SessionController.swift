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
    private let history = SessionHistoryStore.shared
    private var transcriptionTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var targetPIDForInsert: pid_t?
    private var listeningStartedAt: Date?
    private var currentSessionId: UUID?
    private var sessionStartedAt: Date?
    private var didSaveCurrentSession: Bool = false

    init(overlay: OverlayPanelController) {
        self.overlay = overlay
        self.transcription = TranscriptionService()
        self.overlay.presentIdleChip()
    }

    func begin() {
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
                let shot = try await CaptureService.captureActiveWindow()
                self.screenshot = shot
                self.overlay.updateListening(screenshot: shot)
                Log.capture.info("captured active window \(shot.pixelWidth)x\(shot.pixelHeight) scale=\(shot.scale, privacy: .public)")
            } catch {
                self.phase = .error(message: "Screenshot failed: \(error.localizedDescription)")
                self.overlay.presentError("Screenshot failed")
                Log.capture.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Start transcription after the overlay is already visible; this yields back to the run loop,
        // reducing the “fn → listening” perceived latency.
        Task { @MainActor in
            do {
                try self.transcription.start()
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
        Log.session.info("end()")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil
        Task { @MainActor in
            await self.transcription.stopAndFinalize()
            self.transcriptDraft = self.transcription.finalText.isEmpty ? self.transcription.partialText : self.transcription.finalText
            self.overlay.setAccessibilityTrusted(AutoInsertService.isAccessibilityTrusted())
            self.overlay.model.audioLevel = 0.0

            if !self.transcriptDraft.isEmpty {
                // Ensure overlay doesn't interfere with focus/paste timing.
                self.overlay.hide()

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

    func sendToAI() {
        // Placeholder: will be wired to LLMService in the next todo.
        overlay.presentProcessing()
        phase = .processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.overlay.presentResponse("LLM wiring next — transcript ready.\n\n\(self.transcriptDraft)")
            self.phase = .response
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


