//
//  NowPlayingService.swift
//  GrabThisApp
//
//  Now Playing media controls using MediaRemoteAdapter.
//  Based on boring.notch's implementation - spawns a Perl process
//  that streams JSON updates for reliable media detection.
//

import AppKit
import Combine
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.grabthis.app", category: "NowPlaying")

// Simple file-based debug logging
private func debugLog(_ message: String) {
    let logPath = "/tmp/grabthis_debug.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] NowPlayingService: \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    // MARK: - Settings
    @AppStorage("nowPlayingEnabled") var isEnabled: Bool = true

    // MARK: - Published State
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""

    // MARK: - Song Change Detection (for sneak peek on new song)
    private var lastPeekTitle: String = ""
    private var lastPeekArtist: String = ""
    @Published private(set) var albumArt: NSImage?
    @Published private(set) var dominantColor: NSColor = .white
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var hasActivePlayer: Bool = false
    @Published private(set) var bundleIdentifier: String = ""
    @Published private(set) var isShuffled: Bool = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isFavorite: Bool = false
    @Published private(set) var playbackRate: Double = 1.0
    @Published private(set) var lastUpdated: Date = Date()

    // MARK: - MediaRemote Function Pointers (for sending commands)
    private var MRMediaRemoteSendCommandFunction: (@convention(c) (Int, AnyObject?) -> Void)?
    private var MRMediaRemoteSetElapsedTimeFunction: (@convention(c) (Double) -> Void)?
    private var MRMediaRemoteSetShuffleModeFunction: (@convention(c) (Int) -> Void)?
    private var MRMediaRemoteSetRepeatModeFunction: (@convention(c) (Int) -> Void)?

    private var mediaRemoteBundle: CFBundle?

    // MARK: - Process-based Streaming (boring.notch approach)
    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    private init() {
        print("🎵 NowPlayingService initializing...")
        logger.info("Initializing NowPlayingService (process-based streaming)...")
        loadMediaRemoteFramework()
        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()

        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close() }
        }

        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - MediaRemote Framework Loading (for commands only)
    private func loadMediaRemoteFramework() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else {
            logger.error("Failed to load MediaRemote.framework")
            return
        }

        mediaRemoteBundle = bundle

        // Load function pointers for sending commands
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            MRMediaRemoteSendCommandFunction = unsafeBitCast(ptr, to: (@convention(c) (Int, AnyObject?) -> Void).self)
            logger.info("Loaded MRMediaRemoteSendCommand")
        } else {
            logger.error("Failed to load MRMediaRemoteSendCommand")
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetElapsedTime" as CFString) {
            MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(ptr, to: (@convention(c) (Double) -> Void).self)
            logger.info("Loaded MRMediaRemoteSetElapsedTime")
        } else {
            logger.error("Failed to load MRMediaRemoteSetElapsedTime")
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetShuffleMode" as CFString) {
            MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(ptr, to: (@convention(c) (Int) -> Void).self)
            logger.info("Loaded MRMediaRemoteSetShuffleMode")
        } else {
            logger.error("Failed to load MRMediaRemoteSetShuffleMode")
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetRepeatMode" as CFString) {
            MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(ptr, to: (@convention(c) (Int) -> Void).self)
            logger.info("Loaded MRMediaRemoteSetRepeatMode")
        } else {
            logger.error("Failed to load MRMediaRemoteSetRepeatMode")
        }

        print("🎵 MediaRemote framework loaded - SendCommand: \(MRMediaRemoteSendCommandFunction != nil)")
        logger.info("MediaRemote framework loaded")
    }

    // MARK: - Setup Process-based Observer
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/PrivateFrameworks/MediaRemoteAdapter.framework")
        else {
            logger.error("Could not find mediaremote-adapter.pl script or framework path")
            logger.error("scriptURL exists: \(Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") != nil)")
            logger.error("privateFrameworksPath: \(Bundle.main.privateFrameworksPath ?? "nil")")
            return
        }

        logger.info("Setting up process: perl \(scriptURL.path) \(frameworkPath) stream")

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()

        // Capture stderr for debugging
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                logger.warning("mediaremote-adapter stderr: \(str)")
            }
        }

        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            logger.info("mediaremote-adapter process started successfully")
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            logger.error("Failed to launch mediaremote-adapter.pl: \(error.localizedDescription)")
        }
    }

    // MARK: - Async Stream Processing
    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }

        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    // MARK: - Handle Update from Adapter
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        let oldHasActivePlayer = hasActivePlayer
        let oldIsPlaying = isPlaying

        // Update title
        if let newTitle = payload.title {
            title = newTitle
        } else if !diff {
            title = ""
        }

        // Update artist
        if let newArtist = payload.artist {
            artist = newArtist
        } else if !diff {
            artist = ""
        }

        // Update album
        if let newAlbum = payload.album {
            album = newAlbum
        } else if !diff {
            album = ""
        }

        // Update duration
        if let newDuration = payload.duration {
            duration = newDuration
        } else if !diff {
            duration = 0
        }

        // Update elapsed time - store actual value and timestamp
        // Views use estimatedPlaybackPosition(at:) for real-time interpolation
        if let newElapsedTime = payload.elapsedTime {
            elapsedTime = newElapsedTime
            lastUpdated = Date()  // Mark when we got this value
        } else if !diff {
            // Full update without elapsed time means reset
            elapsedTime = 0
            lastUpdated = Date()
        }

        // Update shuffle mode
        if let shuffleMode = payload.shuffleMode {
            isShuffled = shuffleMode != 1
        } else if !diff {
            isShuffled = false
        }

        // Update repeat mode
        if let repeatModeValue = payload.repeatMode {
            repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            repeatMode = .off
        }

        // Update artwork
        if let artworkDataString = payload.artworkData {
            if let artworkData = Data(base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)),
               let image = NSImage(data: artworkData) {
                albumArt = image
                extractDominantColor(from: image)
            }
        } else if !diff {
            albumArt = nil
        }

        // Update timestamp
        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            lastUpdated = date
        } else if !diff {
            lastUpdated = Date()
        }

        // Update playback rate and playing state
        if let newRate = payload.playbackRate {
            playbackRate = newRate
        } else if !diff {
            playbackRate = 1.0
        }

        if let newPlaying = payload.playing {
            isPlaying = newPlaying
        } else if !diff {
            isPlaying = false
        }

        // Update bundle identifier
        if let parentBundle = payload.parentApplicationBundleIdentifier {
            bundleIdentifier = parentBundle
        } else if let bundle = payload.bundleIdentifier {
            bundleIdentifier = bundle
        } else if !diff {
            bundleIdentifier = ""
        }

        // Update hasActivePlayer
        hasActivePlayer = !title.isEmpty

        // Log the update
        if hasActivePlayer {
            logger.debug("Now playing: '\(self.title)' by \(self.artist) [\(self.bundleIdentifier)], playing=\(self.isPlaying)")
        }

        // POST notification if hasActivePlayer or isPlaying changed
        // This is critical for NotchCoordinator to switch pages
        if hasActivePlayer != oldHasActivePlayer || isPlaying != oldIsPlaying {
            print("🎵 NowPlayingService: Posting .nowPlayingDidChange (hasActivePlayer: \(oldHasActivePlayer)->\(self.hasActivePlayer), isPlaying: \(oldIsPlaying)->\(self.isPlaying), title: '\(self.title)')")
            logger.info("Posting .nowPlayingDidChange notification (hasActivePlayer: \(oldHasActivePlayer)->\(self.hasActivePlayer), isPlaying: \(oldIsPlaying)->\(self.isPlaying))")
            NotificationCenter.default.post(name: .nowPlayingDidChange, object: nil)
        }

        // SONG CHANGE DETECTION - Trigger sneak peek on new song (boring.notch style)
        // Only trigger if we're playing and the song actually changed
        let songChanged = (title != lastPeekTitle || artist != lastPeekArtist) && !title.isEmpty
        if songChanged && isPlaying {
            print("🎵 NowPlayingService: Song changed! '\(lastPeekTitle)' -> '\(title)' - posting .songDidChange")
            logger.info("Song changed: '\(self.lastPeekTitle)' -> '\(self.title)' by \(self.artist)")
            NotificationCenter.default.post(name: .songDidChange, object: nil)
        }

        // Always update last peek values when we have valid data
        if !title.isEmpty {
            lastPeekTitle = title
            lastPeekArtist = artist
        }
    }

    // MARK: - Color Extraction
    private func extractDominantColor(from image: NSImage) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            let width = 10
            let height = 10
            let bytesPerPixel = 4
            let bytesPerRow = bytesPerPixel * width
            let bitsPerComponent = 8

            var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            guard let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            var totalR: CGFloat = 0
            var totalG: CGFloat = 0
            var totalB: CGFloat = 0
            let pixelCount = width * height

            for i in 0..<pixelCount {
                let offset = i * bytesPerPixel
                totalR += CGFloat(pixelData[offset])
                totalG += CGFloat(pixelData[offset + 1])
                totalB += CGFloat(pixelData[offset + 2])
            }

            let avgR = totalR / CGFloat(pixelCount) / 255.0
            let avgG = totalG / CGFloat(pixelCount) / 255.0
            let avgB = totalB / CGFloat(pixelCount) / 255.0

            let color = NSColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)

            DispatchQueue.main.async {
                self?.dominantColor = color
            }
        }
    }

    // MARK: - Playback Controls

    /// Command codes: 0=Play, 1=Pause, 2=Toggle, 4=Next, 5=Previous
    func togglePlayPause() {
        debugLog("togglePlayPause called")
        logger.info("togglePlayPause called")
        MRMediaRemoteSendCommandFunction?(2, nil)
        debugLog("togglePlayPause command sent")
    }

    func play() {
        logger.info("play called")
        MRMediaRemoteSendCommandFunction?(0, nil)
    }

    func pause() {
        logger.info("pause called")
        MRMediaRemoteSendCommandFunction?(1, nil)
    }

    /// Play with a gentle volume fade-in (prevents jarring audio after Bluetooth codec switch)
    /// Fades from 20% to original volume over ~1 second
    func playWithFadeIn() {
        logger.info("playWithFadeIn called")

        Task { @MainActor in
            // Get current system volume
            let originalVolume = Self.getSystemVolume()
            logger.info("Original volume: \(originalVolume)")

            // Set volume low to start
            Self.setSystemVolume(Int(Double(originalVolume) * 0.2))

            // Start playback
            play()

            // Fade in over 1 second (5 steps, 200ms each)
            let steps = 5
            let stepDelay: UInt64 = 200_000_000  // 200ms

            for i in 1...steps {
                try? await Task.sleep(nanoseconds: stepDelay)
                let progress = Double(i) / Double(steps)
                let targetVolume = Int(Double(originalVolume) * (0.2 + 0.8 * progress))
                Self.setSystemVolume(targetVolume)
            }

            logger.info("Fade-in complete, volume restored to \(originalVolume)")
        }
    }

    /// Get system output volume (0-100)
    private static func getSystemVolume() -> Int {
        let script = "output volume of (get volume settings)"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return Int(result.int32Value)
            }
        }
        return 50  // Default if unable to get
    }

    /// Set system output volume (0-100)
    private static func setSystemVolume(_ volume: Int) {
        let clampedVolume = max(0, min(100, volume))
        let script = "set volume output volume \(clampedVolume)"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func nextTrack() {
        debugLog("nextTrack called")
        logger.info("nextTrack called")
        if MRMediaRemoteSendCommandFunction == nil {
            debugLog("ERROR: MRMediaRemoteSendCommandFunction is nil!")
            logger.error("MRMediaRemoteSendCommandFunction is nil!")
        } else {
            debugLog("Sending next track command (4)")
            MRMediaRemoteSendCommandFunction?(4, nil)
            debugLog("nextTrack command sent")
        }
    }

    func previousTrack() {
        debugLog("previousTrack called")
        logger.info("previousTrack called")
        if MRMediaRemoteSendCommandFunction == nil {
            debugLog("ERROR: MRMediaRemoteSendCommandFunction is nil!")
            logger.error("MRMediaRemoteSendCommandFunction is nil!")
        } else {
            debugLog("Sending previous track command (5)")
            MRMediaRemoteSendCommandFunction?(5, nil)
            debugLog("previousTrack command sent")
        }
    }

    func seek(to time: TimeInterval) {
        logger.info("seek called to \(time)")
        MRMediaRemoteSetElapsedTimeFunction?(time)
        elapsedTime = time
        lastUpdated = Date()
    }

    func toggleShuffle() {
        // Toggle between shuffle off (1) and shuffle on (3)
        let newMode = isShuffled ? 1 : 3
        MRMediaRemoteSetShuffleModeFunction?(newMode)
        isShuffled.toggle()
    }

    func toggleRepeat() {
        // Cycle: off (1) -> all (3) -> one (2) -> off (1)
        let newMode: Int
        switch repeatMode {
        case .off: newMode = 3
        case .all: newMode = 2
        case .one: newMode = 1
        }
        MRMediaRemoteSetRepeatModeFunction?(newMode)
        repeatMode = RepeatMode(rawValue: newMode) ?? .off
    }

    func toggleFavorite() {
        // Toggle favorite using AppleScript (Apple Music only)
        guard bundleIdentifier == "com.apple.Music" else { return }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let newFavoriteState = !isFavorite
        let script = """
        tell application "Music"
            try
                set favorited of current track to \(newFavoriteState ? "true" : "false")
            end try
        end tell
        """

        Task {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error == nil {
                    await MainActor.run {
                        self.isFavorite = newFavoriteState
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    /// Whether favorite/love can be toggled (Apple Music only)
    var canFavorite: Bool {
        bundleIdentifier == "com.apple.Music" &&
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return elapsedTime / duration
    }

    var formattedElapsedTime: String {
        formatTime(elapsedTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Estimated playback position accounting for time since last update
    func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, duration) }
        let timeDifference = date.timeIntervalSince(lastUpdated)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), duration)
    }
}

// MARK: - JSON Parsing Types

struct NowPlayingUpdate: Codable, Sendable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

// MARK: - JSON Lines Pipe Handler

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""

    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }

    func getPipe() -> Pipe {
        return pipe
    }

    func readJSONLines<T: Decodable & Sendable>(as type: T.Type, onLine: @escaping @Sendable (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }

    private func processLines<T: Decodable & Sendable>(as type: T.Type, onLine: @escaping @Sendable (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }

            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)

                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])

                    if !line.isEmpty {
                        await processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }

    private func processJSONLine<T: Decodable & Sendable>(_ line: String, as type: T.Type, onLine: @escaping @Sendable (T) async -> Void) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }

    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in

            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }

    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}
