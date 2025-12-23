@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
final class OnboardingViewModel: ObservableObject {
    private static let permissionsDidChangeNotification = Notification.Name("grabthis.permissionsDidChange")

    @Published var micStatus: AVAuthorizationStatus
    @Published var speechStatus: SFSpeechRecognizerAuthorizationStatus
    @Published var screenRecordingAllowed: Bool
    @Published var accessibilityTrusted: Bool
    @Published var didComplete: Bool
    @Published var isBundledApp: Bool

    init() {
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.speechStatus = SFSpeechRecognizer.authorizationStatus()
        self.screenRecordingAllowed = PermissionsService.hasScreenRecordingPermission()
        self.accessibilityTrusted = PermissionsService.hasAccessibilityPermission()
        self.didComplete = UserDefaults.standard.bool(forKey: AppState.Keys.onboardingCompleted)
        self.isBundledApp = Bundle.main.bundleIdentifier != nil

        NotificationCenter.default.addObserver(
            forName: Self.permissionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isBundledApp = Bundle.main.bundleIdentifier != nil
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        screenRecordingAllowed = PermissionsService.hasScreenRecordingPermission()
        accessibilityTrusted = PermissionsService.hasAccessibilityPermission()
        didComplete = UserDefaults.standard.bool(forKey: AppState.Keys.onboardingCompleted)
    }

    func requestMic() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: Self.handleMicAuthorization(_:))
    }

    func requestSpeech() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        SFSpeechRecognizer.requestAuthorization(Self.handleSpeechAuthorization(_:))
    }

    func requestScreenRecording() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // May show system prompt; refresh afterwards.
        _ = PermissionsService.requestScreenRecordingPermission()
        refresh()
    }

    func markComplete() {
        UserDefaults.standard.set(true, forKey: AppState.Keys.onboardingCompleted)
        refresh()
    }

    // MARK: - Nonisolated callbacks (TCC may invoke on background queues)

    nonisolated private static func handleMicAuthorization(_ granted: Bool) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.permissionsDidChangeNotification, object: nil)
        }
    }

    nonisolated private static func handleSpeechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.permissionsDidChangeNotification, object: nil)
        }
    }
}


