import SwiftUI

/// Reusable permission request screen for onboarding wizard.
/// Inspired by boring.notch's sequential permission flow.
struct PermissionRequestView: View {
    let icon: String  // SF Symbol name
    let title: String
    let description: String
    let privacyNote: String?
    let isRequired: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Large icon
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.bottom, 8)

            // Title
            VStack(spacing: 4) {
                Text(title)
                    .font(.title)
                    .fontWeight(.semibold)

                if isRequired {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                } else {
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }

            // Description
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Privacy note with lock icon
            if let privacyNote {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(privacyNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                Button("Not Now") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Allow Access") {
                    onAllow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    PermissionRequestView(
        icon: "mic.fill",
        title: "Microphone Access",
        description: "grabthis needs access to your microphone to hear your voice commands.",
        privacyNote: "Audio is processed on-device and never leaves your Mac.",
        isRequired: true,
        onAllow: { },
        onSkip: { }
    )
    .frame(width: 440, height: 520)
}
