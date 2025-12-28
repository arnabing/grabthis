import SwiftUI

/// Finish screen shown at the end of onboarding.
/// Celebrates completion and offers quick actions.
struct OnboardingFinishView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    @State private var showCheckmark = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated checkmark
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.3), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulseScale)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1.0 : 0.0)
            }
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    showCheckmark = true
                }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseScale = 1.05
                }
            }

            // Title
            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Description
            Text("Hold fn anytime to start talking.\nYour screen will be captured for context.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Quick tips
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "fn", text: "Hold fn to record, release to process")
                TipRow(icon: "keyboard", text: "Press fn twice quickly to cancel")
                TipRow(icon: "menubar.rectangle", text: "Click the menu bar icon for history")
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onFinish) {
                    Text("Start Using grabthis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.cyan)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    OnboardingFinishView(
        onFinish: { },
        onOpenSettings: { }
    )
    .frame(width: 440, height: 580)
}
