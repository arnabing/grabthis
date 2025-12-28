//
//  NowPlayingExpandedView.swift
//  GrabThisApp
//
//  Full Now Playing player view for expanded/hover state
//  Includes album art, track info, progress bar, and all controls
//

import SwiftUI

struct NowPlayingExpandedView: View {
    @ObservedObject var service: NowPlayingService
    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            // Header with visualizer
            headerWithVisualizer

            // Main content: Album art + Track info
            HStack(alignment: .top, spacing: 16) {
                albumArtView
                trackInfoView
            }

            // Progress bar with seek
            progressBarView

            // Controls row
            controlsRow
        }
        .padding(16)
    }

    // MARK: - Header with Visualizer
    private var headerWithVisualizer: some View {
        HStack {
            Spacer()
            AudioSpectrumView(isPlaying: .constant(service.isPlaying))
                .frame(width: 20, height: 16)
        }
    }

    // MARK: - Album Art
    private var albumArtView: some View {
        Group {
            if let art = service.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: Color(nsColor: service.dominantColor).opacity(0.4), radius: 12, x: 0, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
    }

    // MARK: - Track Info
    private var trackInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title
            Text(service.title.isEmpty ? "Not Playing" : service.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            // Artist
            Text(service.artist.isEmpty ? "Unknown Artist" : service.artist)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            // Album
            if !service.album.isEmpty {
                Text(service.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress Bar
    private var progressBarView: some View {
        VStack(spacing: 4) {
            // Slider
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: geometry.size.width * currentProgress, height: 4)

                    // Drag handle (appears on hover/drag)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: geometry.size.width * currentProgress - 6)
                        .opacity(isDraggingProgress ? 1 : 0)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDraggingProgress = true
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            dragProgress = progress
                        }
                        .onEnded { value in
                            isDraggingProgress = false
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            let seekTime = progress * service.duration
                            service.seek(to: seekTime)
                        }
                )
            }
            .frame(height: 12)

            // Time labels
            HStack {
                Text(isDraggingProgress ? formatTime(dragProgress * service.duration) : service.formattedElapsedTime)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Text(service.formattedDuration)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var currentProgress: Double {
        if isDraggingProgress {
            return dragProgress
        }
        return service.progress
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Controls Row
    private var controlsRow: some View {
        HStack(spacing: 0) {
            // Shuffle
            controlButton(
                icon: "shuffle",
                isActive: service.isShuffled,
                action: { service.toggleShuffle() }
            )

            Spacer()

            // Previous
            controlButton(
                icon: "backward.fill",
                size: 16,
                action: { service.previousTrack() }
            )

            Spacer()

            // Play/Pause (larger)
            Button(action: { service.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 40, height: 40)

                    Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: service.isPlaying ? 0 : 1)  // Optical centering for play icon
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Next
            controlButton(
                icon: "forward.fill",
                size: 16,
                action: { service.nextTrack() }
            )

            Spacer()

            // Favorite / Add to Library
            controlButton(
                icon: service.isFavorite ? "star.fill" : "star",
                isActive: service.isFavorite,
                action: { service.toggleFavorite() }
            )
        }
        .padding(.horizontal, 8)
    }

    private func controlButton(
        icon: String,
        size: CGFloat = 14,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? Color.red : Color.white.opacity(0.8))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
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
            AudioSpectrumView(isPlaying: .constant(service.isPlaying))
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
