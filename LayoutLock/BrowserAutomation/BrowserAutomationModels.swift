import AppKit
import CoreGraphics
import Foundation

enum BrowserAutomationBrowser: String, CaseIterable, Identifiable {
    case safari
    case chrome
    case brave

    var isChromium: Bool { self != .safari }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari:
            return "Safari"
        case .chrome:
            return "Google Chrome"
        case .brave:
            return "Brave Browser"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari:
            return "com.apple.Safari"
        case .chrome:
            return "com.google.Chrome"
        case .brave:
            return "com.brave.Browser"
        }
    }

    var systemImage: String {
        switch self {
        case .safari:
            return "safari"
        case .chrome, .brave:
            return "globe"
        }
    }
}

enum BrowserAutomationConnectionState: Equatable {
    case notInstalled
    case notConnected
    case connected
    case permissionDenied
    case revoked

    var title: String {
        switch self {
        case .notInstalled:
            return "Not Installed"
        case .notConnected:
            return "Not Connected"
        case .connected:
            return "Connected"
        case .permissionDenied:
            return "Permission Denied"
        case .revoked:
            return "Revoked"
        }
    }
}

struct BrowserAutomationStatus: Equatable {
    let browser: BrowserAutomationBrowser
    let connectionState: BrowserAutomationConnectionState
    let isRunning: Bool
    let isWorking: Bool
    let message: String?

    var canConnect: Bool {
        connectionState != .notInstalled && isRunning && !isWorking
    }

    var canDisconnect: Bool {
        connectionState == .connected && !isWorking
    }

    var canOpenAutomationSettings: Bool {
        connectionState == .permissionDenied || connectionState == .revoked
    }
}

struct CapturedBrowserWindow: Equatable {
    let browser: BrowserAutomationBrowser
    let scriptingIdentifier: String?
    let title: String?
    let frame: CGRect
    let frontToBackIndex: Int
    let tabs: [CapturedBrowserTab]
    var selectedTabIndex: Int? = nil
}

struct CapturedBrowserTab: Equatable {
    let title: String?
    let URL: URL
}

enum BrowserCaptureIssueReason: String, Equatable {
    case permissionDenied
    case permissionRevoked
    case queryFailed
    case ambiguousWindowMatch
}

struct BrowserCaptureIssue: Equatable {
    let browser: BrowserAutomationBrowser
    let reason: BrowserCaptureIssueReason

    var message: String {
        switch reason {
        case .permissionDenied:
            return "\(browser.displayName) tabs were not captured because Automation access has not been granted."
        case .permissionRevoked:
            return "\(browser.displayName) tabs were not captured because Automation access was revoked."
        case .queryFailed:
            return "\(browser.displayName) tabs could not be captured."
        case .ambiguousWindowMatch:
            return "Some \(browser.displayName) tabs could not be assigned to the correct window."
        }
    }
}

struct BrowserTabCaptureResult {
    let windows: [CapturedBrowserWindow]
    let issues: [BrowserCaptureIssue]

    static let empty = BrowserTabCaptureResult(windows: [], issues: [])
}
