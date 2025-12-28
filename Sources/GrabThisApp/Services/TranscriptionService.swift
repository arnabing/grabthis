import AVFoundation
import Combine
import Foundation

// Shared notifications
extension Notification.Name {
    static let sttEngineChanged = Notification.Name("sttEngineChanged")
    static let continueSession = Notification.Name("continueSession")
}

/// Factory and coordinator for STT engines.
/// Wraps the active engine and publishes its state for UI consumption.
@MainActor
final class TranscriptionService: ObservableObject {
    // Re-export the enum for backward compatibility
    typealias State = TranscriptionState

    @Published private(set) var state: TranscriptionState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""

    /// The currently selected engine type. Change this to switch engines.
    @Published var engineType: TranscriptionEngineType {
        didSet {
            if engineType != oldValue {
                UserDefaults.standard.set(engineType.rawValue, forKey: "sttEngineType")
                recreateEngine()
            }
        }
    }

    private var engine: (any TranscriptionEngine)?
    private var cancellables = Set<AnyCancellable>()
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale

        // Load saved preference or default to SFSpeech (stable, cloud-based)
        // SpeechAnalyzer (on-device) is opt-in due to macOS 26 beta instability
        if let saved = UserDefaults.standard.string(forKey: "sttEngineType"),
           let type = TranscriptionEngineType(rawValue: saved) {
            self.engineType = type
        } else {
            self.engineType = .speechAnalyzer
        }

        recreateEngine()

        // Listen for engine changes from Settings
        NotificationCenter.default.addObserver(
            forName: .sttEngineChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDefaults()
            }
        }
    }

    /// Reload engine type from UserDefaults (called when settings change)
    func reloadFromDefaults() {
        if let saved = UserDefaults.standard.string(forKey: "sttEngineType"),
           let type = TranscriptionEngineType(rawValue: saved),
           type != engineType {
            Log.stt.notice("🔄 Engine changed via Settings: \(type.displayName)")
            engineType = type
        }
    }

    func start() async throws {
        guard let engine else {
            Log.stt.error("No transcription engine available")
            state = .error(message: "Transcription engine not initialized")
            return
        }
        try await engine.start()
    }

    func stopAndFinalize(tailNanoseconds: UInt64 = 180_000_000, finalWaitNanoseconds: UInt64 = 650_000_000) async {
        await engine?.stopAndFinalize(tailNanoseconds: tailNanoseconds, finalWaitNanoseconds: finalWaitNanoseconds)
    }

    func reset() {
        engine?.reset()
    }

    /// Check if the SpeechAnalyzer model is available for the current locale.
    func isSpeechAnalyzerModelAvailable() async -> Bool {
        await SpeechAnalyzerTranscriptionEngine.isModelAvailable(for: locale)
    }

    /// Download the SpeechAnalyzer model for the current locale.
    func downloadSpeechAnalyzerModel() async throws {
        try await SpeechAnalyzerTranscriptionEngine.downloadModel(for: locale)
    }

    /// Get download progress stream for the SpeechAnalyzer model.
    func speechAnalyzerModelDownloadProgress() -> AsyncStream<Double> {
        SpeechAnalyzerTranscriptionEngine.downloadProgress(for: locale)
    }

    private func recreateEngine() {
        // Cancel existing subscriptions
        cancellables.removeAll()

        // Reset state
        state = .idle
        partialText = ""
        finalText = ""

        // Create engine based on type
        switch engineType {
        case .speechAnalyzer:
            let speechAnalyzerEngine = SpeechAnalyzerTranscriptionEngine(locale: locale)
            bindEngine(speechAnalyzerEngine)
            engine = speechAnalyzerEngine
            Log.stt.notice("🎤 ENGINE ACTIVE: SpeechAnalyzer (on-device, fast)")

        case .sfSpeech:
            let sfEngine = SFSpeechTranscriptionEngine(locale: locale)
            bindEngine(sfEngine)
            engine = sfEngine
            Log.stt.notice("🎤 ENGINE ACTIVE: SFSpeech (cloud-based)")
        }
    }

    private func bindEngine<E: TranscriptionEngine>(_ engine: E) {
        // Note: objectWillChange fires BEFORE properties change.
        // We use a slight delay to sync AFTER the actual property change.
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Delay slightly so we read the NEW values, not the old ones
                DispatchQueue.main.async {
                    self?.syncFromEngine(engine)
                }
            }
            .store(in: &cancellables)

        // Initial sync
        syncFromEngine(engine)
    }

    private func syncFromEngine<E: TranscriptionEngine>(_ engine: E) {
        self.state = engine.state
        self.partialText = engine.partialText
        self.finalText = engine.finalText

        // Debug log to verify values are syncing correctly
        if !finalText.isEmpty || !partialText.isEmpty {
            Log.stt.debug("🔄 sync: state=\(String(describing: self.state)) partial=\(self.partialText.prefix(30))... final=\(self.finalText.prefix(30))...")
        }
    }
}
