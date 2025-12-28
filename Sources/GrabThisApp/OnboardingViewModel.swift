@preconcurrency import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Steps in the onboarding wizard
enum OnboardingStep: CaseIterable {
    case welcome
    case microphone        // Required
    case speechRecognition // Required
    case screenRecording   // Required
    case inputMonitoring   // Optional
    case accessibility     // Optional
    case finished
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    // MARK: - Step Management

    @Published var currentStep: OnboardingStep = .welcome

    // MARK: - Permission States

    @Published var micStatus: AVAuthorizationStatus
    @Published var speechStatus: SFSpeechRecognizerAuthorizationStatus
    @Published var screenRecordingAllowed: Bool
    @Published var accessibilityTrusted: Bool
    @Published var didComplete: Bool
    @Published var isBundledApp: Bool

    // MARK: - Init

    init() {
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.speechStatus = SFSpeechRecognizer.authorizationStatus()
        self.screenRecordingAllowed = PermissionsService.hasScreenRecordingPermission()
        self.accessibilityTrusted = PermissionsService.hasAccessibilityPermission()
        self.didComplete = UserDefaults.standard.bool(forKey: AppState.Keys.onboardingCompleted)
        self.isBundledApp = Bundle.main.bundleIdentifier != nil

        // Start permission monitoring
        PermissionMonitor.shared.startMonitoring(interval: 2.0)

        // Listen for permission changes
        NotificationCenter.default.addObserver(
            forName: PermissionMonitor.permissionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        Task { @MainActor in
            PermissionMonitor.shared.stopMonitoring()
        }
    }

    // MARK: - Step Navigation

    func nextStep() {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              currentIndex < OnboardingStep.allCases.count - 1 else {
            return
        }
        let next = OnboardingStep.allCases[currentIndex + 1]
        withAnimation(.easeInOut(duration: 0.4)) {
            currentStep = next
        }
    }

    func previousStep() {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              currentIndex > 0 else {
            return
        }
        let prev = OnboardingStep.allCases[currentIndex - 1]
        withAnimation(.easeInOut(duration: 0.4)) {
            currentStep = prev
        }
    }

    func goToStep(_ step: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.4)) {
            currentStep = step
        }
    }

    // MARK: - Status Helpers

    var allRequiredGranted: Bool {
        micStatus == .authorized
        && speechStatus == .authorized
        && screenRecordingAllowed
    }

    var stepProgress: Double {
        guard let index = OnboardingStep.allCases.firstIndex(of: currentStep) else { return 0 }
        return Double(index) / Double(OnboardingStep.allCases.count - 1)
    }

    // MARK: - Refresh

    func refresh() {
        isBundledApp = Bundle.main.bundleIdentifier != nil
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        screenRecordingAllowed = PermissionsService.hasScreenRecordingPermission()
        accessibilityTrusted = PermissionsService.hasAccessibilityPermission()
        didComplete = UserDefaults.standard.bool(forKey: AppState.Keys.onboardingCompleted)
    }

    // MARK: - Permission Requests

    @discardableResult
    func requestMic() async -> Bool {
        guard isBundledApp else { return false }
        let granted = await PermissionMonitor.shared.requestMicrophone()
        refresh()
        return granted
    }

    @discardableResult
    func requestSpeech() async -> Bool {
        guard isBundledApp else { return false }
        let granted = await PermissionMonitor.shared.requestSpeechRecognition()
        refresh()
        return granted
    }

    func requestScreenRecording() {
        guard isBundledApp else { return }
        PermissionMonitor.shared.requestScreenRecording()
        SystemSettingsDeepLinks.openScreenRecording()
        refresh()
    }

    func requestAccessibility() {
        PermissionMonitor.shared.requestAccessibility()
        SystemSettingsDeepLinks.openAccessibility()
        refresh()
    }

    func openInputMonitoring() {
        SystemSettingsDeepLinks.openInputMonitoring()
    }

    // MARK: - Completion

    func markComplete() {
        UserDefaults.standard.set(true, forKey: AppState.Keys.onboardingCompleted)
        PermissionMonitor.shared.stopMonitoring()
        refresh()
    }

    func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: AppState.Keys.onboardingCompleted)
        currentStep = .welcome
        refresh()
    }
}


