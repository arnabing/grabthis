import AVFoundation
import Foundation

/// Common state for all transcription engines.
enum TranscriptionState: Equatable {
    case idle
    case listening
    case processing  // For batch engines (WhisperKit) after recording stops
    case stopped
    case error(message: String)
}

/// Available STT engine types.
enum TranscriptionEngineType: String, CaseIterable, Identifiable {
    case speechAnalyzer = "apple"
    case whisperKit = "whisperkit"
    case deepgram = "deepgram"
    case sfSpeech = "classic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechAnalyzer: return "Apple (On-Device)"
        case .whisperKit: return "WhisperKit (Local AI)"
        case .deepgram: return "Deepgram Nova-3"
        case .sfSpeech: return "Classic (Legacy)"
        }
    }

    var subtitle: String {
        switch self {
        case .speechAnalyzer: return "Free • Real-time • Private"
        case .whisperKit: return "Free • ~400MB download • Private"
        case .deepgram: return "Best accuracy (~4% WER) • $0.26/hr"
        case .sfSpeech: return "Legacy cloud-based"
        }
    }

    var accuracy: String {
        switch self {
        case .speechAnalyzer: return "Good"
        case .whisperKit: return "Better (~7% WER)"
        case .deepgram: return "Best (~4% WER)"
        case .sfSpeech: return "Fair"
        }
    }

    var description: String {
        switch self {
        case .speechAnalyzer: return "Faster, private, works offline"
        case .whisperKit: return "OpenAI Whisper via CoreML, best local accuracy"
        case .deepgram: return "Cloud-based, highest accuracy available"
        case .sfSpeech: return "Legacy cloud-based recognition"
        }
    }

    /// Whether this engine requires a model download before use
    var requiresDownload: Bool { self == .whisperKit }

    /// Whether this engine requires an API key
    var requiresAPIKey: Bool { self == .deepgram }

    /// Whether this engine provides streaming partial results
    var isStreaming: Bool { self != .whisperKit }

    /// Returns only engine types available on the current macOS version.
    static var availableCases: [TranscriptionEngineType] {
        var engines: [TranscriptionEngineType] = [.whisperKit, .deepgram, .sfSpeech]
        if #available(macOS 26, *) {
            engines.insert(.speechAnalyzer, at: 0)
        }
        return engines
    }

    /// Check if this engine type is available on the current macOS version.
    var isAvailable: Bool {
        switch self {
        case .speechAnalyzer:
            if #available(macOS 26, *) {
                return true
            }
            return false
        case .whisperKit, .deepgram, .sfSpeech:
            return true
        }
    }
}

/// Protocol for pluggable STT backends.
/// Implementations: SFSpeechTranscriptionEngine, SpeechAnalyzerTranscriptionEngine
@MainActor
protocol TranscriptionEngine: AnyObject, ObservableObject {
    /// Current transcription state.
    var state: TranscriptionState { get }

    /// Live partial transcript (updates during speech).
    var partialText: String { get }

    /// Final transcript (set when recognition completes).
    var finalText: String { get }

    /// Start listening for speech.
    /// This is async because SpeechAnalyzer may need to download the language model first.
    func start() async throws

    /// Stop listening and finalize the transcript.
    /// - Parameters:
    ///   - tailNanoseconds: Extra capture time after stop request to catch last words.
    ///   - finalWaitNanoseconds: Time to wait for final result after stopping audio.
    func stopAndFinalize(tailNanoseconds: UInt64, finalWaitNanoseconds: UInt64) async

    /// Reset to idle state, clearing all text.
    func reset()
}

// Default parameter values for stopAndFinalize
extension TranscriptionEngine {
    func stopAndFinalize() async {
        await stopAndFinalize(tailNanoseconds: 180_000_000, finalWaitNanoseconds: 650_000_000)
    }
}
