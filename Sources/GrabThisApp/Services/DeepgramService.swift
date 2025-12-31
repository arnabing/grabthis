import Foundation

/// Deepgram WebSocket API service for real-time speech transcription.
/// Uses Nova-3 model for best accuracy (~4% WER).
actor DeepgramService {
    // MARK: - Configuration

    private static let baseURL = "wss://api.deepgram.com/v1/listen"
    private static let model = "nova-3"

    // MARK: - API Key Management

    private static let apiKeyKey = "deepgramAPIKey"

    static var hasAPIKey: Bool {
        guard let key = UserDefaults.standard.string(forKey: apiKeyKey) else { return false }
        return !key.isEmpty
    }

    static func getAPIKey() -> String? {
        UserDefaults.standard.string(forKey: apiKeyKey)
    }

    static func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: apiKeyKey)
    }

    static func clearAPIKey() {
        UserDefaults.standard.removeObject(forKey: apiKeyKey)
    }

    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var transcriptContinuation: AsyncStream<TranscriptResult>.Continuation?
    private var isConnected = false

    // MARK: - Types

    struct TranscriptResult {
        let text: String
        let isFinal: Bool
        let confidence: Double
    }

    // MARK: - Connection

    /// Connect to Deepgram WebSocket API
    func connect() async throws {
        guard let apiKey = Self.getAPIKey(), !apiKey.isEmpty else {
            throw DeepgramError.noAPIKey
        }

        // Build URL with query parameters
        var components = URLComponents(string: Self.baseURL)!
        components.queryItems = [
            URLQueryItem(name: "model", value: Self.model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]

        guard let url = components.url else {
            throw DeepgramError.invalidURL
        }

        // Create request with auth header
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        // Create WebSocket task
        let session = URLSession(configuration: .default)
        self.urlSession = session

        let task = session.webSocketTask(with: request)
        self.webSocketTask = task

        task.resume()
        isConnected = true

        Log.stt.info("Deepgram WebSocket connected")
    }

    /// Disconnect from Deepgram
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        isConnected = false
        Log.stt.info("Deepgram WebSocket disconnected")
    }

    // MARK: - Audio Streaming

    /// Send audio data to Deepgram
    func send(audioData: Data) async throws {
        guard let task = webSocketTask, isConnected else {
            throw DeepgramError.notConnected
        }

        let message = URLSessionWebSocketTask.Message.data(audioData)
        try await task.send(message)
    }

    /// Signal end of audio stream
    func finishAudio() async throws {
        guard let task = webSocketTask, isConnected else { return }

        // Send empty message to signal end of stream
        let closeMessage: [String: Any] = ["type": "CloseStream"]
        let jsonData = try JSONSerialization.data(withJSONObject: closeMessage)
        let message = URLSessionWebSocketTask.Message.data(jsonData)
        try await task.send(message)
    }

    // MARK: - Receiving Transcripts

    /// Get async stream of transcript results
    func receiveTranscripts() -> AsyncStream<TranscriptResult> {
        AsyncStream { continuation in
            self.transcriptContinuation = continuation

            Task {
                await self.startReceiving()
            }
        }
    }

    private func startReceiving() async {
        guard let task = webSocketTask else { return }

        while isConnected {
            do {
                let message = try await task.receive()

                switch message {
                case .string(let text):
                    if let result = parseTranscriptResponse(text) {
                        transcriptContinuation?.yield(result)
                    }

                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let result = parseTranscriptResponse(text) {
                        transcriptContinuation?.yield(result)
                    }

                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    Log.stt.error("Deepgram receive error: \(error.localizedDescription)")
                }
                break
            }
        }

        transcriptContinuation?.finish()
    }

    private func parseTranscriptResponse(_ json: String) -> TranscriptResult? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = response["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String else {
            return nil
        }

        // Skip empty transcripts
        guard !transcript.isEmpty else { return nil }

        let isFinal = (response["is_final"] as? Bool) ?? false
        let confidence = (firstAlt["confidence"] as? Double) ?? 0.0

        return TranscriptResult(text: transcript, isFinal: isFinal, confidence: confidence)
    }
}

// MARK: - Errors

enum DeepgramError: LocalizedError {
    case noAPIKey
    case invalidURL
    case notConnected
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Deepgram API key not configured. Add it in Settings."
        case .invalidURL:
            return "Failed to build Deepgram API URL"
        case .notConnected:
            return "Not connected to Deepgram"
        case .connectionFailed(let message):
            return "Deepgram connection failed: \(message)"
        }
    }
}
