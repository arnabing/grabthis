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
    private let model = "gemini-2.5-flash"
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Analyze a screenshot with a text prompt using Gemini 2.5 Flash
    func analyze(screenshot: CGImage?, prompt: String) async throws -> String {
        let apiKey = APIKeyManager.shared.getActiveKey()
        guard !apiKey.isEmpty else { throw AIError.noAPIKey }
        guard let screenshot else { throw AIError.noScreenshot }

        // Optimize and encode the screenshot
        let imageData = try optimizeAndEncode(screenshot)
        let base64Image = imageData.base64EncodedString()

        // Build request
        let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 1024,
                "temperature": 0.7
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
