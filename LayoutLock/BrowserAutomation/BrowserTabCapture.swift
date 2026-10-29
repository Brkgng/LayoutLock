import AppKit
import Foundation

protocol BrowserTabCapturing {
    func captureTabs(
        runningApplications: [RunningApplicationSnapshot]
    ) -> BrowserTabCaptureResult
}

protocol BrowserScriptEvaluating {
    func evaluate(_ source: String) throws -> NSAppleEventDescriptor
}

struct BrowserScriptEvaluationError: LocalizedError {
    let errorDescription: String?
}

struct NSAppleScriptEvaluator: BrowserScriptEvaluating {
    func evaluate(_ source: String) throws -> NSAppleEventDescriptor {
        if Thread.isMainThread {
            return try evaluateOnMainThread(source)
        }

        return try DispatchQueue.main.sync {
            try evaluateOnMainThread(source)
        }
    }

    private func evaluateOnMainThread(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw BrowserScriptEvaluationError(errorDescription: "The browser script could not be created.")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            throw BrowserScriptEvaluationError(
                errorDescription: message ?? "The browser script could not be executed."
            )
        }
        return result
    }
}

struct BrowserTabCaptureService: BrowserTabCapturing {
    private let userDefaults: UserDefaults
    private let permissionChecker: BrowserAutomationPermissionChecking
    private let scriptEvaluator: BrowserScriptEvaluating

    init(
        userDefaults: UserDefaults = .standard,
        permissionChecker: BrowserAutomationPermissionChecking = BrowserAutomationPermissionChecker(),
        scriptEvaluator: BrowserScriptEvaluating = NSAppleScriptEvaluator()
    ) {
        self.userDefaults = userDefaults
        self.permissionChecker = permissionChecker
        self.scriptEvaluator = scriptEvaluator
    }

    func captureTabs(
        runningApplications: [RunningApplicationSnapshot]
    ) -> BrowserTabCaptureResult {
        let runningBundleIdentifiers = Set(runningApplications.compactMap(\.bundleIdentifier))
        var windows: [CapturedBrowserWindow] = []
        var issues: [BrowserCaptureIssue] = []

        for browser in BrowserAutomationBrowser.allCases {
            guard userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
            ),
            runningBundleIdentifiers.contains(browser.bundleIdentifier) else {
                continue
            }

            switch permissionChecker.status(for: browser, askUserIfNeeded: false) {
            case .authorized:
                do {
                    windows.append(contentsOf: try capture(browser))
                } catch {
                    AppLogger.browserAutomation.error(
                        "\(browser.displayName, privacy: .public) tab query failed."
                    )
                    issues.append(BrowserCaptureIssue(browser: browser, reason: .queryFailed))
                }
            case .denied:
                let connectedBefore = userDefaults.bool(
                    forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
                )
                issues.append(
                    BrowserCaptureIssue(
                        browser: browser,
                        reason: connectedBefore ? .permissionRevoked : .permissionDenied
                    )
                )
            case .notDetermined:
                issues.append(BrowserCaptureIssue(browser: browser, reason: .permissionDenied))
            case .targetNotRunning, .failed:
                issues.append(BrowserCaptureIssue(browser: browser, reason: .queryFailed))
            }
        }

        return BrowserTabCaptureResult(windows: windows, issues: issues)
    }

    private func capture(_ browser: BrowserAutomationBrowser) throws -> [CapturedBrowserWindow] {
        let result = try scriptEvaluator.evaluate(Self.script(for: browser))
        return try BrowserScriptResultParser().parse(result, browser: browser)
    }

    static func script(for browser: BrowserAutomationBrowser) -> String {
        switch browser {
        case .safari:
            return safariScript
        case .chrome, .brave:
            return chromiumScript(for: browser)
        }
    }

    private static let safariScript = """
    tell application id "com.apple.Safari"
        set capturedWindows to {}
        repeat with browserWindow in windows
            set capturedTabs to {}
            repeat with browserTab in tabs of browserWindow
                set tabURL to URL of browserTab
                if tabURL is missing value then set tabURL to ""
                set tabTitle to name of browserTab
                if tabTitle is missing value then set tabTitle to ""
                set end of capturedTabs to {tabTitle as text, tabURL as text}
            end repeat
            set windowBounds to bounds of browserWindow
            set normalizedBounds to {item 1 of windowBounds, item 2 of windowBounds, item 3 of windowBounds, item 4 of windowBounds}
            set end of capturedWindows to {(id of browserWindow) as text, (name of browserWindow) as text, normalizedBounds, capturedTabs, index of current tab of browserWindow}
        end repeat
        return capturedWindows
    end tell
    """

    private static func chromiumScript(for browser: BrowserAutomationBrowser) -> String {
    """
    tell application id "\(browser.bundleIdentifier)"
        set capturedWindows to {}
        repeat with browserWindow in windows
            if mode of browserWindow is "normal" then
                set capturedTabs to {}
                repeat with browserTab in tabs of browserWindow
                    set tabURL to URL of browserTab
                    if tabURL is missing value then set tabURL to ""
                    set tabTitle to title of browserTab
                    if tabTitle is missing value then set tabTitle to ""
                    set end of capturedTabs to {tabTitle as text, tabURL as text}
                end repeat
                set windowBounds to bounds of browserWindow
                set normalizedBounds to {item 1 of windowBounds, item 2 of windowBounds, item 3 of windowBounds, item 4 of windowBounds}
                set end of capturedWindows to {(id of browserWindow) as text, (name of browserWindow) as text, normalizedBounds, capturedTabs, active tab index of browserWindow}
            end if
        end repeat
        return capturedWindows
    end tell
    """
    }
}

struct BrowserScriptResultParser {
    func parse(
        _ descriptor: NSAppleEventDescriptor,
        browser: BrowserAutomationBrowser
    ) throws -> [CapturedBrowserWindow] {
        guard descriptor.numberOfItems >= 0 else {
            throw BrowserScriptEvaluationError(errorDescription: "The browser returned an invalid result.")
        }

        var windows: [CapturedBrowserWindow] = []
        for index in descriptor.itemIndices {
            guard let row = descriptor.atIndex(index),
                  let identifier = row.atIndex(1)?.stringValue,
                  let bounds = row.atIndex(3),
                  let tabs = row.atIndex(4),
                  let frame = frame(from: bounds) else {
                throw BrowserScriptEvaluationError(errorDescription: "The browser returned an invalid window.")
            }

            let title = row.atIndex(2)?.stringValue?.nonEmptyValue
            var selectedTabIndex: Int?
            let selectedSourceIndex = row.atIndex(5)?.int32Value
            var capturedTabs: [CapturedBrowserTab] = []
            for tabIndex in tabs.itemIndices {
                guard let tab = tabs.atIndex(tabIndex),
                      let value = tab.atIndex(2)?.stringValue,
                      let URL = URL(string: value),
                      WindowOpenTargetValidator().webTarget(url: URL) != nil else {
                    continue
                }
                if selectedSourceIndex == Int32(tabIndex) { selectedTabIndex = capturedTabs.count }
                capturedTabs.append(CapturedBrowserTab(
                    title: tab.atIndex(1)?.stringValue?.nonEmptyValue,
                    URL: URL
                ))
            }

            windows.append(
                CapturedBrowserWindow(
                    browser: browser,
                    scriptingIdentifier: identifier.nonEmptyValue,
                    title: title,
                    frame: frame,
                    frontToBackIndex: index - 1,
                    tabs: capturedTabs,
                    selectedTabIndex: selectedTabIndex
                )
            )
        }
        return windows
    }

    private func frame(from descriptor: NSAppleEventDescriptor) -> CGRect? {
        guard descriptor.numberOfItems == 4,
              let left = descriptor.atIndex(1)?.int32Value,
              let top = descriptor.atIndex(2)?.int32Value,
              let right = descriptor.atIndex(3)?.int32Value,
              let bottom = descriptor.atIndex(4)?.int32Value,
              right >= left,
              bottom >= top else {
            return nil
        }

        return CGRect(
            x: CGFloat(left),
            y: CGFloat(top),
            width: CGFloat(right - left),
            height: CGFloat(bottom - top)
        )
    }
}

private extension NSAppleEventDescriptor {
    var itemIndices: Range<Int> {
        1..<(numberOfItems + 1)
    }
}
