import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    @StateObject private var model = OnboardingViewModel()
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("grabthis")
                    .font(.system(size: 32, weight: .bold))
                Text("Hold fn, speak, get answers about your screen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // Permissions list
            ScrollView {
                VStack(spacing: 12) {
                    // Required permissions
                    PermissionCard(
                        icon: "mic.fill",
                        title: "Microphone",
                        description: "Listen to your voice",
                        status: permissionStatus(model.micStatus),
                        isGranted: model.micStatus == .authorized,
                        action: { model.requestMic() }
                    )

                    PermissionCard(
                        icon: "waveform",
                        title: "Speech Recognition",
                        description: "Transcribe what you say",
                        status: permissionStatus(model.speechStatus),
                        isGranted: model.speechStatus == .authorized,
                        action: { model.requestSpeech() }
                    )

                    PermissionCard(
                        icon: "rectangle.dashed.badge.record",
                        title: "Screen Recording",
                        description: "Capture the active window",
                        status: model.screenRecordingAllowed ? "Allowed" : "Required",
                        isGranted: model.screenRecordingAllowed,
                        action: {
                            model.requestScreenRecording()
                            SystemSettingsDeepLinks.openScreenRecording()
                        }
                    )

                    PermissionCard(
                        icon: "keyboard",
                        title: "Input Monitoring",
                        description: "Detect fn key globally",
                        status: "Open Settings",
                        isGranted: false,  // Can't easily check this
                        action: { SystemSettingsDeepLinks.openInputMonitoring() },
                        alwaysShowButton: true
                    )

                    PermissionCard(
                        icon: "hand.point.up.braille",
                        title: "Accessibility",
                        description: "Auto-paste into apps",
                        status: model.accessibilityTrusted ? "Allowed" : "Optional",
                        isGranted: model.accessibilityTrusted,
                        action: {
                            SystemSettingsDeepLinks.openAccessibility()
                            AutoInsertService.requestAccessibilityPermissionPrompt()
                        }
                    )

                    Divider()
                        .padding(.vertical, 8)

                    // Settings
                    SettingsCard(appState: appState)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer actions
            HStack {
                if !model.screenRecordingAllowed {
                    Button("Quit to Apply") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Refresh") {
                    model.refresh()
                }
                .buttonStyle(.bordered)

                Button(allRequiredGranted ? "Done" : "Continue Anyway") {
                    model.markComplete()
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 440, height: 580)
        .background(.ultraThinMaterial)
        .onAppear { model.refresh() }
    }

    private var allRequiredGranted: Bool {
        model.micStatus == .authorized
        && model.speechStatus == .authorized
        && model.screenRecordingAllowed
    }

    private func permissionStatus(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Required"
        @unknown default: return "Unknown"
        }
    }

    private func permissionStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Required"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Permission Card

private struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: String
    let isGranted: Bool
    let action: () -> Void
    var alwaysShowButton: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(isGranted ? Color.green : Color.orange)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status + Button
            if isGranted && !alwaysShowButton {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(isGranted ? "Open" : "Allow") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Settings Card

private struct SettingsCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.saveScreenshotsToHistory) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save screenshots to History")
                        .font(.subheadline)
                    Text("Screenshots will be saved alongside transcripts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
