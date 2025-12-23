import AppKit
import Foundation

enum SystemSettingsDeepLinks {
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

    static func openAccessibility() {
        // Privacy & Security → Accessibility
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}


