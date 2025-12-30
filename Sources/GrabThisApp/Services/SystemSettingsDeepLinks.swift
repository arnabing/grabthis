import AppKit
import Foundation

enum SystemSettingsDeepLinks {
    static func openPrivacySecurity() {
        // Privacy & Security main pane
        open(urlString: "x-apple.systempreferences:com.apple.preference.security")
    }

    static func openScreenRecording() {
        // Privacy & Security → Screen Recording
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openInputMonitoring() {
        // Privacy & Security → Input Monitoring
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophone() {
        // Privacy & Security → Microphone
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechRecognition() {
        // Privacy & Security → Speech Recognition
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    static func openAccessibility() {
        // Privacy & Security → Accessibility
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomation() {
        // Privacy & Security → Automation
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
        // Bring System Settings to foreground
        bringSettingsToFront()
    }

    private static func bringSettingsToFront() {
        // Give the system a moment to open Settings, then activate it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let settingsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                settingsApp.activate(options: [.activateIgnoringOtherApps])
            } else if let settingsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preferences").first {
                // macOS 13+ uses different bundle ID
                settingsApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}


