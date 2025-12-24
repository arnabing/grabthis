import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Keys {
        static let onboardingCompleted = "grabthis.onboardingCompleted"
        static let saveScreenshotsToHistory = "grabthis.saveScreenshotsToHistory"
        static let notchGapWidth = "grabthis.notchGapWidth"
    }

    @Published var isEnabled: Bool = true
    @Published var saveScreenshotsToHistory: Bool = UserDefaults.standard.bool(forKey: Keys.saveScreenshotsToHistory) {
        didSet { UserDefaults.standard.set(saveScreenshotsToHistory, forKey: Keys.saveScreenshotsToHistory) }
    }

    /// Approximate width (pt) of the non-renderable notch cutout. Adjustable per device.
    @Published var notchGapWidth: Double = {
        let v = UserDefaults.standard.double(forKey: Keys.notchGapWidth)
        return v > 0 ? v : 170
    }() {
        didSet { UserDefaults.standard.set(notchGapWidth, forKey: Keys.notchGapWidth) }
    }
}


