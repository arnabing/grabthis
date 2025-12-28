import AVFoundation
import Foundation
import Speech

/// Classic SFSpeechRecognizer-based transcription engine.
/// Uses cloud-based recognition by default for better accuracy.
@MainActor
final class SFSpeechTranscriptionEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var state: TranscriptionState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var stopRequestedAt: Date?

    private let audioEngine = AVAudioEngine()

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() async throws {
        Log.stt.info("SFSpeechTranscriptionEngine.start() called")
        guard state == .idle || state == .stopped else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            state = .error(message: "Speech Recognition permission not granted")
            Log.stt.error("speech auth not granted")
            return
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != .authorized {
            Log.stt.error("microphone auth not granted: \(String(describing: mic))")
        }
        if recognizer == nil {
            Log.stt.error("SFSpeechRecognizer is nil for current locale")
        }

        partialText = ""
        finalText = ""

        // IMPORTANT: The audio tap callback runs off the main thread.
        // Do not touch @MainActor state from inside that callback.
        // Capture the request as a local constant and append buffers directly to it.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        Log.stt.debug("audio format: \(recordingFormat.debugDescription, privacy: .public)")
        inputNode.removeTap(onBus: 0)
        // The tap is called on a realtime queue. If this closure is inferred as @MainActor,
        // Swift will crash with a libdispatch assertion. Create the block in a nonisolated
        // context to prevent global-actor inference.
        let tap = Self.makeTapBlock(request)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: tap)

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .error(message: "Audio engine failed to start: \(error.localizedDescription)")
            Log.stt.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        state = .listening
        Log.stt.info("listening started")
        stopRequestedAt = nil

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    Log.stt.debug("partial: \(self.partialText, privacy: .public)")
                    if result.isFinal {
                        self.finalText = self.partialText
                        // IMPORTANT: The recognizer can emit `isFinal` while we're still holding
                        // push-to-talk (e.g., brief silence). Do not end the session early.
                        if self.stopRequestedAt != nil {
                            self.state = .stopped
                        }
                        Log.stt.info("final: \(self.finalText, privacy: .public) stopRequested=\(self.stopRequestedAt != nil, privacy: .public)")
                    }
                }
                if let error {
                    // If we're stopping and we already have text, prefer a "stopped" state to keep the
                    // Wispr-like feel rather than surfacing an error.
                    if self.stopRequestedAt != nil, !self.partialText.isEmpty {
                        self.finalText = self.finalText.isEmpty ? self.partialText : self.finalText
                        self.state = .stopped
                        Log.stt.error("recognition error during stop (ignored due to text): \(error.localizedDescription, privacy: .public)")
                    } else {
                        self.state = .error(message: error.localizedDescription)
                        Log.stt.error("recognition error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Stop capture while giving the recognizer a tiny grace window to emit the last word(s).
    /// This reduces the "clips the last word" feeling in push-to-talk flows.
    func stopAndFinalize(tailNanoseconds: UInt64 = 180_000_000, finalWaitNanoseconds: UInt64 = 650_000_000) async {
        // The recognizer can emit a `.stopped`/`.error` state asynchronously; we still must stop the
        // audio engine + tap to avoid leaking audio capture and to finalize text.
        if !audioEngine.isRunning, recognitionRequest == nil, recognitionTask == nil {
            return
        }
        stopRequestedAt = Date()
        Log.stt.info("stopAndFinalize() called tailNs=\(tailNanoseconds, privacy: .public) waitNs=\(finalWaitNanoseconds, privacy: .public)")

        // Keep capturing just a touch after key-up.
        if tailNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: tailNanoseconds)
        }

        // Stop audio input and signal end of audio. Do NOT cancel recognitionTask immediately;
        // we want a chance to receive a final result.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        let deadline = Date().addingTimeInterval(Double(finalWaitNanoseconds) / 1_000_000_000.0)
        while Date() < deadline {
            if !finalText.isEmpty { break }
            if case .error = state { break }
            // Let callbacks run.
            try? await Task.sleep(nanoseconds: 35_000_000)
        }

        // Cleanup task/request.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // Prefer final, otherwise keep the best partial.
        if finalText.isEmpty {
            finalText = partialText
        }

        // If the recognizer reported an error like "No speech detected" but we have text,
        // treat it as a stopped session (Wispr-like).
        if case .error(let message) = state, !finalText.isEmpty {
            Log.stt.error("stop finalize overriding error due to captured text: \(message, privacy: .public)")
            state = .stopped
        } else if case .listening = state {
            state = .stopped
        }

        Log.stt.info("finalized finalTextLen=\(self.finalText.count, privacy: .public) partialLen=\(self.partialText.count, privacy: .public)")
    }

    func reset() {
        if state == .listening {
            Task { @MainActor in
                await self.stopAndFinalize(tailNanoseconds: 0, finalWaitNanoseconds: 0)
            }
        }
        partialText = ""
        finalText = ""
        state = .idle
    }
}

private extension SFSpeechTranscriptionEngine {
    nonisolated static func makeTapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            request.append(buffer)
            // Drive notch visualizer with real mic level (safe for audio thread).
            let rms = computeRMS(buffer)
            AudioLevelService.ingestFromAudioThread(rms: rms)
        }
    }

    nonisolated static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        // Prefer float samples.
        if let data = buffer.floatChannelData {
            let ch0 = data[0]
            var sum: Float = 0
            for i in 0..<frameLength {
                let v = ch0[i]
                sum += v * v
            }
            return sqrt(sum / Float(frameLength))
        }

        // Fallback: int16 samples.
        if let data = buffer.int16ChannelData {
            let ch0 = data[0]
            var sum: Float = 0
            let denom: Float = 32768.0
            for i in 0..<frameLength {
                let v = Float(ch0[i]) / denom
                sum += v * v
            }
            return sqrt(sum / Float(frameLength))
        }

        return 0
    }
}
