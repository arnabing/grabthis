import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Keys {
        static let onboardingCompleted = "grabthis.onboardingCompleted"
    }

    @Published var isEnabled: Bool = true
}


