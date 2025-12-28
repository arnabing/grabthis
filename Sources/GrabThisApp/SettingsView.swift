import AVFoundation
import Speech
import SwiftUI

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case privacy = "Privacy"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Main Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedSection: SettingsSection = .general
    @State private var selectedEngine: TranscriptionEngineType
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var screenRecordingGranted: Bool = false
    @State private var accessibilityGranted: Bool = false

    init(appState: AppState) {
        self.appState = appState
        // Load saved preference or default to Apple (On-Device)
        if let saved = UserDefaults.standard.string(forKey: "sttEngineType"),
           let type = TranscriptionEngineType(rawValue: saved) {
            _selectedEngine = State(initialValue: type)
        } else {
            _selectedEngine = State(initialValue: .speechAnalyzer)
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            // Detail view based on selection
            switch selectedSection {
            case .general:
                GeneralSettingsView(
                    appState: appState,
                    selectedEngine: $selectedEngine
                )
            case .privacy:
                PrivacySettingsView(
                    micStatus: micStatus,
                    speechStatus: speechStatus,
                    screenRecordingGranted: screenRecordingGranted,
                    accessibilityGranted: accessibilityGranted
                )
            case .about:
                AboutSettingsView()
            }
        }
        .frame(width: 520, height: 380)
        .onAppear { refreshPermissions() }
    }

    private func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        screenRecordingGranted = PermissionsService.hasScreenRecordingPermission()
        accessibilityGranted = PermissionsService.hasAccessibilityPermission()
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @Binding var selectedEngine: TranscriptionEngineType

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $selectedEngine) {
                    ForEach(TranscriptionEngineType.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedEngine) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    Log.stt.notice("⚙️ Settings: Engine changed from \(oldValue.displayName) → \(newValue.displayName)")
                    UserDefaults.standard.set(newValue.rawValue, forKey: "sttEngineType")
                    NotificationCenter.default.post(name: .sttEngineChanged, object: nil)
                }

                Text(selectedEngine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speech Recognition")
            }

            Section {
                Toggle("Save screenshots to History", isOn: $appState.saveScreenshotsToHistory)

                Text("Transcripts are always saved. Screenshots are optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Privacy Settings

private struct PrivacySettingsView: View {
    let micStatus: AVAuthorizationStatus
    let speechStatus: SFSpeechRecognizerAuthorizationStatus
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required for voice input",
                    isGranted: micStatus == .authorized,
                    action: { SystemSettingsDeepLinks.openMicrophone() }
                )

                PermissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "Required for transcription",
                    isGranted: speechStatus == .authorized,
                    action: { SystemSettingsDeepLinks.openSpeechRecognition() }
                )

                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Required for screenshots",
                    isGranted: screenRecordingGranted,
                    action: { SystemSettingsDeepLinks.openScreenRecording() }
                )

                PermissionRow(
                    icon: "hand.point.up.braille",
                    title: "Accessibility",
                    description: "Required for auto-insert",
                    isGranted: accessibilityGranted,
                    action: { SystemSettingsDeepLinks.openAccessibility() }
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Click \"Open\" to grant permissions in System Settings.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Open") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About Settings

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("App Info")
            }

            Section {
                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: AppState.Keys.onboardingCompleted)
                }
            } header: {
                Text("Debug")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
