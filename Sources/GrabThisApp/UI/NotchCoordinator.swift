//
//  NotchCoordinator.swift
//  GrabThisApp
//
//  Coordinates notch page state and transitions
//  Based on boring.notch's BoringViewCoordinator pattern
//

import Combine
import Foundation
import SwiftUI

/// Coordinates the notch overlay page state
/// Works alongside OverlayPanelController.Mode for page-level navigation
@MainActor
final class NotchCoordinator: ObservableObject {
    static let shared = NotchCoordinator()

    // MARK: - Published State

    /// Current page when notch is expanded via hover (not fn key)
    @Published var currentPage: NotchPage = .transcription

    /// Whether the user is hovering over the notch
    @Published var isHovering: Bool = false

    /// Whether the fn key is being held
    @Published var fnKeyHeld: Bool = false

    /// Triggers a brief "sneak peek" of the notch when a new song starts
    @Published var showSneakPeek: Bool = false

    // MARK: - Private State

    private var hoverTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Track if music was previously available to detect new music starting
    private var hadActivePlayer: Bool = false

    // MARK: - Init

    private init() {
        // When music STARTS playing (not already playing), auto-switch to Now Playing
        NotificationCenter.default.publisher(for: .nowPlayingDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let nowHasPlayer = NowPlayingService.shared.hasActivePlayer
                let isEnabled = NowPlayingService.shared.isEnabled

                print("🎵 NotchCoordinator: nowPlayingDidChange - hasActivePlayer=\(nowHasPlayer), hadActivePlayer=\(self.hadActivePlayer), isEnabled=\(isEnabled), currentPage=\(self.currentPage)")

                // Only auto-switch when music STARTS (wasn't playing before, now is)
                if nowHasPlayer && !self.hadActivePlayer && isEnabled {
                    print("🎵 NotchCoordinator: Music STARTED - switching to .nowPlaying")
                    self.currentPage = .nowPlaying
                }

                // If music stops and we're on Now Playing, switch back to transcription
                if !nowHasPlayer && self.currentPage == .nowPlaying {
                    print("🎵 NotchCoordinator: Music STOPPED - switching to .transcription")
                    self.currentPage = .transcription
                }

                self.hadActivePlayer = nowHasPlayer
            }
            .store(in: &cancellables)

        // Trigger sneak peek when song changes (boring.notch style)
        NotificationCenter.default.publisher(for: .songDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Don't show sneak peek if:
                // - fn key is held (user is dictating)
                // - already hovering (notch is expanded)
                // - fullscreen app is active (watching movie/video)
                guard !self.fnKeyHeld && !self.isHovering else { return }
                let detector = FullScreenDetector.shared
                guard !(detector.isEnabled && detector.isFullScreenAppActive) else {
                    print("🎵 NotchCoordinator: Song changed but fullscreen app active - suppressing sneak peek")
                    return
                }

                print("🎵 NotchCoordinator: Song changed - triggering sneak peek")
                self.triggerSneakPeek()
            }
            .store(in: &cancellables)
    }

    /// Briefly show the notch wings for a new song, then retract
    private func triggerSneakPeek() {
        // Show peek - faster animation for snappier response
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            showSneakPeek = true
            currentPage = .nowPlaying
        }

        // Hide after 2.5 seconds
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !isHovering && !fnKeyHeld else { return }  // Don't hide if user engaged
            await MainActor.run {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                    self.showSneakPeek = false
                }
            }
        }
    }

    // MARK: - Public API

    /// Called when hover state changes
    /// Does NOT auto-switch pages - respects user's current page selection
    func onHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            isHovering = true
            // Don't auto-switch pages on hover - keep user's selection
            // Tabs are always visible when music is available for manual switching
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isHovering = false
                }
            }
        }
    }

    /// Called when fn key state changes
    func onFnKey(_ held: Bool) {
        fnKeyHeld = held
        if held {
            // fn key always goes to transcription page - NO animation wrapper needed
            // The main overlay animation handles this; extra animation causes jank
            currentPage = .transcription
        } else {
            // CRITICAL FIX: Reset hadActivePlayer when fn key released
            // This allows music restart detection to work properly after dictation
            // Without this, the condition `!hadActivePlayer` would fail if music was
            // playing before dictation started
            print("🎵 NotchCoordinator: fn key released - resetting hadActivePlayer")
            hadActivePlayer = false

            // Check if we should show Now Playing
            showNowPlayingIfAvailable()
        }
    }

    /// Switch to a specific page
    func switchTo(_ page: NotchPage) {
        // Faster animation (0.35s → 0.22s) for snappier tab switching
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            currentPage = page
        }
    }

    /// Show Now Playing page if music is playing
    func showNowPlayingIfAvailable() {
        if NowPlayingService.shared.hasActivePlayer && NowPlayingService.shared.isEnabled {
            switchTo(.nowPlaying)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let nowPlayingDidChange = Notification.Name("NowPlayingDidChange")
    static let songDidChange = Notification.Name("SongDidChange")
}
