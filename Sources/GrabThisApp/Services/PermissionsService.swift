import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices

enum PermissionsService {
    // MARK: - Screen Recording (Screen Capture)

    /// Returns `true` if Screen Recording permission is granted for this app.
    /// This is the permission behind the “would like to record this computer’s screen and audio” dialog.
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
}


