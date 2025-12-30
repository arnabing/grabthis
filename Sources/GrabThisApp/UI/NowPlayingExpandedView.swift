//
//  NowPlayingExpandedView.swift
//  GrabThisApp
//
//  Full Now Playing player view for expanded/hover state
//  Includes album art, track info, progress bar, and all controls
//

import SwiftUI

// Simple file-based debug logging
private func debugLog(_ message: String) {
    let logPath = "/tmp/grabthis_debug.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

struct NowPlayingExpandedView: View {
    @ObservedObject var service: NowPlayingService
    var onHover: ((Bool) -> Void)? = nil  // Callback to keep parent notch open
    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress: Double = 0
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Album art LEFT-justified
            albumArtView
                .padding(.leading, 14)

            // Title/Controls/Progress CENTERED in remaining space (under notch)
            VStack(alignment: .center, spacing: 6) {
                trackInfoView

                Spacer(minLength: 0)

                // Controls row (simplified: prev, play/pause, next only)
                controlsRow

                Spacer(minLength: 0)

                // Progress bar at bottom (compact)
                progressBarView
            }
            .frame(maxWidth: .infinity, maxHeight: 100)  // Fill remaining space, centered
            .padding(.trailing, 14)
        }
        .padding(.vertical, 10)
        .background(
            // Use background for hover detection instead of contentShape
            // contentShape was blocking button clicks
            Color.black.opacity(0.001)
                .onHover { hovering in
                    isHovering = hovering
                    onHover?(hovering)
                }
        )
        .onAppear {
            debugLog("NowPlayingExpandedView appeared - controls should be visible")
        }
    }

    // MARK: - Album Art (THE VISUAL FOCUS - maximized)
    private var albumArtView: some View {
        Group {
            if let art = service.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)  // Maximized to fill available space
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: Color(nsColor: service.dominantColor).opacity(0.4), radius: 12, x: 0, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
    }

    // MARK: - Track Info (centered)
    private var trackInfoView: some View {
        VStack(alignment: .center, spacing: 2) {
            // Title
            Text(service.title.isEmpty ? "Not Playing" : service.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            // Artist
            Text(service.artist.isEmpty ? "Unknown Artist" : service.artist)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    // MARK: - Progress Bar (compact, at bottom)
    private var progressBarView: some View {
        // TimelineView updates only when playing - more efficient than a timer
        TimelineView(.animation(minimumInterval: 0.1, paused: !service.isPlaying)) { context in
            let currentTime = isDraggingProgress
                ? dragProgress * service.duration
                : service.estimatedPlaybackPosition(at: context.date)
            let progress = service.duration > 0 ? currentTime / service.duration : 0

            HStack(spacing: 6) {
                // Current time
                Text(formatTime(currentTime))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, alignment: .trailing)

                // Compact slider
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 3)

                        // Progress fill
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.8))
                            .frame(width: geometry.size.width * progress, height: 3)

                        // Drag handle (appears on drag)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: geometry.size.width * progress - 5)
                            .opacity(isDraggingProgress ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingProgress = true
                                let prog = max(0, min(1, value.location.x / geometry.size.width))
                                dragProgress = prog
                            }
                            .onEnded { value in
                                isDraggingProgress = false
                                let prog = max(0, min(1, value.location.x / geometry.size.width))
                                let seekTime = prog * service.duration
                                service.seek(to: seekTime)
                            }
                    )
                }
                .frame(height: 10)

                // Duration
                Text(service.formattedDuration)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Controls Row (iOS 26 style - simplified: prev, play/pause, next)
    private var controlsRow: some View {
        HStack(spacing: 24) {
            // Previous
            controlButton(
                icon: "backward.fill",
                size: 18,
                action: { service.previousTrack() }
            )

            // Play/Pause (larger, centered)
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 36, height: 36)

                Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: service.isPlaying ? 0 : 1)  // Optical centering for play icon
            }
            .highPriorityGesture(
                TapGesture()
                    .onEnded {
                        debugLog("Play/Pause tapped")
                        service.togglePlayPause()
                    }
            )

            // Next
            controlButton(
                icon: "forward.fill",
                size: 18,
                action: { service.nextTrack() }
            )
        }
    }

    private func controlButton(
        icon: String,
        size: CGFloat = 14,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.8))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.001)) // Ensure hit area
            .highPriorityGesture(
                TapGesture()
                    .onEnded {
                        debugLog("Control button tapped: \(icon)")
                        action()
                    }
            )
    }
}

// MARK: - Mini Expanded View (for smaller spaces)

struct NowPlayingMiniExpandedView: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        HStack(spacing: 12) {
            // Album art
            if let art = service.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                // Title + Artist
                Text(service.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(service.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                // Progress
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white)
                            .frame(width: geometry.size.width * service.progress, height: 3)
                    }
                }
                .frame(height: 3)
            }

            Spacer()

            // Controls
            HStack(spacing: 12) {
                Button(action: { service.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: { service.togglePlayPause() }) {
                    Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: { service.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            // Visualizer
            AudioSpectrumView(isPlaying: service.isPlaying)  // Fixed: was .constant()
                .frame(width: 16, height: 14)
        }
        .padding(12)
    }
}

#Preview("Expanded") {
    ZStack {
        Color.black
        NowPlayingExpandedView(service: NowPlayingService.shared)
    }
    .frame(width: 400, height: 250)
}

#Preview("Mini Expanded") {
    ZStack {
        Color.black
        NowPlayingMiniExpandedView(service: NowPlayingService.shared)
    }
    .frame(width: 350, height: 80)
}
