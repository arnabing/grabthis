import AVFoundation
import Foundation
import Speech

/// Modern SpeechAnalyzer-based transcription engine (macOS 26+).
/// Uses on-device DictationTranscriber for fast, private transcription with punctuation.
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerTranscriptionEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var state: TranscriptionState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""

    /// Track the longest partial to prevent regression during re-evaluation
    private var longestPartialSeen: String = ""

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var stopRequestedAt: Date?

    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Check if the language model is available for the current locale.
    static func isModelAvailable(for locale: Locale = .current) async -> Bool {
        let supportedLocales = await DictationTranscriber.supportedLocales
        return supportedLocales.contains(locale)
    }

    /// Download the language model for a locale.
    /// Note: On macOS 26, models are managed automatically by the system.
    static func downloadModel(for locale: Locale = .current) async throws {
        let supportedLocales = await DictationTranscriber.supportedLocales
        guard supportedLocales.contains(locale) else {
            throw TranscriptionEngineError.localeNotSupported
        }
        // Models are managed automatically by the system on macOS 26
        Log.stt.info("Language model for \(locale.identifier) is managed by the system")
    }

    /// Get download progress for a locale's model.
    /// Note: On macOS 26, models are managed automatically.
    static func downloadProgress(for locale: Locale = .current) -> AsyncStream<Double> {
        AsyncStream { continuation in
            continuation.yield(1.0)
            continuation.finish()
        }
    }

    func start() async throws {
        Log.stt.info("SpeechAnalyzerTranscriptionEngine.start() called")
        guard state == .idle || state == .stopped else { return }

        // Check permissions
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            state = .error(message: "Speech Recognition permission not granted")
            Log.stt.error("speech auth not granted")
            return
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != .authorized {
            Log.stt.error("microphone auth not granted: \(String(describing: mic))")
        }

        // Check locale support using BCP47 identifiers
        let localeId = locale.identifier(.bcp47)
        let supported = await DictationTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(localeId) else {
            state = .error(message: "Language '\(localeId)' not supported for on-device transcription")
            Log.stt.error("locale not supported: \(localeId)")
            throw TranscriptionEngineError.localeNotSupported
        }

        // Check if model is installed, download if needed
        let installed = await DictationTranscriber.installedLocales
        if !installed.map({ $0.identifier(.bcp47) }).contains(localeId) {
            Log.stt.info("Downloading speech model for \(localeId)...")
            state = .error(message: "Downloading language model...")  // Temporary status
            // Create transcriber for download request
            let tempTranscriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [tempTranscriber]) {
                try await downloader.downloadAndInstall()
            }
            Log.stt.info("Speech model downloaded for \(localeId)")
        }

        partialText = ""
        finalText = ""
        longestPartialSeen = ""
        stopRequestedAt = nil

        // Create DictationTranscriber for notes/messages with automatic punctuation
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        self.transcriber = transcriber

        // Get the required audio format for the analyzer
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            state = .error(message: "Failed to get analyzer audio format")
            Log.stt.error("bestAvailableAudioFormat returned nil")
            throw TranscriptionEngineError.audioFormatConversionFailed
        }
        self.analyzerFormat = analyzerFormat
        Log.stt.debug("analyzer format: \(analyzerFormat.debugDescription, privacy: .public)")

        // Create analyzer with transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Create async stream for audio input
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Set up audio engine
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        Log.stt.debug("mic format: \(micFormat.debugDescription, privacy: .public)")

        // Create audio converter from mic format to analyzer format
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            state = .error(message: "Failed to create audio format converter")
            Log.stt.error("failed to create AVAudioConverter from mic to analyzer format")
            throw TranscriptionEngineError.audioFormatConversionFailed
        }
        self.audioConverter = converter

        inputNode.removeTap(onBus: 0)

        // Create audio tap that converts and feeds audio to the analyzer
        let tap = Self.makeTapBlock(
            continuation: continuation,
            converter: converter,
            analyzerFormat: analyzerFormat
        )
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat, block: tap)

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .error(message: "Audio engine failed to start: \(error.localizedDescription)")
            Log.stt.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        state = .listening
        Log.stt.info("listening started with SpeechAnalyzer")

        // Start the analyzer with the input sequence
        analyzerTask = Task { @MainActor in
            do {
                try await analyzer.start(inputSequence: inputSequence)
            } catch {
                if self.stopRequestedAt == nil {
                    Log.stt.error("analyzer start failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Start consuming transcription results
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self, let transcriber = self.transcriber else { return }

            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }

                    // Convert AttributedString to plain String
                    let text = String(result.text.characters)

                    // Prevent regression: only update if we have more text than before
                    if text.count >= self.longestPartialSeen.count {
                        self.partialText = text
                        self.longestPartialSeen = text
                    }

                    Log.stt.debug("partial: \(self.partialText.suffix(50), privacy: .public) (len=\(self.partialText.count))")

                    if result.isFinal {
                        self.finalText = self.longestPartialSeen.isEmpty ? text : self.longestPartialSeen
                        if self.stopRequestedAt != nil {
                            self.state = .stopped
                        }
                        Log.stt.info("final: len=\(self.finalText.count)")
                    }
                }

                // Stream ended naturally (not from user stop or error)
                // This happens when Apple's DictationTranscriber times out (~30s of silence)
                if self.stopRequestedAt == nil && self.state == .listening {
                    Log.stt.warning("⚠️ DictationTranscriber stream ended unexpectedly (Apple inactivity timeout?) - dictation paused")
                    // Don't change state - audio engine is still running
                    // User can continue speaking and we'll keep listening
                    // The finalText will contain what was captured so far
                }
            } catch {
                if self.stopRequestedAt != nil, !self.partialText.isEmpty {
                    self.finalText = self.finalText.isEmpty ? self.partialText : self.finalText
                    self.state = .stopped
                    Log.stt.error("transcription error during stop (ignored due to text): \(error.localizedDescription, privacy: .public)")
                } else {
                    self.state = .error(message: error.localizedDescription)
                    Log.stt.error("transcription error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stopAndFinalize(tailNanoseconds: UInt64 = 180_000_000, finalWaitNanoseconds: UInt64 = 650_000_000) async {
        guard let audioEngine, let analyzer else { return }

        stopRequestedAt = Date()
        Log.stt.info("stopAndFinalize() called tailNs=\(tailNanoseconds, privacy: .public) waitNs=\(finalWaitNanoseconds, privacy: .public)")

        // Keep capturing just a touch after key-up
        if tailNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: tailNanoseconds)
        }

        // Stop audio input IMMEDIATELY to release microphone
        // This helps Bluetooth switch from HFP back to A2DP faster
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Release audio resources immediately (helps Bluetooth audio quality recovery)
        self.audioConverter = nil
        self.audioEngine = nil
        Log.stt.info("🎧 Audio engine released - Bluetooth should recover to A2DP")

        // Finish the input stream
        inputContinuation?.finish()
        inputContinuation = nil

        // Signal end of audio to analyzer
        try? await analyzer.finalizeAndFinishThroughEndOfInput()

        // Wait for final result
        let deadline = Date().addingTimeInterval(Double(finalWaitNanoseconds) / 1_000_000_000.0)
        while Date() < deadline {
            if !finalText.isEmpty { break }
            if case .error = state { break }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }

        // Cleanup remaining resources
        transcriptionTask?.cancel()
        transcriptionTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        self.analyzer = nil
        self.transcriber = nil

        // Prefer final, otherwise keep the longest partial we saw
        if finalText.isEmpty {
            finalText = longestPartialSeen.isEmpty ? partialText : longestPartialSeen
        }

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
        longestPartialSeen = ""
        state = .idle
    }
}

// MARK: - Audio Processing

@available(macOS 26, *)
private extension SpeechAnalyzerTranscriptionEngine {
    nonisolated static func makeTapBlock(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        converter: AVAudioConverter,
        analyzerFormat: AVAudioFormat
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            // Drive notch visualizer with real mic level (safe for audio thread)
            let rms = computeRMS(buffer)
            AudioLevelService.ingestFromAudioThread(rms: rms)

            // Calculate output buffer size based on sample rate ratio
            let inputFrames = buffer.frameLength
            let sampleRateRatio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(inputFrames) * sampleRateRatio) + 1

            // Create output buffer in analyzer format
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            // Convert audio from mic format to analyzer format
            var error: NSError?
            var inputBufferConsumed = false
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if inputBufferConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputBufferConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, convertedBuffer.frameLength > 0 else { return }

            // Feed converted audio to the analyzer
            let input = AnalyzerInput(buffer: convertedBuffer)
            continuation.yield(input)
        }
    }

    nonisolated static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let data = buffer.floatChannelData {
            let ch0 = data[0]
            var sum: Float = 0
            for i in 0..<frameLength {
                let v = ch0[i]
                sum += v * v
            }
            return sqrt(sum / Float(frameLength))
        }

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

// MARK: - Errors

enum TranscriptionEngineError: LocalizedError {
    case localeNotSupported
    case modelNotInstalled
    case audioFormatConversionFailed

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return "This language is not supported for on-device transcription"
        case .modelNotInstalled:
            return "The language model needs to be downloaded first"
        case .audioFormatConversionFailed:
            return "Failed to convert audio to the required format"
        }
    }
}
