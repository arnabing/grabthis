import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ApplicationServices

enum PermissionsService {
    // MARK: - Helpers

    /// Check if an app is currently running by bundle identifier
    private static func isAppRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
    // MARK: - Screen Recording (Screen Capture)

    /// Returns `true` if Screen Recording permission is granted for this app.
    /// This is the permission behind the "would like to record this computer's screen and audio" dialog.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt (if needed) and returns the resulting permission state.
    /// Note: after enabling in System Settings, macOS often requires quitting + relaunching the app.
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Accessibility

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Requests Accessibility permission with a system prompt.
    /// This opens the System Settings if not already trusted.
    @MainActor
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Automation (AppleScript/Apple Events)

    /// Checks if Automation permission is granted for controlling System Events.
    /// Returns true if we can successfully run an AppleScript, false otherwise.
    /// Note: This may trigger a permission prompt if not yet determined.
    static func checkAutomationPermission() -> Bool {
        let script = """
        tell application "System Events"
            return name of first application process whose frontmost is true
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            // If we got a result and no error, permission is granted
            if error == nil && result.stringValue != nil {
                return true
            }
        }
        return false
    }

    /// Requests Automation permission by triggering AppleScript execution.
    /// This will show the system prompt if permission hasn't been determined yet.
    /// Returns true if permission was granted, false otherwise.
    @discardableResult
    static func requestAutomationPermission() -> Bool {
        // First, try System Events (needed for general automation)
        let systemEventsScript = """
        tell application "System Events"
            return name of first application process whose frontmost is true
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: systemEventsScript) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil && result.stringValue != nil {
                // System Events permission granted, now try Music
                triggerMusicAutomation()
                return true
            }
        }
        return false
    }

    /// Triggers Automation permission request for Apple Music specifically.
    /// Only runs if Music is currently running (avoids "Where is Music?" dialog).
    static func triggerMusicAutomation() {
        // Check if Music is running BEFORE trying AppleScript
        guard isAppRunning(bundleIdentifier: "com.apple.Music") else { return }

        let musicScript = """
        tell application "Music"
            return player state as string
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: musicScript) {
            appleScript.executeAndReturnError(&error)
        }
    }

    /// Triggers Automation permission request for Spotify specifically.
    /// Only runs if Spotify is currently running (avoids "Where is Spotify?" dialog).
    static func triggerSpotifyAutomation() {
        // Check if Spotify is running BEFORE trying AppleScript
        guard isAppRunning(bundleIdentifier: "com.spotify.client") else { return }

        let spotifyScript = """
        tell application "Spotify"
            return player state as string
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: spotifyScript) {
            appleScript.executeAndReturnError(&error)
        }
    }
}


