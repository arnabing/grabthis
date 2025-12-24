import Foundation

/// Publishes a smoothed microphone level (0...1) for UI visualization.
/// IMPORTANT: `ingestFromAudioThread` is safe to call from a realtime audio tap.
@MainActor
final class AudioLevelService: ObservableObject {
    static let shared = AudioLevelService()

    @Published private(set) var level: Double = 0.0

    private var lastPublishTime: UInt64 = 0
    private var smoothed: Double = 0.0

    /// Called from the audio tap thread. Safe for realtime: does no work besides scheduling.
    nonisolated static func ingestFromAudioThread(rms: Float) {
        DispatchQueue.main.async {
            Task { @MainActor in
                AudioLevelService.shared.ingestOnMain(rms: rms)
            }
        }
    }

    /// Main-actor ingestion: throttles to ~30fps and applies smoothing.
    private func ingestOnMain(rms: Float) {
        // Convert RMS (typically 0..~1) into 0..1 range with a gentle curve.
        let raw = Double(max(0.0, min(1.0, rms)))
        // Slight non-linear boost so quiet speech still animates.
        let mapped = pow(raw, 0.55)

        let now = DispatchTime.now().uptimeNanoseconds
        // Throttle to ~30fps.
        if now &- lastPublishTime < 33_000_000 { return }
        lastPublishTime = now

        // Smooth with simple attack/release.
        let attack = 0.35
        let release = 0.12
        let coeff = mapped > smoothed ? attack : release
        smoothed = smoothed + (mapped - smoothed) * coeff
        level = smoothed
    }
}


