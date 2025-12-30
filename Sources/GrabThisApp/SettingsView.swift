import AVFoundation
import Speech
import SwiftUI

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case media = "Media"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .media: return "play.laptopcomputer"
        case .permissions: return "lock.shield"
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
        // Load saved preference, validating it's available on this macOS version
        if let saved = UserDefaults.standard.string(forKey: "sttEngineType"),
           let type = TranscriptionEngineType(rawValue: saved),
           type.isAvailable {
            _selectedEngine = State(initialValue: type)
        } else {
            // Default to best available engine
            _selectedEngine = State(initialValue: TranscriptionEngineType.availableCases.first ?? .sfSpeech)
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar - system handles Liquid Glass automatically
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            // Detail view - let system handle background
            switch selectedSection {
            case .general:
                GeneralSettingsView(
                    appState: appState,
                    selectedEngine: $selectedEngine
                )
            case .media:
                MediaSettingsView()
            case .permissions:
                PermissionsSettingsView(
                    micStatus: micStatus,
                    speechStatus: speechStatus,
                    screenRecordingGranted: screenRecordingGranted,
                    accessibilityGranted: accessibilityGranted,
                    onRefresh: { refreshPermissions() }
                )
            case .about:
                AboutSettingsView()
            }
        }
        .frame(width: 520, height: 480)
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
                    ForEach(TranscriptionEngineType.availableCases) { engine in
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

// MARK: - Media Settings

private struct MediaSettingsView: View {
    @AppStorage("nowPlayingEnabled") private var nowPlayingEnabled: Bool = true
    @AppStorage("autoPauseMusicDuringDictation") private var autoPauseDuringDictation: Bool = true
    @ObservedObject private var nowPlaying = NowPlayingService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Now Playing", isOn: $nowPlayingEnabled.animation())

                Text("Display music controls when Apple Music or Spotify is playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Now Playing")
            }

            Section {
                Toggle("Pause music during dictation", isOn: $autoPauseDuringDictation)

                Text("Automatically pause and resume music when dictating. Prevents Bluetooth audio quality degradation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Dictation")
            }

            Section {
                // Status indicator
                HStack {
                    Text("Status")
                    Spacer()
                    if nowPlaying.hasActivePlayer {
                        Label(nowPlaying.isPlaying ? "Playing" : "Paused", systemImage: nowPlaying.isPlaying ? "play.fill" : "pause.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("No media detected")
                            .foregroundStyle(.secondary)
                    }
                }

                if nowPlaying.hasActivePlayer {
                    HStack {
                        Text("Track")
                        Spacer()
                        Text(nowPlaying.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("Artist")
                        Spacer()
                        Text(nowPlaying.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Debug Info")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Permissions Settings

private struct PermissionsSettingsView: View {
    let micStatus: AVAuthorizationStatus
    let speechStatus: SFSpeechRecognizerAuthorizationStatus
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let onRefresh: () -> Void

    /// Count of required permissions (excludes optional Automation)
    private var grantedCount: Int {
        var count = 0
        if micStatus == .authorized { count += 1 }
        if speechStatus == .authorized { count += 1 }
        if screenRecordingGranted { count += 1 }
        if accessibilityGranted { count += 1 }
        return count
    }

    private var allGranted: Bool { grantedCount == 4 }

    var body: some View {
        Form {
            // Status summary with action buttons
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(grantedCount) of 4 required permissions")
                            .font(.headline)
                        Text(allGranted ? "All set!" : "Some permissions are missing")
                            .font(.caption)
                            .foregroundStyle(allGranted ? .green : .orange)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button("Refresh") {
                            onRefresh()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !allGranted {
                            Button("Open Settings") {
                                openFirstMissingPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

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
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    /// Opens System Settings for the first missing required permission (excludes optional Automation)
    private func openFirstMissingPermission() {
        if micStatus != .authorized {
            SystemSettingsDeepLinks.openMicrophone()
        } else if speechStatus != .authorized {
            SystemSettingsDeepLinks.openSpeechRecognition()
        } else if !screenRecordingGranted {
            SystemSettingsDeepLinks.openScreenRecording()
        } else if !accessibilityGranted {
            SystemSettingsDeepLinks.openAccessibility()
        }
        // Automation is optional, so we don't navigate to it automatically
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built by Arnab Raychaudhuri")
                        .fontWeight(.medium)

                    Link(destination: URL(string: "https://www.linkedin.com/in/arnabing/")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.caption)
                            Text("linkedin.com/in/arnabing")
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Developer")
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
