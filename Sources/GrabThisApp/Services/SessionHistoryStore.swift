import AppKit
import Foundation

struct SessionRecord: Codable, Identifiable, Equatable {
    enum EndReason: String, Codable {
        case completed
        case cancelled
        case interrupted
    }

    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let endReason: EndReason

    let appName: String
    let bundleIdentifier: String?
    let targetPID: Int?

    let transcript: String
    let screenshotPath: String?
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


