//
//  MusicVisualizer.swift
//  GrabThisApp
//
//  4-bar audio spectrum visualizer
//  Based on boring.notch's AudioSpectrum implementation
//

import AppKit
import SwiftUI

// MARK: - NSView-based Audio Spectrum

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0..<barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(0.35)  // Match boring.notch
            layer?.addSublayer(barLayer)
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBars()
            }
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }

    private func updateBars() {
        // Match boring.notch exactly
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: 0.35...1.0)
            barScales[i] = targetScale

            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true  // KEY: Makes bars bounce back
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false

            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }

            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[i] = 0.35
        }
    }

    func setPlaying(_ playing: Bool) {
        // Match boring.notch: no guard, just set directly
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

// MARK: - SwiftUI Wrapper

struct AudioSpectrumView: NSViewRepresentable {
    var isPlaying: Bool  // Plain Bool instead of @Binding for proper updates

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

// MARK: - Pure SwiftUI Visualizer (alternative)

struct MusicVisualizerView: View {
    @Binding var isPlaying: Bool
    @State private var barHeights: [CGFloat] = [0.35, 0.35, 0.35, 0.35]

    private let barCount = 4
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 14

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Color.white)
                    .frame(width: barWidth, height: maxHeight * barHeights[index])
            }
        }
        .frame(height: maxHeight)
        .onAppear {
            if isPlaying {
                startAnimation()
            }
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                startAnimation()
            } else {
                resetBars()
            }
        }
    }

    private func startAnimation() {
        guard isPlaying else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            for i in 0..<barCount {
                barHeights[i] = CGFloat.random(in: 0.35...1.0)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if isPlaying {
                startAnimation()
            }
        }
    }

    private func resetBars() {
        withAnimation(.easeInOut(duration: 0.2)) {
            for i in 0..<barCount {
                barHeights[i] = 0.35
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        Text("NSView-based (preferred)")
        AudioSpectrumView(isPlaying: true)
            .frame(width: 20, height: 14)

        Text("Pure SwiftUI")
        MusicVisualizerView(isPlaying: .constant(true))
            .frame(width: 20, height: 14)
    }
    .padding()
    .background(Color.black)
}
