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
    private var transcriptionTask: Task<Void, Never>?
    private var targetPIDForInsert: pid_t?
    private var listeningStartedAt: Date?

    init(overlay: OverlayPanelController) {
        self.overlay = overlay
        self.transcription = TranscriptionService()
    }

    func begin() {
        guard phase == .idle else { return }
        Log.session.info("begin()")
        listeningStartedAt = Date()

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
    }

    func end() {
        guard phase == .listening else { return }
        Log.session.info("end()")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        Task { @MainActor in
            await self.transcription.stopAndFinalize()
            self.transcriptDraft = self.transcription.finalText.isEmpty ? self.transcription.partialText : self.transcription.finalText
            self.overlay.setAccessibilityTrusted(AutoInsertService.isAccessibilityTrusted())

            if !self.transcriptDraft.isEmpty {
                // Ensure overlay doesn't interfere with focus/paste timing.
                self.overlay.hide()

                let targetPID = self.targetPIDForInsert
                let targetAppName = self.appContext?.appName ?? "Unknown"
                let frontmostBefore = NSWorkspace.shared.frontmostApplication
                Log.autoInsert.info("start target=\(targetAppName, privacy: .public) pid=\(targetPID ?? -1, privacy: .public) frontmostBefore=\(frontmostBefore?.localizedName ?? "nil", privacy: .public) bundle=\(frontmostBefore?.bundleIdentifier ?? "nil", privacy: .public) overlayKey=\(self.overlay.isOverlayKeyWindow, privacy: .public)")

                if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
                    let ok = app.activate(options: [.activateAllWindows])
                    Log.autoInsert.info("activate targetPid=\(targetPID, privacy: .public) ok=\(ok, privacy: .public) isActive=\(app.isActive, privacy: .public)")
                }

                // Let focus settle (especially for Electron apps like Cursor).
                let settleDeadline = Date().addingTimeInterval(0.65)
                while Date() < settleDeadline {
                    if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 45_000_000)
                }

                AutoInsertService.copyToClipboardKeeping(_text: self.transcriptDraft)

                let frontmostAtPaste = NSWorkspace.shared.frontmostApplication
                let axTrusted = AutoInsertService.isAccessibilityTrusted()
                self.overlay.setAccessibilityTrusted(axTrusted)
                Log.autoInsert.info("paste frontmostAtPaste=\(frontmostAtPaste?.localizedName ?? "nil", privacy: .public) pid=\(frontmostAtPaste?.processIdentifier ?? -1, privacy: .public) bundle=\(frontmostAtPaste?.bundleIdentifier ?? "nil", privacy: .public) axTrusted=\(axTrusted, privacy: .public)")

                if axTrusted {
                    // Try AX insert first (often more reliable for Cursor).
                    let axOk = AutoInsertService.tryInsertViaAccessibility(self.transcriptDraft)
                    Log.autoInsert.info("strategy axInsert ok=\(axOk, privacy: .public)")
                    if !axOk {
                        let menuOk = AutoInsertService.tryPasteViaEditMenu(targetPID: targetPID)
                        Log.autoInsert.info("strategy menuPaste ok=\(menuOk, privacy: .public)")
                        if !menuOk {
                            AutoInsertService.copyAndPasteKeepingClipboard(self.transcriptDraft)
                            Log.autoInsert.info("strategy cmdV fallback sent")
                        }
                    }
                } else {
                    // We can still copy (already done), but we cannot reliably auto-insert without Accessibility.
                    AutoInsertService.requestAccessibilityPermissionPrompt()
                    Log.autoInsert.info("axTrusted=false; copied only; prompted for Accessibility")
                }
            }

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
        transcription.reset()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        targetPIDForInsert = nil
        phase = .idle
        overlay.hide()
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


