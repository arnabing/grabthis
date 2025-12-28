import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ScreenshotCaptureResult: Equatable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat
}

enum CaptureService {
    enum CaptureError: Error {
        case noScreen
        case noDisplayMatch
        case noFrontmostApp
        case noFrontmostWindow
        case captureFailed
    }

    /// Temporary implementation: capture the main display via ScreenCaptureKit.
    /// Next step in this same todo: capture the *active window* instead of the display.
    @MainActor
    static func captureActiveDisplay() async throws -> ScreenshotCaptureResult {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw CaptureError.noScreen }
        guard let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw CaptureError.noScreen
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == screenNumber }) else {
            throw CaptureError.noDisplayMatch
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.capturesAudio = false
        config.width = scDisplay.width
        config.height = scDisplay.height

        let image = try await captureImage(contentFilter: filter, configuration: config)
        return ScreenshotCaptureResult(
            image: image,
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: screen.backingScaleFactor
        )
    }

    /// MVP: capture the active window (frontmost app) using ScreenCaptureKit desktop-independent window capture.
    @MainActor
    static func captureActiveWindow() async throws -> ScreenshotCaptureResult {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { throw CaptureError.noFrontmostApp }
        return try await captureWindow(forPID: frontmost.processIdentifier)
    }

    /// Capture window for a specific app by PID.
    /// Use this when you've already captured the target app's PID to avoid race conditions.
    @MainActor
    static func captureWindow(forPID pid: pid_t) async throws -> ScreenshotCaptureResult {
        // Get ALL windows including those on secondary displays
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)

        // Log available displays for debugging multi-monitor issues
        Log.capture.debug("Available displays: \(content.displays.map { "id=\($0.displayID) \($0.width)x\($0.height)" }.joined(separator: ", "), privacy: .public)")

        let candidates = content.windows.filter { w in
            guard let owning = w.owningApplication else { return false }
            return owning.processID == pid && w.windowLayer == 0
        }

        // Enhanced logging for multi-display debugging
        Log.capture.debug("PID \(pid): found \(candidates.count) candidate windows")
        for (i, w) in candidates.enumerated() {
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            Log.capture.debug("  [\(i)] '\(w.title ?? "untitled")' frame=\(w.frame.debugDescription) center=\(center.debugDescription) isActive=\(w.isActive) isOnScreen=\(w.isOnScreen)")
        }

        // Get current space info for debugging
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        Log.capture.debug("Mouse at \(mouseLocation.debugDescription) on screen: \(mouseScreen?.localizedName ?? "unknown")")

        // PRIORITY 1: Filter to on-screen windows first (more reliable than isActive for space switching)
        let onScreen = candidates.filter(\.isOnScreen)
        Log.capture.debug("Selection: \(onScreen.count) onScreen out of \(candidates.count) candidates")

        // PRIORITY 2: Among on-screen windows, prefer active window if available
        if let activeOnScreen = onScreen.first(where: { $0.isActive }) {
            Log.capture.info("Using active on-screen window: '\(activeOnScreen.title ?? "untitled")' frame=\(activeOnScreen.frame.debugDescription)")
            return try await captureSpecificWindow(activeOnScreen)
        }

        // PRIORITY 3: Fallback to any active window (even if not marked on-screen)
        if let activeWindow = candidates.first(where: { $0.isActive }) {
            Log.capture.info("Using active window (not on-screen): '\(activeWindow.title ?? "untitled")' frame=\(activeWindow.frame.debugDescription)")
            return try await captureSpecificWindow(activeWindow)
        }

        // PRIORITY 4: Use on-screen windows, narrow by mouse display
        var preferred = !onScreen.isEmpty ? onScreen : candidates

        Log.capture.debug("No active window found, using \(preferred.count) preferred candidates")

        // If multiple windows, prefer the one on the display with the mouse cursor
        // Use center-point matching (more reliable than frame intersection for multi-display)
        if preferred.count > 1, let mouseScreen = mouseScreen {
            Log.capture.debug("Mouse on screen: \(mouseScreen.localizedName) frame=\(mouseScreen.frame.debugDescription)")

            // Filter to windows whose CENTER is on the mouse's display
            let windowsOnMouseScreen = preferred.filter { w in
                let windowCenter = NSPoint(x: w.frame.midX, y: w.frame.midY)
                return NSPointInRect(windowCenter, mouseScreen.frame)
            }
            if !windowsOnMouseScreen.isEmpty {
                preferred = windowsOnMouseScreen
                Log.capture.debug("Narrowed to \(windowsOnMouseScreen.count) windows on mouse screen (center-point match)")
            }
        }

        guard let window = preferred.max(by: { area($0.frame) < area($1.frame) }) else {
            Log.capture.error("No frontmost window found for PID \(pid)")
            throw CaptureError.noFrontmostWindow
        }

        Log.capture.info("Selected window: '\(window.title ?? "untitled")' frame=\(window.frame.debugDescription)")
        return try await captureSpecificWindow(window)
    }

    /// Capture a specific SCWindow
    @MainActor
    private static func captureSpecificWindow(_ window: SCWindow) async throws -> ScreenshotCaptureResult {

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let pixelWidth = Int(info.contentRect.width * scale)
        let pixelHeight = Int(info.contentRect.height * scale)

        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.width = max(1, pixelWidth)
        config.height = max(1, pixelHeight)

        let image = try await captureImage(contentFilter: filter, configuration: config)
        return ScreenshotCaptureResult(
            image: image,
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: scale
        )
    }
}

private extension CaptureService {
    @MainActor
    static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: CaptureError.captureFailed)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }
}


