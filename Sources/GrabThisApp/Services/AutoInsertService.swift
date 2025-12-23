import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum AutoInsertService {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermissionPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let opts: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(opts)
        Log.app.info("requested Accessibility prompt (AXIsProcessTrustedWithOptions)")
    }

    /// Writes text to clipboard and pastes via Cmd+V.
    /// Simple model: we keep the transcript on the clipboard (no restore).
    /// Requires Accessibility permission in most setups.
    @MainActor
    static func copyAndPasteKeepingClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        Log.app.info("copyAndPasteKeepingClipboard len=\(text.count, privacy: .public) axTrusted=\(isAccessibilityTrusted(), privacy: .public)")

        copyToClipboardKeeping(_text: text)
        sendCmdV()
        Log.app.info("sent Cmd+V")
    }

    @MainActor
    static func copyToClipboardKeeping(_text text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.app.info("copied transcript to clipboard len=\(text.count, privacy: .public)")
    }

    @MainActor
    private static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v' on US keyboard

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}


