import AVFoundation
import Foundation

/// Deepgram-based transcription engine for cloud-based speech recognition.
/// Uses Nova-3 model with streaming results for best accuracy (~4% WER).
@MainActor
final class DeepgramTranscriptionEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var state: TranscriptionState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""

    private let deepgram = DeepgramService()
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var receiveTask: Task<Void, Never>?

    /// Accumulated finalized segments (Deepgram sends multiple final segments during streaming)
    private var accumulatedFinalText: String = ""

    // MARK: - TranscriptionEngine Protocol

    func start() async throws {
        guard state == .idle || state == .stopped else {
            Log.stt.warning("Deepgram start called in invalid state: \(String(describing: self.state))")
            return
        }

        // Check for API key
        guard DeepgramService.hasAPIKey else {
            state = .error(message: "Deepgram API key not configured")
            throw DeepgramError.noAPIKey
        }

        // Reset state
        partialText = ""
        finalText = ""
        accumulatedFinalText = ""

        // Connect to Deepgram
        do {
            try await deepgram.connect()
        } catch {
            state = .error(message: "Failed to connect to Deepgram: \(error.localizedDescription)")
            throw error
        }

        // Start receiving transcripts
        receiveTask = Task { [weak self] in
            guard let self else { return }

            for await result in await self.deepgram.receiveTranscripts() {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    if result.isFinal {
                        // Append to accumulated final text
                        if self.accumulatedFinalText.isEmpty {
                            self.accumulatedFinalText = result.text
                        } else {
                            self.accumulatedFinalText += " " + result.text
                        }
                        // Update partialText to show full accumulated text (UI subscribes to this)
                        self.partialText = self.accumulatedFinalText
                    } else {
                        // Show accumulated final + current interim for smooth display
                        if self.accumulatedFinalText.isEmpty {
                            self.partialText = result.text
                        } else {
                            self.partialText = self.accumulatedFinalText + " " + result.text
                        }
                    }
                }
            }
        }

        // Setup audio capture
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Deepgram expects 16kHz mono linear16 (Int16)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            state = .error(message: "Failed to create audio format")
            throw DeepgramError.connectionFailed("Audio format creation failed")
        }

        // Create converter
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state = .error(message: "Failed to create audio converter")
            throw DeepgramError.connectionFailed("Audio converter creation failed")
        }
        self.audioConverter = converter

        // Install audio tap - must use nonisolated static function to avoid MainActor inference
        // The tap closure runs on a real-time audio thread and cannot call @MainActor methods
        let tap = Self.makeTapBlock(deepgram: deepgram, converter: converter, targetFormat: targetFormat)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: tap)

        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            state = .listening
            Log.stt.info("Deepgram listening started")
        } catch {
            state = .error(message: "Audio engine failed to start: \(error.localizedDescription)")
            await deepgram.disconnect()
            throw error
        }
    }

    func stopAndFinalize(tailNanoseconds: UInt64 = 180_000_000, finalWaitNanoseconds: UInt64 = 650_000_000) async {
        guard state == .listening else {
            Log.stt.warning("Deepgram stopAndFinalize called in non-listening state")
            return
        }

        // Brief tail capture
        if tailNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: tailNanoseconds)
        }

        // Stop audio capture
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil

        // Signal end of audio to Deepgram
        try? await deepgram.finishAudio()

        // Wait for final results
        if finalWaitNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: finalWaitNanoseconds)
        }

        // Cancel receive task
        receiveTask?.cancel()
        receiveTask = nil

        // Disconnect
        await deepgram.disconnect()

        // Set finalText from accumulated text (partialText contains the full running transcript)
        finalText = partialText.isEmpty ? accumulatedFinalText : partialText

        state = .stopped
        Log.stt.info("Deepgram stopped, final: \(self.finalText.prefix(50))...")
    }

    func reset() {
        // Stop any active recording
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil

        // Cancel receive task
        receiveTask?.cancel()
        receiveTask = nil

        // Disconnect
        Task {
            await deepgram.disconnect()
        }

        // Clear state
        partialText = ""
        finalText = ""
        accumulatedFinalText = ""
        state = .idle
    }

    // MARK: - Private Methods (nonisolated for audio thread safety)

    /// Creates the audio tap block in a nonisolated context to prevent @MainActor inference.
    /// This is critical because the audio tap callback runs on a real-time audio thread.
    nonisolated static func makeTapBlock(
        deepgram: DeepgramService,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            // Feed AudioLevelService for waveform visualization (safe for audio thread)
            let rms = computeRMS(buffer)
            AudioLevelService.ingestFromAudioThread(rms: rms)

            // Calculate output buffer size
            let inputFrames = buffer.frameLength
            let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(inputFrames) * sampleRateRatio) + 1

            // Create output buffer
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            // Convert audio
            var error: NSError?
            var inputBufferConsumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputBufferConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputBufferConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, convertedBuffer.frameLength > 0 else { return }

            // Extract Int16 samples and send to Deepgram
            if let channelData = convertedBuffer.int16ChannelData?[0] {
                let frames = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData, count: frames * MemoryLayout<Int16>.size)

                // Send asynchronously to the actor
                Task {
                    try? await deepgram.send(audioData: data)
                }
            }
        }
    }

    nonisolated static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let v = data[i]
            sum += v * v
        }
        return sqrt(sum / Float(count))
    }
}
