import AppKit
import Foundation
import SwiftUI

/// Detects when a fullscreen app is active (e.g., YouTube, Netflix, VLC).
/// Used to suppress the Now Playing sneak peek during movies/videos.
@MainActor
final class FullScreenDetector: ObservableObject {
    static let shared = FullScreenDetector()

    /// User setting to enable/disable fullscreen detection (on by default)
    @AppStorage("hideNotchInFullScreen") var isEnabled: Bool = true

    @Published private(set) var isFullScreenAppActive: Bool = false

    private var timer: Timer?

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        // Check every 0.5 seconds (lightweight, catches transitions quickly)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFullScreenStatus()
            }
        }
        // Initial check
        updateFullScreenStatus()
    }

    private func updateFullScreenStatus() {
        let newStatus = checkIfFullScreenActive()
        if newStatus != isFullScreenAppActive {
            isFullScreenAppActive = newStatus
            Log.overlay.info("Full screen status changed: \(newStatus)")
        }
    }

    private func checkIfFullScreenActive() -> Bool {
        guard let screen = NSScreen.main else { return false }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }

        // Skip if our app is frontmost (user interacting with notch)
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }

        // Get list of on-screen windows
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let screenFrame = screen.frame

        for window in windows {
            // Only check windows belonging to the frontmost app
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid == frontApp.processIdentifier else {
                continue
            }

            // Get window bounds
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let _ = boundsDict["X"],
                  let _ = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            // If window fills the entire screen, it's fullscreen
            // Use >= to handle potential rounding/fractional differences
            if width >= screenFrame.width && height >= screenFrame.height {
                return true
            }
        }

        return false
    }
}
