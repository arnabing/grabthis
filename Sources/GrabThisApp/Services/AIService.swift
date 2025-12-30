import AppKit
import Foundation

@MainActor
final class AIService {
    enum AIError: Error, LocalizedError {
        case noAPIKey
        case noScreenshot
        case networkError(String)
        case invalidResponse(String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key configured"
            case .noScreenshot: return "No screenshot available"
            case .networkError(let msg): return "Network error: \(msg)"
            case .invalidResponse(let msg): return "Invalid response: \(msg)"
            case .rateLimited: return "Rate limited - try again in a moment"
            }
        }
    }

    private let session: URLSession
    private let model = "gemini-3-flash-preview"
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Analyze a screenshot with a text prompt using Gemini 3 Flash
    func analyze(screenshot: CGImage?, prompt: String) async throws -> String {
        // For single-turn, just use the new method with empty history
        return try await analyzeWithHistory(
            screenshot: screenshot,
            prompt: prompt,
            conversationHistory: []
        )
    }

    /// Analyze with full conversation history for multi-turn support (streaming)
    func analyzeWithHistoryStreaming(
        screenshot: CGImage?,
        prompt: String,
        conversationHistory: [ConversationTurn],
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let apiKey = APIKeyManager.shared.getActiveKey()
        guard !apiKey.isEmpty else { throw AIError.noAPIKey }

        // Optimize and encode the screenshot (optional)
        let base64Image: String?
        if let screenshot {
            let imageData = try optimizeAndEncode(screenshot)
            base64Image = imageData.base64EncodedString()
        } else {
            base64Image = nil
        }

        // Build streaming request (different endpoint)
        let url = URL(string: "\(baseURL)/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build contents array with conversation history
        let contents = buildContents(
            prompt: prompt,
            base64Image: base64Image,
            conversationHistory: conversationHistory
        )

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.7
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.app.info("AI streaming request: historyTurns=\(conversationHistory.count) promptLen=\(prompt.count)")

        // Make streaming request
        let (bytes, response) = try await session.bytes(for: request)

        // Check HTTP status
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200: break
            case 429: throw AIError.rateLimited
            case 400...499:
                throw AIError.invalidResponse("HTTP \(httpResponse.statusCode)")
            case 500...599:
                throw AIError.networkError("Server error \(httpResponse.statusCode)")
            default:
                throw AIError.networkError("HTTP \(httpResponse.statusCode)")
            }
        }

        // Parse SSE stream
        var fullText = ""
        var lineCount = 0
        for try await line in bytes.lines {
            lineCount += 1
            Log.app.debug("SSE line \(lineCount): \(line.prefix(100))")

            // SSE format: "data: {json}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            if let data = jsonString.data(using: .utf8) {
                do {
                    let chunk = try parseStreamChunk(data)
                    if !chunk.isEmpty {
                        fullText += chunk
                        Log.app.debug("SSE chunk parsed: \(chunk.prefix(50))... total=\(fullText.count)")
                        // Call onChunk directly - we're already on MainActor
                        onChunk(fullText)
                    }
                } catch {
                    Log.app.error("SSE parse error: \(error.localizedDescription)")
                }
            }
        }

        Log.app.info("AI streaming complete: \(lineCount) lines, \(fullText.count) chars")
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Analyze with full conversation history for multi-turn support (non-streaming fallback)
    func analyzeWithHistory(
        screenshot: CGImage?,
        prompt: String,
        conversationHistory: [ConversationTurn]
    ) async throws -> String {
        let apiKey = APIKeyManager.shared.getActiveKey()
        guard !apiKey.isEmpty else { throw AIError.noAPIKey }

        // Optimize and encode the screenshot (optional)
        let base64Image: String?
        if let screenshot {
            let imageData = try optimizeAndEncode(screenshot)
            base64Image = imageData.base64EncodedString()
        } else {
            base64Image = nil
        }

        // Build request
        let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build contents array with conversation history
        let contents = buildContents(
            prompt: prompt,
            base64Image: base64Image,
            conversationHistory: conversationHistory
        )

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.7
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.app.info("AI request: historyTurns=\(conversationHistory.count) promptLen=\(prompt.count)")

        // Make request
        let (data, response) = try await session.data(for: request)

        // Check HTTP status
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200: break
            case 429: throw AIError.rateLimited
            case 400...499:
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.invalidResponse("HTTP \(httpResponse.statusCode): \(errorMsg)")
            case 500...599:
                throw AIError.networkError("Server error \(httpResponse.statusCode)")
            default:
                throw AIError.networkError("HTTP \(httpResponse.statusCode)")
            }
        }

        // Parse response
        return try parseResponse(data)
    }

    /// Build contents array for Gemini API
    private func buildContents(
        prompt: String,
        base64Image: String?,
        conversationHistory: [ConversationTurn]
    ) -> [[String: Any]] {
        var contents: [[String: Any]] = []

        // For multi-turn: include previous turns, with screenshot only in first user message
        if !conversationHistory.isEmpty {
            var isFirstUserMessage = true

            for turn in conversationHistory {
                let role = turn.role == .user ? "user" : "model"
                var parts: [[String: Any]] = [["text": turn.content]]

                // Include screenshot only in the first user message (if available)
                if turn.role == .user && isFirstUserMessage, let imageData = base64Image {
                    parts.append([
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": imageData
                        ]
                    ])
                    isFirstUserMessage = false
                } else if turn.role == .user && isFirstUserMessage {
                    isFirstUserMessage = false  // Mark as seen even without image
                }

                contents.append([
                    "role": role,
                    "parts": parts
                ])
            }

            // Add the current prompt as the final user message
            contents.append([
                "role": "user",
                "parts": [["text": prompt]]
            ])
        } else {
            // Single-turn: prompt with optional screenshot
            var parts: [[String: Any]] = [["text": prompt]]
            if let imageData = base64Image {
                parts.append([
                    "inline_data": [
                        "mime_type": "image/jpeg",
                        "data": imageData
                    ]
                ])
            }
            contents = [["parts": parts]]
        }

        return contents
    }

    /// Parse a single SSE chunk from streaming response
    private func parseStreamChunk(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            Log.app.debug("SSE chunk not JSON: \(raw.prefix(100))")
            return ""
        }

        // Check for error
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIError.invalidResponse(message)
        }

        // Extract text from chunk
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            // Log the structure to debug
            Log.app.debug("SSE chunk missing expected structure: \(String(describing: json).prefix(200))")
            return ""
        }

        return text
    }

    /// Optimize screenshot: resize if needed, convert to JPEG
    private func optimizeAndEncode(_ image: CGImage) throws -> Data {
        let maxDimension: CGFloat = 3072  // Gemini's max resolution
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // Calculate scale if needed
        var scale: CGFloat = 1.0
        if width > maxDimension || height > maxDimension {
            scale = min(maxDimension / width, maxDimension / height)
        }

        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)

        // Create resized image if needed
        let finalImage: CGImage
        if scale < 1.0 {
            guard let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw AIError.invalidResponse("Failed to create graphics context")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            guard let resized = context.makeImage() else {
                throw AIError.invalidResponse("Failed to resize image")
            }
            finalImage = resized
        } else {
            finalImage = image
        }

        // Convert to JPEG with 80% quality
        let bitmap = NSBitmapImageRep(cgImage: finalImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw AIError.invalidResponse("Failed to encode JPEG")
        }

        Log.app.info("AI screenshot optimized: \(image.width)x\(image.height) -> \(newWidth)x\(newHeight), \(jpegData.count / 1024)KB")
        return jpegData
    }

    /// Parse Gemini API response
    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Failed to parse JSON")
        }

        // Check for error
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIError.invalidResponse(message)
        }

        // Extract response text
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw AIError.invalidResponse("Unexpected response structure")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
