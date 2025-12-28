//
//  NowPlayingCompactView.swift
//  GrabThisApp
//
//  Compact Now Playing view for closed notch state (peek-through design)
//  Shows album art on left, visualizer on right
//

import SwiftUI

struct NowPlayingCompactView: View {
    @ObservedObject var service: NowPlayingService
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Left peek: Album art
            leftPeek

            // Center: Notch gap (invisible spacer)
            Spacer()
                .frame(width: notchWidth)

            // Right peek: Visualizer
            rightPeek
        }
    }

    // MARK: - Left Peek (Album Art)
    private var leftPeek: some View {
        Group {
            if let art = service.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: Color(nsColor: service.dominantColor).opacity(0.5), radius: 4, x: 0, y: 0)
            } else {
                // Placeholder when no artwork
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .onTapGesture {
            service.togglePlayPause()
        }
    }

    // MARK: - Right Peek (Visualizer)
    private var rightPeek: some View {
        AudioSpectrumView(isPlaying: .constant(service.isPlaying))
            .frame(width: 16, height: 14)
            .onTapGesture {
                service.togglePlayPause()
            }
    }
}

// MARK: - Alternative: Full Width Compact View
// This shows all info in a single row (for when expanded but compact)

struct NowPlayingCompactFullView: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        HStack(spacing: 8) {
            // Album art
            if let art = service.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }

            // Title + Artist
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(service.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            // Controls
            HStack(spacing: 8) {
                Button(action: { service.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: { service.togglePlayPause() }) {
                    Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: { service.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            // Visualizer
            AudioSpectrumView(isPlaying: .constant(service.isPlaying))
                .frame(width: 16, height: 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

#Preview("Compact Peek") {
    ZStack {
        Color.black
        NowPlayingCompactView(
            service: NowPlayingService.shared,
            notchWidth: 185
        )
    }
    .frame(width: 300, height: 40)
}

#Preview("Compact Full") {
    ZStack {
        Color.black
        NowPlayingCompactFullView(service: NowPlayingService.shared)
    }
    .frame(width: 300, height: 50)
}
