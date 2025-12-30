//
//  NotchPage.swift
//  GrabThisApp
//
//  Pages/views for the notch overlay
//

import Foundation

/// Available pages in the notch overlay
enum NotchPage: Equatable {
    case transcription   // Default when fn held - live transcription (home)
    case nowPlaying      // When hovering with music playing
    case history         // History view
    case settings        // Settings expansion

    /// SF Symbol icon for this page (used in tab bar)
    var icon: String {
        switch self {
        case .transcription: return "mic.fill"
        case .nowPlaying: return "music.note"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    /// Display name for this page
    var displayName: String {
        switch self {
        case .transcription: return "Home"
        case .nowPlaying: return "Now Playing"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
}
