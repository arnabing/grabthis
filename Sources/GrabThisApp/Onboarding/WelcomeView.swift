import SwiftUI

/// Welcome screen shown at the start of onboarding.
/// Introduces the app and invites the user to begin setup.
struct WelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon and title
            VStack(spacing: 16) {
                // Animated gradient icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.3), .blue.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)

                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text("grabthis")
                    .font(.system(size: 36, weight: .bold))

                Text("Hold fn, speak, get answers")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // Feature highlights
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "mic.fill",
                    title: "Voice-First",
                    description: "Just hold fn and speak naturally"
                )
                FeatureRow(
                    icon: "camera.viewfinder",
                    title: "Context-Aware",
                    description: "AI sees your screen for better answers"
                )
                FeatureRow(
                    icon: "sparkles",
                    title: "Instant Answers",
                    description: "Powered by Gemini 2.5 Flash"
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // Get Started button
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: { })
        .frame(width: 440, height: 520)
}
