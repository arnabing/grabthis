import AVFoundation
import Foundation
@preconcurrency import WhisperKit

/// WhisperKit-based transcription engine for high-accuracy local speech recognition.
/// Uses batch processing (no streaming) - audio is recorded, then transcribed after recording stops.
@MainActor
final class WhisperKitTranscriptionEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var state: TranscriptionState = .idle
    @Published private(set) var partialText: String = ""  // Always empty for batch processing
    @Published private(set) var finalText: String = ""

    // WhisperKit is not Sendable, but we only use it on MainActor
    nonisolated(unsafe) private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var audioConverter: AVAudioConverter?
    private let modelManager = WhisperKitModelManager.shared

    // MARK: - TranscriptionEngine Protocol

    func start() async throws {
        guard state == .idle || state == .stopped else {
            Log.stt.warning("WhisperKit start called in invalid state: \(String(describing: self.state))")
            return
        }

        // Reset state
        partialText = ""
        finalText = ""
        audioBuffer = []

        // Load WhisperKit model if needed
        do {
            whisperKit = try await modelManager.getWhisperKit()
        } catch {
            state = .error(message: "Failed to load WhisperKit model: \(error.localizedDescription)")
            Log.stt.error("WhisperKit model load failed: \(error.localizedDescription)")
            throw error
        }

        // Setup audio capture
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // WhisperKit expects 16kHz mono float samples
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            state = .error(message: "Failed to create audio format")
            throw WhisperKitError.transcriptionFailed("Audio format creation failed")
        }

        // Create converter from input format to WhisperKit format
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state = .error(message: "Failed to create audio converter")
            throw WhisperKitError.transcriptionFailed("Audio converter creation failed")
        }
        self.audioConverter = converter

        // Install audio tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            state = .listening
            Log.stt.info("WhisperKit listening started")
        } catch {
            state = .error(message: "Audio engine failed to start: \(error.localizedDescription)")
            Log.stt.error("WhisperKit audio engine start failed: \(error.localizedDescription)")
            throw error
        }
    }

    func stopAndFinalize(tailNanoseconds: UInt64 = 180_000_000, finalWaitNanoseconds: UInt64 = 0) async {
        guard state == .listening else {
            Log.stt.warning("WhisperKit stopAndFinalize called in non-listening state")
            return
        }

        // Brief tail capture to catch last words
        if tailNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: tailNanoseconds)
        }

        // Stop audio capture
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil

        // Transition to processing state
        state = .processing
        let durationSec = Double(self.audioBuffer.count) / 16000.0
        Log.stt.info("WhisperKit processing \(self.audioBuffer.count) samples (~\(String(format: "%.1f", durationSec))s of audio)")

        // Run transcription
        guard whisperKit != nil else {
            state = .error(message: "WhisperKit not initialized")
            return
        }

        guard !audioBuffer.isEmpty else {
            finalText = ""
            state = .stopped
            Log.stt.warning("WhisperKit: No audio captured")
            return
        }

        // Copy audio buffer to local for transcription
        let audioToTranscribe = self.audioBuffer

        do {
            let startTime = Date()

            // Transcribe the audio buffer (WhisperKit is nonisolated(unsafe) to bypass Sendable check)
            let results = try await self.whisperKit!.transcribe(audioArray: audioToTranscribe)

            // Combine all segment texts
            finalText = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            let elapsed = Date().timeIntervalSince(startTime)
            Log.stt.info("WhisperKit transcription complete in \(String(format: "%.2f", elapsed))s: \(self.finalText.prefix(50))...")

            state = .stopped

        } catch {
            Log.stt.error("WhisperKit transcription failed: \(error.localizedDescription)")
            state = .error(message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        // Stop any active recording
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil

        // Clear buffers and state
        audioBuffer = []
        partialText = ""
        finalText = ""
        state = .idle
    }

    // MARK: - Private Methods

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
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

        // Extract float samples and append to buffer
        if let channelData = convertedBuffer.floatChannelData?[0] {
            let frames = Int(convertedBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))

            // Append on main actor
            Task { @MainActor in
                self.audioBuffer.append(contentsOf: samples)
            }

            // Feed AudioLevelService for waveform visualization
            let rms = computeRMS(convertedBuffer)
            AudioLevelService.ingestFromAudioThread(rms: rms)
        }
    }

    private nonisolated func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
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
