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
        Log.autoInsert.info("requested Accessibility prompt (AXIsProcessTrustedWithOptions)")
    }

    /// Writes text to clipboard and pastes via Cmd+V.
    /// Simple model: we keep the transcript on the clipboard (no restore).
    /// Requires Accessibility permission in most setups.
    @MainActor
    static func copyAndPasteKeepingClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        Log.autoInsert.info("copyAndPasteKeepingClipboard len=\(text.count, privacy: .public) axTrusted=\(isAccessibilityTrusted(), privacy: .public)")

        copyToClipboardKeeping(_text: text)
        let ok = sendCmdV()
        Log.autoInsert.info("sent Cmd+V ok=\(ok, privacy: .public)")
    }

    @MainActor
    static func copyToClipboardKeeping(_text text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.autoInsert.info("copied transcript to clipboard len=\(text.count, privacy: .public)")
    }

    /// Attempts to insert text via Accessibility into the currently focused UI element.
    /// This can be more reliable than synthetic Cmd+V for some apps (including Electron apps).
    /// Returns true if we successfully set an accessibility value.
    @MainActor
    static func tryInsertViaAccessibility(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard isAccessibilityTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedObj)
        guard focusedErr == .success, let focusedObj else {
            Log.autoInsert.error("AX focused element missing err=\(String(describing: focusedErr), privacy: .public)")
            return false
        }
        let focused = (focusedObj as AnyObject) as! AXUIElement

        var roleObj: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleObj)
        let role = (roleObj as? String) ?? "unknown"
        var subroleObj: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleObj)
        let subrole = (subroleObj as? String) ?? "unknown"
        Log.autoInsert.info("AX focused role=\(role, privacy: .public) subrole=\(subrole, privacy: .public)")

        // Prefer replacing selected text (safe for insertion at caret when selection is empty).
        let selectedSetErr = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if selectedSetErr == .success {
            Log.autoInsert.info("AX insert success (kAXSelectedTextAttribute)")
            return true
        }

        // Avoid kAXValueAttribute here; it may overwrite entire editor contents (dangerous).
        Log.autoInsert.error("AX insert failed err=\(String(describing: selectedSetErr), privacy: .public)")
        return false
    }

    @MainActor
    static func tryPasteViaEditMenu(targetPID: pid_t? = nil) -> Bool {
        guard isAccessibilityTrusted() else { return false }

        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        guard pid > 0 else {
            Log.autoInsert.error("menu paste failed: missing pid")
            return false
        }

        let app = AXUIElementCreateApplication(pid)

        var menuBarObj: CFTypeRef?
        let menuBarErr = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarObj)
        guard menuBarErr == .success, let menuBarObj else {
            Log.autoInsert.error("menu paste failed: no menuBar err=\(String(describing: menuBarErr), privacy: .public)")
            return false
        }
        let menuBar = (menuBarObj as AnyObject) as! AXUIElement

        var barChildrenObj: CFTypeRef?
        let barChildrenErr = AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &barChildrenObj)
        guard barChildrenErr == .success, let items = barChildrenObj as? [AXUIElement] else {
            Log.autoInsert.error("menu paste failed: no menubar children err=\(String(describing: barChildrenErr), privacy: .public)")
            return false
        }

        func title(of el: AXUIElement) -> String? {
            var titleObj: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleObj)
            guard err == .success else { return nil }
            return titleObj as? String
        }

        // Find the "Edit" menu bar item
        guard let editItem = items.first(where: { title(of: $0) == "Edit" }) else {
            Log.autoInsert.error("menu paste failed: couldn't find Edit menu")
            return false
        }

        var editChildrenObj: CFTypeRef?
        let editChildrenErr = AXUIElementCopyAttributeValue(editItem, kAXChildrenAttribute as CFString, &editChildrenObj)
        guard editChildrenErr == .success, let editChildren = editChildrenObj as? [AXUIElement], let editMenu = editChildren.first else {
            Log.autoInsert.error("menu paste failed: Edit has no submenu err=\(String(describing: editChildrenErr), privacy: .public)")
            return false
        }

        var menuItemsObj: CFTypeRef?
        let menuItemsErr = AXUIElementCopyAttributeValue(editMenu, kAXChildrenAttribute as CFString, &menuItemsObj)
        guard menuItemsErr == .success, let menuItems = menuItemsObj as? [AXUIElement] else {
            Log.autoInsert.error("menu paste failed: Edit menu has no items err=\(String(describing: menuItemsErr), privacy: .public)")
            return false
        }

        // Find "Paste" menu item
        guard let pasteItem = menuItems.first(where: { title(of: $0) == "Paste" }) else {
            Log.autoInsert.error("menu paste failed: couldn't find Paste item")
            return false
        }

        let pressErr = AXUIElementPerformAction(pasteItem, kAXPressAction as CFString)
        if pressErr == .success {
            Log.autoInsert.info("menu paste success (Edit → Paste)")
            return true
        } else {
            Log.autoInsert.error("menu paste failed: press err=\(String(describing: pressErr), privacy: .public)")
            return false
        }
    }

    @MainActor
    private static func sendCmdV() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v' on US keyboard

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return cmdDown != nil && cmdUp != nil
    }
}


