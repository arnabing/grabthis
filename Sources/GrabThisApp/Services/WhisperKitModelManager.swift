import Foundation
import WhisperKit

/// Manages WhisperKit model downloads and lifecycle.
@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    // MARK: - Model Types

    enum Model: String, CaseIterable, Identifiable {
        // WhisperKit model variant names - these must match the Hugging Face repo exactly
        // The turbo models use underscore (large-v3_turbo), not hyphen (large-v3-turbo)
        case largev3Turbo = "large-v3_turbo"
        case largev3 = "large-v3"
        case base = "base"

        var id: String { rawValue }

        /// The full folder name as stored in Hugging Face cache
        var folderName: String {
            "openai_whisper-\(rawValue)"
        }

        var displayName: String {
            switch self {
            case .largev3Turbo: return "Large V3 Turbo (Recommended)"
            case .largev3: return "Large V3 (Best Accuracy)"
            case .base: return "Base (Fastest)"
            }
        }

        var sizeDescription: String {
            switch self {
            case .largev3Turbo: return "~950MB"
            case .largev3: return "~1.5GB"
            case .base: return "~150MB"
            }
        }

        var sizeBytes: Int64 {
            switch self {
            case .largev3Turbo: return 954_000_000
            case .largev3: return 1_500_000_000
            case .base: return 150_000_000
            }
        }
    }

    // MARK: - Published State

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadedModels: Set<Model> = []
    @Published var selectedModel: Model = .largev3Turbo {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Keys.selectedModel)
        }
    }
    @Published var downloadError: String?

    // MARK: - Private State

    private var whisperKit: WhisperKit?

    // MARK: - Keys

    private enum Keys {
        static let selectedModel = "whisperKitSelectedModel"
    }

    // MARK: - Init

    private init() {
        // Load saved model preference
        if let saved = UserDefaults.standard.string(forKey: Keys.selectedModel),
           let model = Model(rawValue: saved) {
            selectedModel = model
        }

        // Check which models are already downloaded
        refreshDownloadedModels()
        Log.stt.info("WhisperKit initialized: downloaded=\(self.downloadedModels.map { $0.rawValue }), selected=\(self.selectedModel.rawValue)")
    }

    // MARK: - Public API

    /// Refresh the set of downloaded models by checking disk
    func refreshDownloadedModels() {
        downloadedModels = Set(Model.allCases.filter { isModelDownloaded($0) })
    }

    /// Check if a model is downloaded on disk (checks WhisperKit's default cache)
    func isModelDownloaded(_ model: Model) -> Bool {
        // WhisperKit/Hub stores models in ~/Documents/huggingface/models/
        // Check the model-specific folder using the full folder name
        let modelPath = whisperKitCacheDirectory()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.folderName)

        // Check if the model directory exists and has actual model files
        let audioEncoderPath = modelPath.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: audioEncoderPath.path)
    }

    /// WhisperKit's default cache directory (Documents/huggingface per Hub package)
    func whisperKitCacheDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Get the directory for a specific model (in WhisperKit's cache)
    func modelDirectory(for model: Model) -> URL? {
        let modelPath = whisperKitCacheDirectory()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.folderName)

        if FileManager.default.fileExists(atPath: modelPath.path) {
            return modelPath
        }
        return nil
    }

    /// Download a model
    func downloadModel(_ model: Model) async throws {
        guard !isDownloading else {
            Log.stt.warning("Download already in progress")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        Log.stt.info("Starting WhisperKit model download: \(model.displayName)")

        // Start a simulated progress animation (WhisperKit doesn't expose download progress)
        let progressTask = Task { @MainActor in
            while !Task.isCancelled && self.downloadProgress < 0.9 {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
                if !Task.isCancelled && self.isDownloading {
                    // Slow asymptotic progress towards 90%
                    self.downloadProgress += (0.9 - self.downloadProgress) * 0.15
                }
            }
        }

        defer {
            progressTask.cancel()
            isDownloading = false
        }

        do {
            // DON'T provide modelFolder - this triggers WhisperKit to download from HuggingFace
            // Models are cached in ~/Documents/huggingface/models/
            let config = WhisperKitConfig(
                model: model.rawValue,
                verbose: true,
                prewarm: false,
                download: true
            )

            whisperKit = try await WhisperKit(config)

            downloadedModels.insert(model)
            downloadProgress = 1.0
            Log.stt.info("WhisperKit model downloaded: \(model.displayName)")

        } catch {
            let errorDetail = String(describing: error)
            downloadError = errorDetail
            downloadProgress = 0
            Log.stt.error("WhisperKit model download failed for '\(model.rawValue)': \(errorDetail)")
            throw error
        }
    }

    /// Delete a downloaded model
    func deleteModel(_ model: Model) throws {
        if let modelDir = modelDirectory(for: model) {
            try FileManager.default.removeItem(at: modelDir)
            downloadedModels.remove(model)
            Log.stt.info("WhisperKit model deleted: \(model.displayName)")
        }

        // If we deleted the currently loaded model, clear the instance
        if selectedModel == model {
            whisperKit = nil
        }
    }

    /// Get or load the WhisperKit instance for transcription
    func getWhisperKit() async throws -> WhisperKit {
        // Return existing instance if available and matches selected model
        if let existing = whisperKit {
            return existing
        }

        // Check if model is downloaded
        guard isModelDownloaded(selectedModel) else {
            throw WhisperKitError.modelNotDownloaded
        }

        // Get the model folder path where the model is cached
        guard let modelFolder = modelDirectory(for: selectedModel) else {
            Log.stt.error("Model directory not found for \(self.selectedModel.rawValue)")
            throw WhisperKitError.modelNotDownloaded
        }

        Log.stt.info("Loading WhisperKit model from: \(modelFolder.path)")

        // Load the model from the explicit folder path
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            download: false  // Don't re-download, just load from cache
        )

        do {
            let kit = try await WhisperKit(config)
            whisperKit = kit
            Log.stt.info("WhisperKit model loaded successfully")
            return kit
        } catch {
            Log.stt.error("WhisperKit model load failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Unload the current WhisperKit instance to free memory
    func unloadModel() {
        whisperKit = nil
        Log.stt.info("WhisperKit model unloaded")
    }
}

// MARK: - Errors

enum WhisperKitError: LocalizedError {
    case modelNotDownloaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "WhisperKit model not downloaded. Please download it in Settings."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}
