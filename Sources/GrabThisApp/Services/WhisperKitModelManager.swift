import Foundation
import WhisperKit

/// Manages WhisperKit model downloads and lifecycle.
@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    // MARK: - Model Types

    enum Model: String, CaseIterable, Identifiable {
        case largev3Turbo = "openai_whisper-large-v3-turbo"
        case largev3 = "openai_whisper-large-v3"
        case base = "openai_whisper-base"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .largev3Turbo: return "Large V3 Turbo (Recommended)"
            case .largev3: return "Large V3 (Best Accuracy)"
            case .base: return "Base (Fastest)"
            }
        }

        var sizeDescription: String {
            switch self {
            case .largev3Turbo: return "~400MB"
            case .largev3: return "~1.5GB"
            case .base: return "~150MB"
            }
        }

        var sizeBytes: Int64 {
            switch self {
            case .largev3Turbo: return 400_000_000
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
    }

    // MARK: - Public API

    /// Refresh the set of downloaded models by checking disk
    func refreshDownloadedModels() {
        downloadedModels = Set(Model.allCases.filter { isModelDownloaded($0) })
    }

    /// Check if a model is downloaded on disk
    func isModelDownloaded(_ model: Model) -> Bool {
        let modelFolder = modelDirectory(for: model)
        return FileManager.default.fileExists(atPath: modelFolder.path)
    }

    /// Get the parent directory where all WhisperKit models are stored
    func modelStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("grabthis", isDirectory: true)
            .appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// Get the directory for a specific model
    func modelDirectory(for model: Model) -> URL {
        modelStorageDirectory().appendingPathComponent(model.rawValue, isDirectory: true)
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
            Log.stt.info("Starting WhisperKit model download: \(model.displayName)")

            // Create the model storage directory
            let storageDir = modelStorageDirectory()
            try FileManager.default.createDirectory(at: storageDir,
                                                    withIntermediateDirectories: true)

            // WhisperKit handles download automatically when initialized
            // modelFolder is the parent directory where model subdirectories are stored
            let config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: storageDir.path,
                verbose: true,
                prewarm: false,
                download: true
            )

            Log.stt.info("Initializing WhisperKit with modelFolder=\(storageDir.path), model=\(model.rawValue)")
            whisperKit = try await WhisperKit(config)

            downloadedModels.insert(model)
            downloadProgress = 1.0
            Log.stt.info("WhisperKit model downloaded: \(model.displayName)")

        } catch {
            downloadError = error.localizedDescription
            downloadProgress = 0
            Log.stt.error("WhisperKit model download failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Delete a downloaded model
    func deleteModel(_ model: Model) throws {
        let modelDir = modelDirectory(for: model)
        if FileManager.default.fileExists(atPath: modelDir.path) {
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

        // Load the model
        let modelDir = modelDirectory(for: selectedModel)
        let config = WhisperKitConfig(
            model: selectedModel.rawValue,
            modelFolder: modelDir.deletingLastPathComponent().path,
            verbose: false,
            prewarm: true
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        return kit
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
