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

    init(overlay: OverlayPanelController) {
        self.overlay = overlay
        self.transcription = TranscriptionService()
    }

    func begin() {
        guard phase == .idle else { return }
        Log.app.info("session begin()")

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

        do {
            try transcription.start()
        } catch {
            phase = .error(message: "Transcription failed: \(error.localizedDescription)")
            overlay.presentError("Transcription failed")
            Log.stt.error("transcription start threw: \(error.localizedDescription, privacy: .public)")
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
        Log.app.info("session end()")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcription.stop()
        transcriptDraft = transcription.finalText.isEmpty ? transcription.partialText : transcription.finalText

        // Auto-insert flow:
        // - Hide overlay so it can't steal focus
        // - Re-activate the app the user was in at begin()
        // - Copy transcript to clipboard (keep it there)
        // - Cmd+V
        if !transcriptDraft.isEmpty {
            overlay.hide()

            let targetPID = targetPIDForInsert
            let targetAppName = appContext?.appName ?? "Unknown"
            let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            Log.app.info("auto-insert start target=\(targetAppName, privacy: .public) pid=\(targetPID ?? -1, privacy: .public) frontmostBefore=\(frontmostBefore, privacy: .public) overlayKey=\(self.overlay.isOverlayKeyWindow, privacy: .public)")

            if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
                _ = app.activate(options: [])
            }

            Task { @MainActor in
                // Let focus settle (especially for Electron apps like Cursor).
                try? await Task.sleep(nanoseconds: 160_000_000)

                AutoInsertService.copyToClipboardKeeping(_text: self.transcriptDraft)

                let frontmostAtPaste = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
                Log.app.info("auto-insert paste frontmostAtPaste=\(frontmostAtPaste, privacy: .public) axTrusted=\(AutoInsertService.isAccessibilityTrusted(), privacy: .public)")

                if AutoInsertService.isAccessibilityTrusted() {
                    AutoInsertService.copyAndPasteKeepingClipboard(self.transcriptDraft)
                }
            }
        }

        overlay.presentReview(
            appName: appContext?.appName ?? "Unknown",
            screenshot: screenshot,
            transcript: transcriptDraft
        )
        phase = .review
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
            Log.app.info("manual insert transcript len=\(self.transcriptDraft.count, privacy: .public) keepClipboard=true")
        } else {
            AutoInsertService.requestAccessibilityPermissionPrompt()
            Log.app.info("accessibility not trusted; prompted")
        }
    }
}


