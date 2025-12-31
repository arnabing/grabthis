import AVFoundation
import Speech
import SwiftUI

/// Sequential onboarding wizard (boring.notch pattern)
struct OnboardingView: View {
    @StateObject private var model = OnboardingViewModel()

    var body: some View {
        ZStack {
            // Step content with transitions
            stepContent
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(model.currentStep)  // Force view identity change for transition
        }
        .frame(width: 440, height: 520)
        .background(.ultraThinMaterial)
        .onAppear {
            model.refresh()
        }
        // Auto-skip already granted permissions
        .onChange(of: model.currentStep) { _, newStep in
            autoSkipIfGranted(step: newStep)
        }
    }

    /// Auto-advance past steps where permission is already granted
    private func autoSkipIfGranted(step: OnboardingStep) {
        // Small delay to show the transition, then skip if granted
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            model.refresh()  // Ensure latest state

            switch step {
            case .microphone:
                if model.micStatus == .authorized {
                    model.nextStep()
                }
            case .speechRecognition:
                if model.speechStatus == .authorized {
                    model.nextStep()
                }
            case .screenRecording:
                if model.screenRecordingAllowed {
                    model.nextStep()
                }
            case .accessibility:
                if model.accessibilityTrusted {
                    model.nextStep()
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.currentStep {
        case .welcome:
            WelcomeView(onGetStarted: { model.nextStep() })

        case .microphone:
            PermissionRequestView(
                icon: "mic.fill",
                title: "Microphone Access",
                description: "grabthis listens to your voice when you hold the fn key. Your audio is processed on-device for transcription.",
                privacyNote: "Audio never leaves your Mac. We use Apple's Speech Recognition.",
                isRequired: true,
                onAllow: {
                    Task {
                        let granted = await model.requestMic()
                        if !granted {
                            // If not granted, open System Settings
                            SystemSettingsDeepLinks.openMicrophone()
                        } else {
                            model.nextStep()
                        }
                    }
                },
                onSkip: { model.nextStep() },
                buttonText: "Allow Microphone",
                showInstructions: false  // System dialog handles this
            )

        case .speechRecognition:
            PermissionRequestView(
                icon: "waveform",
                title: "Speech Recognition",
                description: "Convert your voice into text using Apple's on-device speech recognition engine.",
                privacyNote: "Transcription happens locally on your Mac.",
                isRequired: true,
                onAllow: {
                    Task {
                        let granted = await model.requestSpeech()
                        if !granted {
                            // If not granted, open System Settings
                            SystemSettingsDeepLinks.openSpeechRecognition()
                        } else {
                            model.nextStep()
                        }
                    }
                },
                onSkip: { model.nextStep() },
                buttonText: "Allow Speech",
                showInstructions: false  // System dialog handles this
            )

        case .screenRecording:
            // Screen Recording has special handling - show different UI based on permission state
            if model.screenRecordingAllowed {
                // Already granted - show success view
                ScreenRecordingGrantedView(onContinue: { model.nextStep() })
            } else {
                PermissionRequestView(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Capture the active window so AI can see what you're looking at and provide contextual answers.",
                    privacyNote: "Screenshots are captured only when you hold fn to dictate.",
                    isRequired: true,
                    onAllow: {
                        model.requestScreenRecording()
                        // Don't auto-advance - user needs to grant in System Settings
                    },
                    onSkip: { model.nextStep() },
                    buttonText: "Open Settings"
                )
                .overlay(alignment: .bottom) {
                    // Extra guidance for Screen Recording
                    VStack(spacing: 8) {
                        Text("After enabling, you may need to quit & relaunch grabthis")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack(spacing: 12) {
                            Button(action: { model.refresh() }) {
                                Label("Check Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            Button("Continue →") { model.nextStep() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 120)
                }
            }

        case .inputMonitoring:
            PermissionRequestView(
                icon: "keyboard",
                title: "Input Monitoring",
                description: "Detect when you press the fn key from anywhere on your Mac, even when grabthis isn't focused.",
                privacyNote: "We only detect the fn key. No other keystrokes are monitored.",
                isRequired: false,
                onAllow: {
                    model.openInputMonitoring()
                    // Can't detect this permission, so just move on after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        model.nextStep()
                    }
                },
                onSkip: { model.nextStep() },
                buttonText: "Open Settings"
            )

        case .accessibility:
            PermissionRequestView(
                icon: "hand.point.up.braille",
                title: "Accessibility",
                description: "Allow grabthis to automatically paste AI responses into the app you're using.",
                privacyNote: "Used only for pasting text. No other actions are performed.",
                isRequired: false,
                onAllow: {
                    model.requestAccessibility()
                    // Small delay so user sees the system prompt
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        model.nextStep()
                    }
                },
                onSkip: { model.nextStep() },
                buttonText: "Open Settings"
            )

        case .finished:
            OnboardingFinishView(
                onFinish: {
                    model.markComplete()
                    NSApp.keyWindow?.close()
                },
                onOpenSettings: {
                    model.markComplete()
                    // Keep window open but could open settings
                    NSApp.keyWindow?.close()
                    // Could add: openSettings()
                }
            )
        }
    }
}

// MARK: - Legacy Permission Card (kept for Settings view)

struct PermissionCard: View {
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

// MARK: - Screen Recording Granted View

/// Shown when screen recording permission is already granted
private struct ScreenRecordingGrantedView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Success icon
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.bottom, 8)

            // Title with checkmark
            VStack(spacing: 8) {
                Text("Screen Recording")
                    .font(.title)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Enabled")
                        .foregroundStyle(.green)
                }
                .font(.subheadline.weight(.medium))
            }

            Text("grabthis can now capture your screen to provide contextual AI answers.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            // Continue button
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    OnboardingView()
}
