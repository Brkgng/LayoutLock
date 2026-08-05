import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.layoutlock.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let displays = Logger(subsystem: subsystem, category: "displays")
    static let entitlements = Logger(subsystem: subsystem, category: "entitlements")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let browserAutomation = Logger(subsystem: subsystem, category: "browser-automation")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
