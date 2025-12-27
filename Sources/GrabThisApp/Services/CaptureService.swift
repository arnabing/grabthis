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
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { w in
            guard let owning = w.owningApplication else { return false }
            return owning.processID == pid && w.windowLayer == 0
        }

        let active = candidates.filter(\.isActive)
        let onScreen = candidates.filter(\.isOnScreen)
        let preferred = (!active.isEmpty ? active : (!onScreen.isEmpty ? onScreen : candidates))

        guard let window = preferred.max(by: { area($0.frame) < area($1.frame) }) else {
            throw CaptureError.noFrontmostWindow
        }

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


