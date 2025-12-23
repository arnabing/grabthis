import AVFoundation
import Foundation
import Speech

@MainActor
final class TranscriptionService: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case stopped
        case error(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let audioEngine = AVAudioEngine()

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() throws {
        Log.stt.info("start() called")
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

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    Log.stt.debug("partial: \(self.partialText, privacy: .public)")
                    if result.isFinal {
                        self.finalText = self.partialText
                        self.state = .stopped
                        Log.stt.info("final: \(self.finalText, privacy: .public)")
                    }
                }
                if let error {
                    self.state = .error(message: error.localizedDescription)
                    Log.stt.error("recognition error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() {
        guard state == .listening else { return }
        Log.stt.info("stop() called")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        finalText = finalText.isEmpty ? partialText : finalText
        state = .stopped
        Log.stt.info("stopped finalTextLen=\(self.finalText.count, privacy: .public)")
    }

    func reset() {
        if state == .listening {
            stop()
        }
        partialText = ""
        finalText = ""
        state = .idle
    }
}

private extension TranscriptionService {
    nonisolated static func makeTapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            request.append(buffer)
        }
    }
}


