import AppKit
import Combine
import SwiftUI

/// Manages multiple OverlayPanelController instances - one per connected screen.
/// All panels share the same Model, so state is synchronized across all screens.
@MainActor
final class OverlayPanelManager {
    static let shared = OverlayPanelManager()

    /// Shared model used by all panels (single source of truth)
    let model = OverlayPanelController.Model()

    /// Panel controllers indexed by screen's unique identifier
    private var panels: [CGDirectDisplayID: OverlayPanelController] = [:]

    private var screenObserver: Any?

    private init() {
        // Create panels for all current screens
        updatePanelsForScreens()

        // Listen for screen configuration changes (connect/disconnect monitors)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updatePanelsForScreens()
            }
        }
    }

    /// Returns the primary panel (main screen) for API compatibility
    var primaryPanel: OverlayPanelController? {
        guard let mainScreen = NSScreen.main else { return panels.values.first }
        let mainDisplayID = mainScreen.displayID
        return panels[mainDisplayID] ?? panels.values.first
    }

    /// All active panel controllers
    var allPanels: [OverlayPanelController] {
        Array(panels.values)
    }

    /// Updates panels to match currently connected screens
    private func updatePanelsForScreens() {
        let currentScreenIDs = Set(NSScreen.screens.map { $0.displayID })
        let existingPanelIDs = Set(panels.keys)

        // Remove panels for disconnected screens
        let disconnectedIDs = existingPanelIDs.subtracting(currentScreenIDs)
        for displayID in disconnectedIDs {
            if let panel = panels.removeValue(forKey: displayID) {
                panel.hide()
                Log.overlay.info("Removed panel for disconnected screen \(displayID)")
            }
        }

        // Add panels for new screens
        let newScreenIDs = currentScreenIDs.subtracting(existingPanelIDs)
        for screen in NSScreen.screens where newScreenIDs.contains(screen.displayID) {
            let controller = OverlayPanelController(model: model, screen: screen)
            panels[screen.displayID] = controller
            Log.overlay.info("Created panel for screen \(screen.displayID) (\(screen.localizedName))")

            // Show idle chip on new screen if we're in idle mode
            if model.mode == .idleChip {
                controller.presentIdleChip()
            }
        }
    }

    // MARK: - Forwarding API (calls all panels)

    func hide() {
        for panel in allPanels {
            panel.hide()
        }
    }

    func presentIdleChip() {
        for panel in allPanels {
            panel.presentIdleChip()
        }
    }

    func presentListening(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        for panel in allPanels {
            panel.presentListening(appName: appName, screenshot: screenshot, transcript: transcript)
        }
    }

    func updateListening(screenshot: ScreenshotCaptureResult? = nil, transcript: String? = nil) {
        // Model is shared, so just update once - all panels see it
        if let screenshot { model.screenshot = screenshot }
        if let transcript { model.transcript = transcript }
    }

    func presentReview(appName: String, screenshot: ScreenshotCaptureResult?, transcript: String) {
        for panel in allPanels {
            panel.presentReview(appName: appName, screenshot: screenshot, transcript: transcript)
        }
    }

    func presentTranscribing() {
        for panel in allPanels {
            panel.presentTranscribing()
        }
    }

    func presentProcessing() {
        for panel in allPanels {
            panel.presentProcessing()
        }
    }

    func presentResponse(_ text: String) {
        for panel in allPanels {
            panel.presentResponse(text)
        }
    }

    func presentError(_ message: String) {
        for panel in allPanels {
            panel.presentError(message)
        }
    }

    func retractResponse() {
        for panel in allPanels {
            panel.retractResponse()
        }
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        model.accessibilityTrusted = trusted
    }

    func show() {
        for panel in allPanels {
            panel.show()
        }
    }

    func positionWindow() {
        for panel in allPanels {
            panel.positionWindow()
        }
    }

    func showExpandedScreenshot() {
        // Only show expanded screenshot on the primary panel
        primaryPanel?.showExpandedScreenshot()
    }

    var isOverlayKeyWindow: Bool {
        allPanels.contains { $0.isOverlayKeyWindow }
    }
}

// MARK: - NSScreen Extension

private extension NSScreen {
    /// Unique display identifier for this screen
    var displayID: CGDirectDisplayID {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
