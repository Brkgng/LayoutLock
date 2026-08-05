import AppKit
import Foundation

enum BrowserWindowOpenResult {
    case opened
    case unavailable
    case failed
}

protocol BrowserWindowOpening {
    func openNewWindow(
        targets: [WindowOpenTarget],
        browser: BrowserAutomationBrowser
    ) async -> BrowserWindowOpenResult
}

struct BrowserAutomationWindowOpener: BrowserWindowOpening {
    private let userDefaults: UserDefaults
    private let permissionChecker: BrowserAutomationPermissionChecking
    private let scriptEvaluator: BrowserScriptEvaluating
    private let applicationURLProvider: (String) -> URL?
    private let runningApplicationProvider: (String) -> Bool
    private let applicationLauncher: (URL) async -> Bool
    private let launchPollSleeper: (TimeInterval) async -> Void

    init(
        userDefaults: UserDefaults = .standard,
        permissionChecker: BrowserAutomationPermissionChecking =
            BrowserAutomationPermissionChecker(),
        scriptEvaluator: BrowserScriptEvaluating = NSAppleScriptEvaluator(),
        workspace: NSWorkspace = .shared,
        applicationURLProvider: ((String) -> URL?)? = nil,
        runningApplicationProvider: ((String) -> Bool)? = nil,
        applicationLauncher: ((URL) async -> Bool)? = nil,
        launchPollSleeper: @escaping (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) {
        self.userDefaults = userDefaults
        self.permissionChecker = permissionChecker
        self.scriptEvaluator = scriptEvaluator
        self.applicationURLProvider = applicationURLProvider ?? {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        self.runningApplicationProvider = runningApplicationProvider ?? { bundleIdentifier in
            workspace.runningApplications.contains {
                $0.bundleIdentifier == bundleIdentifier
            }
        }
        self.applicationLauncher = applicationLauncher ?? { applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            return await withCheckedContinuation { continuation in
                workspace.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
        self.launchPollSleeper = launchPollSleeper
    }

    func openNewWindow(
        targets: [WindowOpenTarget],
        browser: BrowserAutomationBrowser
    ) async -> BrowserWindowOpenResult {
        guard !targets.isEmpty,
              targets.allSatisfy({ $0.kind == .webURL }),
              userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
              ),
              userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
              ),
              !userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
              ) else {
            return .unavailable
        }

        let wasRunning = runningApplicationProvider(browser.bundleIdentifier)
        if !wasRunning {
            guard let applicationURL = applicationURLProvider(browser.bundleIdentifier),
                  await applicationLauncher(applicationURL),
                  await waitUntilRunning(browser) else {
                return .failed
            }
        }

        guard permissionChecker.status(
            for: browser,
            askUserIfNeeded: false
        ) == .authorized else {
            return .unavailable
        }

        do {
            _ = try scriptEvaluator.evaluate(
                Self.script(
                    for: browser,
                    targets: targets,
                    reuseDisposableSafariWindow: browser == .safari && !wasRunning
                )
            )
            return .opened
        } catch {
            AppLogger.browserAutomation.error(
                "\(browser.displayName, privacy: .public) window restore failed."
            )
            return .failed
        }
    }

    static func script(
        for browser: BrowserAutomationBrowser,
        targets: [WindowOpenTarget],
        reuseDisposableSafariWindow: Bool = false
    ) -> String {
        let URLs = targets.map { appleScriptLiteral($0.url.absoluteString) }
        let URLList = "{\(URLs.joined(separator: ", "))}"

        switch browser {
        case .safari:
            let selectTargetWindow = reuseDisposableSafariWindow
                ? """
                set shouldReuseFrontWindow to false
                if (count windows) > 0 then
                    set candidateWindow to front window
                    if (count tabs of candidateWindow) is 1 then
                        set candidateURL to URL of current tab of candidateWindow
                        if candidateURL is missing value then
                            set shouldReuseFrontWindow to true
                        else
                            set candidateURLText to candidateURL as text
                            if candidateURLText is "" or candidateURLText is "about:blank" or candidateURLText starts with "favorites://" then
                                set shouldReuseFrontWindow to true
                            end if
                        end if
                    end if
                end if

                if shouldReuseFrontWindow then
                    set targetWindow to candidateWindow
                else
                    make new document
                    set targetWindow to front window
                end if
                """
                : """
                make new document
                set targetWindow to front window
                """
            return """
            set targetURLs to \(URLList)
            tell application id "com.apple.Safari"
                \(selectTargetWindow)
                set URL of current tab of targetWindow to item 1 of targetURLs
                if (count targetURLs) > 1 then
                    repeat with tabIndex from 2 to count targetURLs
                        set tabURL to item tabIndex of targetURLs
                        tell targetWindow
                            make new tab at end of tabs with properties {URL:tabURL as text}
                        end tell
                    end repeat
                end if
                set current tab of targetWindow to tab 1 of targetWindow
            end tell
            """
        case .chrome:
            return """
            set targetURLs to \(URLList)
            tell application id "com.google.Chrome"
                set targetWindow to make new window with properties {mode:"normal"}
                set URL of active tab of targetWindow to item 1 of targetURLs
                if (count targetURLs) > 1 then
                    repeat with tabIndex from 2 to count targetURLs
                        set tabURL to item tabIndex of targetURLs
                        tell targetWindow
                            make new tab at end of tabs with properties {URL:tabURL as text}
                        end tell
                    end repeat
                end if
                set active tab index of targetWindow to 1
            end tell
            """
        }
    }

    private func waitUntilRunning(
        _ browser: BrowserAutomationBrowser
    ) async -> Bool {
        for _ in 0..<50 {
            if runningApplicationProvider(browser.bundleIdentifier) {
                return true
            }
            await launchPollSleeper(0.1)
        }
        return runningApplicationProvider(browser.bundleIdentifier)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
