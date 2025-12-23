import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    @StateObject private var model = OnboardingViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !model.isBundledApp {
                notBundledWarning
            }
            requirements
            actions
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .onAppear { model.refresh() }
    }
}

private extension OnboardingView {
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to grabthis")
                .font(.system(size: 26, weight: .semibold))
            Text("Hold fn, speak what you want, and get an instant answer about what’s on your screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            PermissionRow(
                title: "Microphone",
                subtitle: "Required for push-to-talk.",
                statusText: authText(for: model.micStatus),
                isGranted: model.micStatus == .authorized
            ) {
                model.requestMic()
            }
            .disabled(!model.isBundledApp)

            PermissionRow(
                title: "Speech Recognition",
                subtitle: "Used to transcribe what you say.",
                statusText: authText(for: model.speechStatus),
                isGranted: model.speechStatus == .authorized
            ) {
                model.requestSpeech()
            }
            .disabled(!model.isBundledApp)

            PermissionRow(
                title: "Screen Recording",
                subtitle: "Required for screenshots. If you enable it in System Settings, you must quit & relaunch grabthis.",
                statusText: model.screenRecordingAllowed ? "Allowed" : "Not allowed",
                isGranted: model.screenRecordingAllowed
            ) {
                model.requestScreenRecording()
            }
            .disabled(!model.isBundledApp)

            if !model.screenRecordingAllowed {
                ActionRow(
                    title: "Screen Recording Settings",
                    subtitle: "If the system prompt keeps showing, toggle grabthis ON here, then quit & relaunch.",
                    buttonTitle: "Open Settings"
                ) {
                    SystemSettingsDeepLinks.openScreenRecording()
                }
            }

            ActionRow(
                title: "Input Monitoring",
                subtitle: "Required so grabthis can detect fn/shortcuts globally while you’re in other apps.",
                buttonTitle: "Open Settings"
            ) {
                SystemSettingsDeepLinks.openInputMonitoring()
            }

            ActionRow(
                title: "Accessibility",
                subtitle: "Required to auto-insert dictated text into other apps (Wispr-like).",
                buttonTitle: "Open Settings"
            ) {
                SystemSettingsDeepLinks.openAccessibility()
                AutoInsertService.requestAccessibilityPermissionPrompt()
            }
        }
    }

    var actions: some View {
        HStack {
            Button("Refresh") { model.refresh() }

            Spacer()

            Button(model.didComplete ? "Done" : "Continue") {
                markCompleteAndClose()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isReadyToContinue)
        }
        .padding(.top, 8)
    }

    var isReadyToContinue: Bool {
        model.isBundledApp
        && model.micStatus == .authorized
        && model.speechStatus == .authorized
        && model.screenRecordingAllowed
    }

    func markCompleteAndClose() {
        model.markComplete()
        NSApp.keyWindow?.close()
    }

    func authText(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    func authText(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    var notBundledWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run the bundled app to grant permissions")
                .font(.subheadline.weight(.semibold))
            Text("You’re currently running a raw executable (Bundle ID is nil). macOS privacy prompts (Mic/Speech/Screen Recording/Input Monitoring) may fail or crash. Please run the packaged .app from the build script.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let statusText: String
    let isGranted: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(isGranted ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button(isGranted ? "Granted" : "Allow") { request() }
                .buttonStyle(.bordered)
                .disabled(isGranted)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ActionRow: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.blue.opacity(0.9))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(buttonTitle) { action() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}


