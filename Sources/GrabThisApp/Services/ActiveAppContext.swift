import AppKit
import Foundation

struct ActiveAppContext: Equatable {
    let appName: String
    let bundleIdentifier: String?
    let pid: pid_t
}

enum ActiveAppContextProvider {
    static func current() -> ActiveAppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ActiveAppContext(
            appName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier
        )
    }
}


