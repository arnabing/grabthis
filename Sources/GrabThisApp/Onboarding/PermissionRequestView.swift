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
    var buttonText: String = "Open Settings"  // Clearer default text
    var showInstructions: Bool = true  // Show step-by-step instructions

    var body: some View {
        VStack(spacing: 24) {
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
                .padding(.bottom, 4)

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

            // Step-by-step instructions
            if showInstructions {
                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(step: 1, text: "Click '\(buttonText)' below")
                    instructionRow(step: 2, text: "Find 'GrabThisApp' in the list")
                    instructionRow(step: 3, text: "Toggle the switch ON")
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

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
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                Button("Skip") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onAllow) {
                    HStack(spacing: 6) {
                        Text(buttonText)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func instructionRow(step: Int, text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(step)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
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
