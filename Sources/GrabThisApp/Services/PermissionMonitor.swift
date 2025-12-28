@preconcurrency import AVFoundation
import Foundation
import Speech

/// Monitors permission status changes using polling (boring.notch pattern).
/// Publishes changes via @Published properties and NotificationCenter.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    // MARK: - Published Permission States

    @Published private(set) var microphoneGranted = false
    @Published private(set) var speechRecognitionGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    // MARK: - Notification Names

    static let permissionsDidChange = Notification.Name("grabthis.permissionMonitor.didChange")
    static let accessibilityDidChange = Notification.Name("grabthis.permissionMonitor.accessibilityDidChange")
    static let screenRecordingDidChange = Notification.Name("grabthis.permissionMonitor.screenRecordingDidChange")

    // MARK: - Private State

    private var monitoringTask: Task<Void, Never>?
    private var lastAccessibilityState: Bool?
    private var lastScreenRecordingState: Bool?

    private init() {
        // Initial check
        refreshAll()
    }

    // MARK: - Public API

    /// Refresh all permission states immediately
    func refreshAll() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        screenRecordingGranted = PermissionsService.hasScreenRecordingPermission()
        accessibilityGranted = PermissionsService.hasAccessibilityPermission()
    }

    /// Start polling for permission changes (boring.notch pattern)
    /// - Parameter interval: Polling interval in seconds (default: 3.0)
    func startMonitoring(interval: TimeInterval = 3.0) {
        stopMonitoring()

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPermissions()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    /// Stop polling for permission changes
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    /// Check if all required permissions are granted
    var allRequiredGranted: Bool {
        microphoneGranted && speechRecognitionGranted && screenRecordingGranted
    }

    /// Check if all permissions (including optional) are granted
    var allGranted: Bool {
        allRequiredGranted && accessibilityGranted
    }

    // MARK: - Private

    private func pollPermissions() {
        let prevMic = microphoneGranted
        let prevSpeech = speechRecognitionGranted
        let prevScreen = screenRecordingGranted
        let prevAccess = accessibilityGranted

        refreshAll()

        // Detect changes and notify
        var didChange = false

        if prevMic != microphoneGranted || prevSpeech != speechRecognitionGranted {
            didChange = true
        }

        if prevScreen != screenRecordingGranted {
            didChange = true
            NotificationCenter.default.post(
                name: Self.screenRecordingDidChange,
                object: nil,
                userInfo: ["granted": screenRecordingGranted]
            )
        }

        if prevAccess != accessibilityGranted {
            didChange = true
            NotificationCenter.default.post(
                name: Self.accessibilityDidChange,
                object: nil,
                userInfo: ["granted": accessibilityGranted]
            )
        }

        if didChange {
            NotificationCenter.default.post(name: Self.permissionsDidChange, object: nil)
        }
    }
}

// MARK: - Permission Request Helpers

extension PermissionMonitor {
    /// Request microphone permission
    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Request speech recognition permission
    nonisolated func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Request screen recording permission (opens system dialog)
    func requestScreenRecording() {
        _ = PermissionsService.requestScreenRecordingPermission()
        refreshAll()
    }

    /// Request accessibility permission (opens system dialog)
    func requestAccessibility() {
        AutoInsertService.requestAccessibilityPermissionPrompt()
        refreshAll()
    }
}
