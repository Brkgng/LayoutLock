import AppKit
import Foundation

enum BrowserWindowOpenResult {
    case opened(CapturedBrowserWindow)
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
            let descriptor = try scriptEvaluator.evaluate(
                Self.script(
                    for: browser,
                    targets: targets,
                    reuseDisposableStartupWindow: !wasRunning
                )
            )
            guard let openedWindow = try BrowserScriptResultParser()
                .parse(descriptor, browser: browser)
                .first else {
                return .failed
            }
            return .opened(openedWindow)
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
        reuseDisposableStartupWindow: Bool = false
    ) -> String {
        let URLs = targets.map { appleScriptLiteral($0.url.absoluteString) }
        let URLList = "{\(URLs.joined(separator: ", "))}"

        switch browser {
        case .safari:
            let selectTargetWindow = reuseDisposableStartupWindow
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
                set capturedTabs to {}
                repeat with browserTab in tabs of targetWindow
                    set tabURL to URL of browserTab
                    if tabURL is missing value then set tabURL to ""
                    set tabTitle to name of browserTab
                    if tabTitle is missing value then set tabTitle to ""
                    set end of capturedTabs to {tabTitle as text, tabURL as text}
                end repeat
                set windowBounds to bounds of targetWindow
                set normalizedBounds to {item 1 of windowBounds, item 2 of windowBounds, item 3 of windowBounds, item 4 of windowBounds}
                return {{(id of targetWindow) as text, (name of targetWindow) as text, normalizedBounds, capturedTabs}}
            end tell
            """
        case .chrome:
            let selectTargetWindow = reuseDisposableStartupWindow
                ? """
                set shouldReuseFrontWindow to false
                if (count windows) is 1 then
                    set candidateWindow to front window
                    if (mode of candidateWindow) is "normal" and (count tabs of candidateWindow) is 1 then
                        set candidateURL to URL of active tab of candidateWindow
                        if candidateURL is missing value then
                            set shouldReuseFrontWindow to true
                        else
                            set candidateURLText to candidateURL as text
                            if candidateURLText is "" or candidateURLText starts with "chrome://newtab" then
                                set shouldReuseFrontWindow to true
                            end if
                        end if
                    end if
                end if

                if shouldReuseFrontWindow then
                    set targetWindow to candidateWindow
                else
                    set targetWindow to make new window with properties {mode:"normal"}
                end if
                """
                : """
                set targetWindow to make new window with properties {mode:"normal"}
                """
            return """
            set targetURLs to \(URLList)
            tell application id "com.google.Chrome"
                \(selectTargetWindow)
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
                set capturedTabs to {}
                repeat with browserTab in tabs of targetWindow
                    set tabURL to URL of browserTab
                    if tabURL is missing value then set tabURL to ""
                    set tabTitle to title of browserTab
                    if tabTitle is missing value then set tabTitle to ""
                    set end of capturedTabs to {tabTitle as text, tabURL as text}
                end repeat
                set windowBounds to bounds of targetWindow
                set normalizedBounds to {item 1 of windowBounds, item 2 of windowBounds, item 3 of windowBounds, item 4 of windowBounds}
                return {{(id of targetWindow) as text, (name of targetWindow) as text, normalizedBounds, capturedTabs}}
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
