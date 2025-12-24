import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Enable grabthis", isOn: $appState.isEnabled)
            }

            Section("History") {
                Toggle("Save screenshots to History", isOn: $appState.saveScreenshotsToHistory)
                Text("Transcripts are saved. Screenshots are only saved if enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("By default, grabthis does not save screenshots or audio unless you choose Save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset onboarding") {
                    UserDefaults.standard.set(false, forKey: AppState.Keys.onboardingCompleted)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}


