import SwiftUI

/// Compact waveform visualizer for batch recording mode (WhisperKit).
/// Shows 12 animated bars that respond to audio level with organic motion.
struct CompactWaveformView: View {
    let audioLevel: Double  // 0...1
    let barCount: Int

    @State private var tick: Int = 0
    let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    // Pre-computed per-bar randomness for organic look (seeded by index)
    private let barSeeds: [Double]

    init(audioLevel: Double, barCount: Int = 12) {
        self.audioLevel = audioLevel
        self.barCount = barCount
        // Generate deterministic but varied seeds per bar
        self.barSeeds = (0..<barCount).map { i in
            let seed = sin(Double(i) * 1.618 + 0.5) * 0.5 + 0.5  // Golden ratio for nice spread
            return seed
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.9),
                                Color.blue.opacity(0.7)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2, height: barHeight(for: index))
            }
        }
        .frame(height: 14)  // Match notch peek height
        .animation(.easeOut(duration: 0.06), value: tick)
        .onReceive(timer) { _ in
            tick += 1
        }
    }

    /// Calculate bar height - EXAGGERATED peaks and valleys
    private func barHeight(for index: Int) -> CGFloat {
        let seed = barSeeds[index]

        // Multiple wave frequencies for organic motion
        let slowWave = sin(Double(index) * 0.5 + Double(tick) * 0.15)
        let fastWave = sin(Double(index) * 1.2 + Double(tick) * 0.4 + seed * 3.14)
        let waveBlend = (slowWave * 0.6 + fastWave * 0.4) * 0.5 + 0.5  // 0-1 range

        // Very aggressive boost - make even quiet speech visible
        let boostedAudio = min(1.0, audioLevel * 10.0)

        // EXAGGERATED: tiny when silent (2pt), full height when speaking (14pt)
        // Use pow() to create sharper peaks - some bars very short, some very tall
        let peakVariation = pow(waveBlend, 0.7)  // Sharpen the wave for more dramatic peaks
        let idleHeight = 2.0 + waveBlend * 0.5  // 2-2.5pt when silent (almost static)
        let voiceHeight = 2.0 + boostedAudio * 12.0 * peakVariation  // 2-14pt with sharp peaks

        // Instant crossfade - voice takes over immediately
        let voiceInfluence = min(1.0, boostedAudio * 4.0)
        let height = idleHeight * (1.0 - voiceInfluence) + voiceHeight * voiceInfluence

        return max(2, min(14, height))
    }
}

#Preview {
    VStack(spacing: 20) {
        // Low level
        CompactWaveformView(audioLevel: 0.1)
            .background(Color.black)

        // Medium level
        CompactWaveformView(audioLevel: 0.5)
            .background(Color.black)

        // High level
        CompactWaveformView(audioLevel: 0.9)
            .background(Color.black)
    }
    .padding()
    .background(Color.gray)
}
