//
//  NowPlayingService.swift
//  GrabThisApp
//
//  Now Playing media controls using MediaRemote.framework
//  Based on boring.notch's implementation
//

import AppKit
import Combine
import Foundation
import SwiftUI

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

    // MARK: - MediaRemote Function Pointers
    private var MRMediaRemoteSendCommandFunction: (@convention(c) (Int, AnyObject?) -> Void)?
    private var MRMediaRemoteSetElapsedTimeFunction: (@convention(c) (Double) -> Void)?
    private var MRMediaRemoteSetShuffleModeFunction: (@convention(c) (Int) -> Void)?
    private var MRMediaRemoteSetRepeatModeFunction: (@convention(c) (Int) -> Void)?
    private var MRMediaRemoteGetNowPlayingInfoFunction: (@convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void)?
    private var MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void)?

    private var mediaRemoteBundle: CFBundle?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var notificationTask: Task<Void, Never>?
    private var spotifyNotificationTask: Task<Void, Never>?

    // MARK: - Initialization
    private init() {
        print("NowPlayingService: Initializing...")
        loadMediaRemoteFramework()
        setupNotificationObservers()
        startPeriodicUpdates()
        print("NowPlayingService: Initialization complete. isEnabled=\(isEnabled)")
    }

    // Timer cleanup happens automatically when the service is deallocated

    // MARK: - MediaRemote Framework Loading
    private func loadMediaRemoteFramework() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else {
            print("NowPlayingService: Failed to load MediaRemote.framework")
            return
        }

        mediaRemoteBundle = bundle

        // Load function pointers
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            MRMediaRemoteSendCommandFunction = unsafeBitCast(ptr, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetElapsedTime" as CFString) {
            MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(ptr, to: (@convention(c) (Double) -> Void).self)
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetShuffleMode" as CFString) {
            MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(ptr, to: (@convention(c) (Int) -> Void).self)
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetRepeatMode" as CFString) {
            MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(ptr, to: (@convention(c) (Int) -> Void).self)
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            MRMediaRemoteGetNowPlayingInfoFunction = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void).self)
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void).self)
        }

        print("NowPlayingService: MediaRemote framework loaded successfully")
    }

    // MARK: - Notification Observers (boring.notch async pattern)
    private func setupNotificationObservers() {
        // Apple Music - async notification stream (boring.notch pattern)
        notificationTask = Task { @MainActor [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )
            for await _ in notifications {
                print("🎵 Apple Music notification received")
                await self?.pollNowPlayingViaAppleScript()
            }
        }

        // Spotify - async notification stream
        spotifyNotificationTask = Task { @MainActor [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                print("🎵 Spotify notification received")
                await self?.pollNowPlayingViaAppleScript()
            }
        }

        print("🎵 NowPlayingService: Notification observers set up (async pattern)")
    }

    private func startPeriodicUpdates() {
        // Poll for now playing info every 2 seconds (reliable fallback)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Update elapsed time if playing
                if self.isPlaying {
                    let timeSinceUpdate = Date().timeIntervalSince(self.lastUpdated)
                    self.elapsedTime = min(self.elapsedTime + (timeSinceUpdate * self.playbackRate), self.duration)
                    self.lastUpdated = Date()
                }
                // Poll for updates via AppleScript (reliable)
                await self.pollNowPlayingViaAppleScript()
            }
        }

        // Initial fetch
        updateNowPlayingInfo()
        Task {
            await pollNowPlayingViaAppleScript()
        }
    }

    // MARK: - AppleScript-based polling (reliable fallback)
    private func pollNowPlayingViaAppleScript() async {
        // Check Apple Music first
        let musicApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        if !musicApps.isEmpty {
            await fetchAppleMusicInfo()
            return
        }

        // Check Spotify
        let spotifyApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
        if !spotifyApps.isEmpty {
            await fetchSpotifyInfo()
            return
        }

        // No music app running
        hasActivePlayer = false
    }

    private func fetchAppleMusicInfo() async {
        let script = """
        tell application "Music"
            if it is running then
                try
                    set playerState to player state as string
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    return playerState & "|" & trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
                on error
                    return "stopped|||||"
                end try
            else
                return "stopped|||||"
            end if
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error == nil, let output = result.stringValue {
                let parts = output.components(separatedBy: "|")
                if parts.count >= 6 {
                    let state = parts[0]
                    isPlaying = state == "playing"
                    title = parts[1]
                    artist = parts[2]
                    album = parts[3]
                    duration = Double(parts[4]) ?? 0
                    elapsedTime = Double(parts[5]) ?? 0
                    bundleIdentifier = "com.apple.Music"
                    hasActivePlayer = !title.isEmpty
                    lastUpdated = Date()
                    print("🎵 Apple Music: '\(title)' by \(artist), playing=\(isPlaying), active=\(hasActivePlayer)")
                }
            } else if let error = error {
                print("🎵 Apple Music AppleScript error: \(error)")
            }
        }
    }

    private func fetchSpotifyInfo() async {
        let script = """
        tell application "Spotify"
            if it is running then
                try
                    set playerState to player state as string
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to (duration of current track) / 1000
                    set trackPosition to player position
                    return playerState & "|" & trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
                on error
                    return "stopped|||||"
                end try
            else
                return "stopped|||||"
            end if
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error == nil, let output = result.stringValue {
                let parts = output.components(separatedBy: "|")
                if parts.count >= 6 {
                    let state = parts[0]
                    isPlaying = state == "playing"
                    title = parts[1]
                    artist = parts[2]
                    album = parts[3]
                    duration = Double(parts[4]) ?? 0
                    elapsedTime = Double(parts[5]) ?? 0
                    bundleIdentifier = "com.spotify.client"
                    hasActivePlayer = !title.isEmpty
                    lastUpdated = Date()
                    print("🎵 Spotify: '\(title)' by \(artist), playing=\(isPlaying), active=\(hasActivePlayer)")
                }
            } else if let error = error {
                print("🎵 Spotify AppleScript error: \(error)")
            }
        }
    }

    // MARK: - Notification Handlers
    private func handleMusicUpdate(
        state: String?, name: String?, artist artistName: String?,
        album albumName: String?, totalTime: Double?, position: Double?
    ) {
        bundleIdentifier = "com.apple.Music"

        if let state = state {
            isPlaying = state == "Playing"
        }

        if let name = name {
            title = name
        }

        if let artistName = artistName {
            artist = artistName
        }

        if let albumName = albumName {
            album = albumName
        }

        if let totalTime = totalTime {
            duration = totalTime / 1000.0  // Convert ms to seconds
        }

        if let position = position {
            elapsedTime = position
        }

        hasActivePlayer = !title.isEmpty
        lastUpdated = Date()

        // Fetch artwork via MediaRemote
        updateNowPlayingInfo()
    }

    private func handleSpotifyUpdate(
        state: String?, name: String?, artist artistName: String?,
        album albumName: String?, duration durationMs: Double?, position: Double?
    ) {
        bundleIdentifier = "com.spotify.client"

        if let state = state {
            isPlaying = state == "Playing"
        }

        if let name = name {
            title = name
        }

        if let artistName = artistName {
            artist = artistName
        }

        if let albumName = albumName {
            album = albumName
        }

        if let durationMs = durationMs {
            duration = durationMs / 1000.0
        }

        if let position = position {
            elapsedTime = position
        }

        hasActivePlayer = !title.isEmpty
        lastUpdated = Date()

        updateNowPlayingInfo()
    }

    // MARK: - MediaRemote Info Fetch
    private func updateNowPlayingInfo() {
        MRMediaRemoteGetNowPlayingInfoFunction?(DispatchQueue.main) { [weak self] info in
            Task { @MainActor in
                self?.processNowPlayingInfo(info)
            }
        }

        MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction?(DispatchQueue.main) { [weak self] playing in
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }

    private func processNowPlayingInfo(_ info: [String: Any]?) {
        guard let info = info else {
            print("NowPlayingService: processNowPlayingInfo received nil")
            hasActivePlayer = false
            return
        }

        print("NowPlayingService: processNowPlayingInfo received \(info.keys.count) keys")

        // kMRMediaRemoteNowPlayingInfoTitle
        if let infoTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String {
            title = infoTitle
        }

        // kMRMediaRemoteNowPlayingInfoArtist
        if let infoArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String {
            artist = infoArtist
        }

        // kMRMediaRemoteNowPlayingInfoAlbum
        if let infoAlbum = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String {
            album = infoAlbum
        }

        // kMRMediaRemoteNowPlayingInfoDuration
        if let infoDuration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double {
            duration = infoDuration
        }

        // kMRMediaRemoteNowPlayingInfoElapsedTime
        if let infoElapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
            elapsedTime = infoElapsed
        }

        // kMRMediaRemoteNowPlayingInfoPlaybackRate
        if let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double {
            playbackRate = rate
            isPlaying = rate > 0
        }

        // kMRMediaRemoteNowPlayingInfoShuffleMode
        if let shuffleMode = info["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? Int {
            isShuffled = shuffleMode != 1  // 1 = off
        }

        // kMRMediaRemoteNowPlayingInfoRepeatMode
        if let repeatModeValue = info["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? Int {
            repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        }

        // kMRMediaRemoteNowPlayingInfoArtworkData
        if let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
           let image = NSImage(data: artworkData) {
            albumArt = image
            extractDominantColor(from: image)
        }

        hasActivePlayer = !title.isEmpty
        lastUpdated = Date()
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
        MRMediaRemoteSendCommandFunction?(2, nil)
    }

    func play() {
        MRMediaRemoteSendCommandFunction?(0, nil)
    }

    func pause() {
        MRMediaRemoteSendCommandFunction?(1, nil)
    }

    func nextTrack() {
        MRMediaRemoteSendCommandFunction?(4, nil)
    }

    func previousTrack() {
        MRMediaRemoteSendCommandFunction?(5, nil)
    }

    func seek(to time: TimeInterval) {
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
