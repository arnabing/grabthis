import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum AutoInsertService {
    enum InsertStrategy: String {
        case axSelectedText = "axSelectedText"
        case axMenuCmdV = "axMenuCmdV"
        case cgCmdV = "cgCmdV"
        case cgTypeText = "cgTypeText"
    }

    struct InsertResult {
        let success: Bool
        let strategy: InsertStrategy?
        let details: String
    }

    private static let cursorBundleIdHints: [String] = [
        "com.todesktop.", // common Cursor / todesktop wrapper
        "com.cursor.",    // future-proof if Cursor ships a direct bundle id
    ]

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

    /// Wispr-like polish: optionally restore the user's previous clipboard after an auto-insert.
    /// Keep this conservative: restore only plain string content.
    @MainActor
    static func copyToClipboardRestoringPrevious(_ text: String, restoreAfterMs: Int = 350, pasteAction: () -> InsertResult) -> InsertResult {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        let result = pasteAction()
        guard result.success else { return result }

        // Restore after a short delay to give the target app time to read the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, restoreAfterMs))) {
            guard let previous else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previous, forType: .string)
            Log.autoInsert.info("restored clipboard after auto-insert")
        }
        return result
    }

    /// Deterministic insert pipeline (Wispr-like): copy → then try multiple insertion strategies.
    /// Assumes the target app is already frontmost and its editor is focused.
    @MainActor
    static func autoInsert(_ text: String, targetPID: pid_t?) -> InsertResult {
        guard !text.isEmpty else { return InsertResult(success: false, strategy: nil, details: "empty text") }
        guard isAccessibilityTrusted() else { return InsertResult(success: false, strategy: nil, details: "axTrusted=false") }

        // Always copy first (so user can manually paste if we fail).
        // For Cursor we restore clipboard (Wispr-like) after successful insert.
        let isCursor = shouldUseCursorFallback(targetPID: targetPID)
        let restoreClipboard = isCursor

        let runPipeline: () -> InsertResult = {
            copyToClipboardKeeping(_text: text)

            // Cursor/Electron: frontmost can be true before focus is ready; try to wait briefly.
            let focusedReady = waitForFocusedElement(timeoutSeconds: 0.55)
            Log.autoInsert.info("focusReady=\(focusedReady, privacy: .public)")
            Log.autoInsert.info("autoInsert targetIsCursor=\(isCursor, privacy: .public)")

            if isCursor {
                // Cursor: avoid menu interaction (causes visible menu bar flicker and often fails to match).
                // Prefer robust CGEvent Cmd+V.
                if retry(times: 4, delayMs: 55, work: { sendCmdVSeparated() }) {
                    return InsertResult(success: true, strategy: .cgCmdV, details: "Cursor: CGEvent Cmd down + V down/up + Cmd up")
                }
            } else {
                // Strategy 1 (default): AX selected-text insert (fast when supported).
                if tryInsertViaAccessibility(text) {
                    return InsertResult(success: true, strategy: .axSelectedText, details: "AX selected text set")
                }

                // Strategy 2 (default): Press the app's menu item corresponding to Cmd+V (language-agnostic).
                if retry(times: 2, delayMs: 55, work: { tryPasteViaMenuShortcutCmdV(targetPID: targetPID, wakeMenuBar: false) }) {
                    return InsertResult(success: true, strategy: .axMenuCmdV, details: "AX menu press for Cmd+V")
                }

                // Strategy 3 (default): Robust Cmd+V injection (separate Cmd keydown/up, small delays, retries).
                if retry(times: 3, delayMs: 45, work: { sendCmdVSeparated() }) {
                    return InsertResult(success: true, strategy: .cgCmdV, details: "CGEvent Cmd down + V down/up + Cmd up")
                }
            }

            // Strategy 4: As a last resort, type the text (slow but works when paste is ignored).
            if isCursor || !focusedReady {
                if typeUnicode(text) {
                    return InsertResult(success: true, strategy: .cgTypeText, details: "CGEvent Unicode typing (Cursor fallback)")
                }
            }

            return InsertResult(success: false, strategy: nil, details: "all strategies failed")
        }

        if restoreClipboard {
            return copyToClipboardRestoringPrevious(text, restoreAfterMs: 350, pasteAction: runPipeline)
        } else {
            return runPipeline()
        }
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

        // Guard: do not auto-insert into secure fields (passwords).
        if subrole.localizedCaseInsensitiveContains("secure") || role.localizedCaseInsensitiveContains("secure") {
            Log.autoInsert.error("AX insert blocked: secure field role=\(role, privacy: .public) subrole=\(subrole, privacy: .public)")
            return false
        }

        // Web/Electron fields often report success for SelectedText but don’t commit the change.
        // For these, prefer paste-based strategies (Cmd+V) instead of AX value setting.
        if role == "AXTextArea", subrole == "unknown" {
            Log.autoInsert.info("AX selectedText skipped for AXTextArea/unknown (prefer paste)")
            return false
        }

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

    /// More robust than title-matching: finds the menu item whose shortcut is Cmd+V and presses it.
    /// This tends to work even if "Paste" is localized, or menus differ (common in Electron apps).
    @MainActor
    static func tryPasteViaMenuShortcutCmdV(targetPID: pid_t?, wakeMenuBar: Bool = false) -> Bool {
        guard isAccessibilityTrusted() else { return false }
        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        guard pid > 0 else {
            Log.autoInsert.error("menu Cmd+V failed: missing pid")
            return false
        }

        let app = AXUIElementCreateApplication(pid)
        var menuBarObj: CFTypeRef?
        let menuBarErr = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarObj)
        guard menuBarErr == .success, let menuBarObj else {
            Log.autoInsert.error("menu Cmd+V failed: no menuBar err=\(String(describing: menuBarErr), privacy: .public)")
            return false
        }
        let menuBar = (menuBarObj as AnyObject) as! AXUIElement

        // Some apps require the menu bar to be "awake". This causes visible menu flicker,
        // so keep it opt-in (Cursor in particular looks bad here).
        if wakeMenuBar {
            _ = tryOpenEditMenu(in: menuBar)
        }

        // Walk menu bar tree and find a menu item that has Cmd+V as its key equivalent.
        let pressed = pressFirstMenuItem(matchingCmdChar: "v", modifiersMustContainCommand: true, in: menuBar, depthLimit: 5)
        if pressed {
            Log.autoInsert.info("menu Cmd+V success (found key equivalent)")
        } else {
            Log.autoInsert.error("menu Cmd+V failed: no matching menu item")
        }
        return pressed
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

    /// More reliable for some Electron apps: press Command as a separate modifier key.
    @MainActor
    private static func sendCmdVSeparated() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let src else { return false }

        let cmdKey: CGKeyCode = 55 // left command
        let vKey: CGKeyCode = 9    // 'v' on US keyboard

        guard
            let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)
        else { return false }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        // tiny delay helps Electron pick up modifier state
        usleep(10_000)
        vDown.post(tap: .cghidEventTap)
        usleep(6_000)
        vUp.post(tap: .cghidEventTap)
        usleep(6_000)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private static func typeUnicode(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let src else { return false }

        var ok = true
        for scalar in text.unicodeScalars {
            var u = UInt16(scalar.value)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            } else {
                ok = false
                break
            }
        }
        Log.autoInsert.info("typed unicode len=\(text.count, privacy: .public) ok=\(ok, privacy: .public)")
        return ok
    }

    // MARK: - AX menu traversal helpers

    @MainActor
    private static func retry(times: Int, delayMs: Int, work: () -> Bool) -> Bool {
        guard times > 0 else { return false }
        for i in 0..<times {
            if work() { return true }
            if i != times - 1 {
                usleep(useconds_t(max(0, delayMs) * 1000))
            }
        }
        return false
    }

    @MainActor
    private static func waitForFocusedElement(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let sys = AXUIElementCreateSystemWide()
        while Date() < deadline {
            var focusedObj: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedObj)
            if err == .success, focusedObj != nil {
                return true
            }
            usleep(25_000)
        }
        return false
    }

    @MainActor
    private static func shouldUseCursorFallback(targetPID: pid_t?) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier ?? ""
        let name = front?.localizedName ?? ""
        let pid = front?.processIdentifier ?? -1

        let isCursorByName = name.localizedCaseInsensitiveContains("Cursor")
        let isCursorByBundle = cursorBundleIdHints.contains(where: { bundle.hasPrefix($0) })
        let pidMatches = (targetPID != nil && pid == targetPID)

        let isCursor = (isCursorByName || isCursorByBundle) && (targetPID == nil || pidMatches)
        Log.autoInsert.info("cursorCheck name=\(name, privacy: .public) bundle=\(bundle, privacy: .public) isCursor=\(isCursor, privacy: .public)")
        return isCursor
    }

    @MainActor
    private static func pressFirstMenuItem(matchingCmdChar: String, modifiersMustContainCommand: Bool, in root: AXUIElement, depthLimit: Int) -> Bool {
        guard depthLimit >= 0 else { return false }

        // Read children; menu bars and menus both use kAXChildren.
        var childrenObj: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenObj)
        if err == .success, let children = childrenObj as? [AXUIElement] {
            for child in children {
                // If this is a menu item, see if it matches Cmd+V.
                if matchesCmdCharMenuItem(child, cmdChar: matchingCmdChar, requireCommand: modifiersMustContainCommand) {
                    let pressErr = AXUIElementPerformAction(child, kAXPressAction as CFString)
                    if pressErr == .success { return true }
                }

                // Recurse into child (submenu).
                if pressFirstMenuItem(matchingCmdChar: matchingCmdChar, modifiersMustContainCommand: modifiersMustContainCommand, in: child, depthLimit: depthLimit - 1) {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    private static func matchesCmdCharMenuItem(_ el: AXUIElement, cmdChar: String, requireCommand: Bool) -> Bool {
        // Menu items expose:
        // - kAXMenuItemCmdCharAttribute (e.g. "V")
        // - kAXMenuItemCmdModifiersAttribute (bitmask including command)
        var charObj: CFTypeRef?
        let charErr = AXUIElementCopyAttributeValue(el, kAXMenuItemCmdCharAttribute as CFString, &charObj)
        guard charErr == .success, let char = (charObj as? String)?.lowercased(), char == cmdChar.lowercased() else {
            return false
        }

        if !requireCommand { return true }

        var modObj: CFTypeRef?
        let modErr = AXUIElementCopyAttributeValue(el, kAXMenuItemCmdModifiersAttribute as CFString, &modObj)
        guard modErr == .success else { return false }

        let mods: Int
        if let n = modObj as? NSNumber {
            mods = n.intValue
        } else if let n = modObj as? Int {
            mods = n
        } else {
            return false
        }

        // Carbon modifier flags: cmdKey = 1<<8 (256). We'll accept if that bit is set.
        let cmdKeyMask = 1 << 8
        return (mods & cmdKeyMask) != 0
    }

    @MainActor
    private static func tryOpenEditMenu(in menuBar: AXUIElement) -> Bool {
        func title(of el: AXUIElement) -> String? {
            var titleObj: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleObj)
            guard err == .success else { return nil }
            return titleObj as? String
        }

        var childrenObj: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenObj)
        guard err == .success, let items = childrenObj as? [AXUIElement] else { return false }

        // English-first: best-effort only (we still do key-equivalent search).
        guard let editItem = items.first(where: { title(of: $0) == "Edit" }) else { return false }
        let pressErr = AXUIElementPerformAction(editItem, kAXPressAction as CFString)
        if pressErr == .success {
            Log.autoInsert.info("opened Edit menu (best-effort)")
            usleep(25_000)
            return true
        }
        return false
    }
}


