import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Keys {
        static let onboardingCompleted = "grabthis.onboardingCompleted"
        static let saveScreenshotsToHistory = "grabthis.saveScreenshotsToHistory"
    }

    @Published var isEnabled: Bool = true
    @Published var saveScreenshotsToHistory: Bool = {
        // Default to true for new users (UserDefaults returns false if key doesn't exist)
        if UserDefaults.standard.object(forKey: Keys.saveScreenshotsToHistory) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Keys.saveScreenshotsToHistory)
    }() {
        didSet { UserDefaults.standard.set(saveScreenshotsToHistory, forKey: Keys.saveScreenshotsToHistory) }
    }
}


