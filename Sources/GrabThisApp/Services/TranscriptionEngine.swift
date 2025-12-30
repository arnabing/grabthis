import AVFoundation
import Foundation

/// Common state for all transcription engines.
enum TranscriptionState: Equatable {
    case idle
    case listening
    case stopped
    case error(message: String)
}

/// Available STT engine types.
enum TranscriptionEngineType: String, CaseIterable, Identifiable {
    case speechAnalyzer = "apple"
    case sfSpeech = "classic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechAnalyzer: return "Apple (On-Device)"
        case .sfSpeech: return "Classic (Cloud)"
        }
    }

    var description: String {
        switch self {
        case .speechAnalyzer: return "Faster, private, works offline"
        case .sfSpeech: return "Legacy cloud-based recognition"
        }
    }

    /// Returns only engine types available on the current macOS version.
    static var availableCases: [TranscriptionEngineType] {
        var engines: [TranscriptionEngineType] = [.sfSpeech]
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
        case .sfSpeech:
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
