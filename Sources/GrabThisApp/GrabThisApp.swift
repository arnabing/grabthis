import SwiftUI

@main
struct GrabThisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Settings {
            SettingsView(appState: appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) { }
        }
    }
}


