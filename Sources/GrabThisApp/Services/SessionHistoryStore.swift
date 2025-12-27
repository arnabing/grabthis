import AppKit
import Foundation

/// A single message in a conversation (user question or AI response)
struct ConversationTurn: Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let role: Role
    let content: String
    let timestamp: Date
}

struct SessionRecord: Identifiable, Equatable {
    enum EndReason: String, Codable {
        case completed
        case cancelled
        case interrupted
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date
    var endReason: EndReason

    let appName: String
    let bundleIdentifier: String?
    let targetPID: Int?

    let screenshotPath: String?

    /// All conversation turns (user questions + AI responses)
    var turns: [ConversationTurn]

    // MARK: - Computed Properties for Backward Compatibility

    /// First user message (for list preview)
    var transcript: String {
        turns.first(where: { $0.role == .user })?.content ?? ""
    }

    /// Last AI response (for quick access)
    var aiResponse: String? {
        turns.last(where: { $0.role == .assistant })?.content
    }

    // MARK: - Initialization

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        endReason: EndReason,
        appName: String,
        bundleIdentifier: String?,
        targetPID: Int?,
        transcript: String,
        screenshotPath: String?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.targetPID = targetPID
        self.screenshotPath = screenshotPath

        // Initialize with first user turn if transcript provided
        if !transcript.isEmpty {
            self.turns = [ConversationTurn(role: .user, content: transcript, timestamp: startedAt)]
        } else {
            self.turns = []
        }
    }
}

// MARK: - Codable with Migration Support

extension SessionRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, endReason
        case appName, bundleIdentifier, targetPID
        case screenshotPath, turns
        // Legacy keys for migration
        case transcript, aiResponse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        endReason = try container.decode(EndReason.self, forKey: .endReason)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        targetPID = try container.decodeIfPresent(Int.self, forKey: .targetPID)
        screenshotPath = try container.decodeIfPresent(String.self, forKey: .screenshotPath)

        // Try new format first, then migrate from legacy
        if let decodedTurns = try container.decodeIfPresent([ConversationTurn].self, forKey: .turns) {
            turns = decodedTurns
        } else {
            // Migrate from legacy format
            var migrated: [ConversationTurn] = []
            if let legacyTranscript = try container.decodeIfPresent(String.self, forKey: .transcript),
               !legacyTranscript.isEmpty {
                migrated.append(ConversationTurn(role: .user, content: legacyTranscript, timestamp: startedAt))
            }
            if let legacyResponse = try container.decodeIfPresent(String.self, forKey: .aiResponse),
               !legacyResponse.isEmpty {
                migrated.append(ConversationTurn(role: .assistant, content: legacyResponse, timestamp: endedAt))
            }
            turns = migrated
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(endReason, forKey: .endReason)
        try container.encode(appName, forKey: .appName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(targetPID, forKey: .targetPID)
        try container.encodeIfPresent(screenshotPath, forKey: .screenshotPath)
        try container.encode(turns, forKey: .turns)
    }
}

@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    @Published private(set) var records: [SessionRecord] = []

    /// Keep this small by default; we can make it configurable later.
    private let maxRecords = 50

    private var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("grabthis", isDirectory: true)
    }

    private var screenshotsDir: URL { baseDir.appendingPathComponent("screenshots", isDirectory: true) }
    private var historyFile: URL { baseDir.appendingPathComponent("history.json", isDirectory: false) }

    init() {
        load()
    }

    func add(_ record: SessionRecord) {
        // Newest first.
        records.insert(record, at: 0)
        enforceRetention()
        save()
    }

    func remove(_ id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: idx)
        if let screenshotPath = removed.screenshotPath {
            try? FileManager.default.removeItem(atPath: screenshotPath)
        }
        save()
    }

    func clear() {
        // Best-effort delete screenshot files referenced by history.
        for r in records {
            if let screenshotPath = r.screenshotPath {
                try? FileManager.default.removeItem(atPath: screenshotPath)
            }
        }
        records = []
        save()
    }

    /// Add an AI response turn to an existing session
    func addResponse(sessionId: UUID, response: String) {
        guard let idx = records.firstIndex(where: { $0.id == sessionId }) else { return }
        let turn = ConversationTurn(role: .assistant, content: response, timestamp: Date())
        records[idx].turns.append(turn)
        records[idx].endedAt = Date()
        save()
        let turnCount = records[idx].turns.count
        Log.session.info("history added AI response for id=\(sessionId.uuidString, privacy: .public) totalTurns=\(turnCount)")
    }

    /// Add a user follow-up turn to an existing session
    func addFollowUp(sessionId: UUID, question: String) {
        guard let idx = records.firstIndex(where: { $0.id == sessionId }) else { return }
        let turn = ConversationTurn(role: .user, content: question, timestamp: Date())
        records[idx].turns.append(turn)
        save()
        let turnCount = records[idx].turns.count
        Log.session.info("history added follow-up for id=\(sessionId.uuidString, privacy: .public) totalTurns=\(turnCount)")
    }

    /// Replace all turns for a session (for full conversation updates)
    func updateTurns(sessionId: UUID, turns: [ConversationTurn]) {
        guard let idx = records.firstIndex(where: { $0.id == sessionId }) else { return }
        records[idx].turns = turns
        records[idx].endedAt = Date()
        save()
        Log.session.info("history updated turns for id=\(sessionId.uuidString, privacy: .public) totalTurns=\(turns.count)")
    }

    func saveScreenshotIfNeeded(_ screenshot: ScreenshotCaptureResult?, sessionId: UUID) -> String? {
        guard AppState.shared.saveScreenshotsToHistory else { return nil }
        guard let screenshot else { return nil }

        do {
            try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
            let url = screenshotsDir.appendingPathComponent("\(sessionId.uuidString).png")
            let rep = NSBitmapImageRep(cgImage: screenshot.image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            Log.app.error("history screenshot save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private extension SessionHistoryStore {
    func load() {
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: historyFile.path) else { return }
            let data = try Data(contentsOf: historyFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([SessionRecord].self, from: data)
        } catch {
            Log.app.error("history load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: historyFile, options: .atomic)
        } catch {
            Log.app.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func enforceRetention() {
        guard records.count > maxRecords else { return }
        let kept = records.prefix(maxRecords)
        let removed = records.suffix(records.count - maxRecords)

        for r in removed {
            if let screenshotPath = r.screenshotPath {
                try? FileManager.default.removeItem(atPath: screenshotPath)
            }
        }
        records = Array(kept)
    }
}


