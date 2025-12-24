import Foundation
import OSLog

enum Log {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "grabthis"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let autoInsert = Logger(subsystem: subsystem, category: "autoInsert")
    static let session = Logger(subsystem: subsystem, category: "session")
}


