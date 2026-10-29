import AppKit
import Foundation

enum BrowserWindowOpenResult {
    case opened(
        CapturedBrowserWindow,
        startupWindows: [CapturedBrowserWindow] = [],
        openedTargetCount: Int? = nil
    )
    case unavailable
    case failed
}

protocol BrowserWindowOpening {
    func openNewWindow(
        targets: [WindowOpenTarget],
        browser: BrowserAutomationBrowser,
        excludingWindowIdentifiers: Set<String>,
        preferredApplicationURL: URL?,
        remainingWindowTargets: [[WindowOpenTarget]]
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
        browser: BrowserAutomationBrowser,
        excludingWindowIdentifiers: Set<String> = [],
        preferredApplicationURL: URL? = nil,
        remainingWindowTargets: [[WindowOpenTarget]] = []
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
            guard let applicationURL = preferredApplicationURL?.validatedApplicationBundleURL(
                withBundleIdentifier: browser.bundleIdentifier) ?? applicationURLProvider(browser.bundleIdentifier),
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
            var startupWindows: [CapturedBrowserWindow] = []
            var targetsToOpen = targets
            var existingWindow: CapturedBrowserWindow?
            var startupWindowIdentifier: String?
            var startupTabIdentifier: String?
            defer {
                if let startupWindowIdentifier, let startupTabIdentifier {
                    do {
                        _ = try scriptEvaluator.evaluate(Self.chromiumStartupCleanupScript(
                            windowIdentifier: startupWindowIdentifier,
                            tabIdentifier: startupTabIdentifier,
                            browser: browser
                        ))
                    } catch {
                        AppLogger.browserAutomation.error("Browser startup blank-tab cleanup failed.")
                    }
                }
            }
            if browser.isChromium {
                // Creating Chromium's first window can itself trigger session restoration.
                // Initialize it without opening a target, then inventory the restored tabs.
                let startupDescriptor = try scriptEvaluator.evaluate(Self.chromiumStartupScript(for: browser))
                startupWindowIdentifier = startupDescriptor.atIndex(1)?.stringValue
                startupTabIdentifier = startupDescriptor.atIndex(2)?.stringValue
            }
            let attemptCount = browser.isChromium && (!wasRunning || startupWindowIdentifier != nil) ? 50 : 1
            for attempt in 0..<attemptCount {
                let descriptor = try scriptEvaluator.evaluate(
                    BrowserTabCaptureService.script(for: browser)
                )
                startupWindows = try BrowserScriptResultParser().parse(
                    descriptor,
                    browser: browser
                )
                let candidates = startupWindows.filter {
                    $0.scriptingIdentifier.map { !excludingWindowIdentifiers.contains($0) } == true
                }
                existingWindow = Self.reusableWindow(targets: targets,
                    remainingWindowTargets: remainingWindowTargets, candidates: candidates)
                targetsToOpen = existingWindow.map { Self.missingTargets(targets, in: $0) } ?? targets
                if attempt == 0 || targetsToOpen.isEmpty || attempt == attemptCount - 1 {
                    AppLogger.browserAutomation.info(
                        "\(browser.displayName, privacy: .public) startup inventory attempt=\(attempt + 1) windowCount=\(startupWindows.count) tabCount=\(startupWindows.reduce(0) { $0 + $1.tabs.count }) missingTargetCount=\(targetsToOpen.count) createdStartupWindow=\(startupWindowIdentifier != nil)."
                    )
                }
                if targetsToOpen.isEmpty {
                    // Keep the window identity so restore can position the reused window.
                    if let window = existingWindow {
                        selectSavedTab(targets: targets, window: window, browser: browser)
                        return .opened(window, startupWindows: startupWindows, openedTargetCount: 0)
                    }
                }
                if attempt < attemptCount - 1 {
                    await launchPollSleeper(0.1)
                }
            }
            if targetsToOpen.count == targets.count { existingWindow = nil }

            let descriptor = try scriptEvaluator.evaluate(
                Self.script(
                    for: browser,
                    targets: targetsToOpen,
                    reuseDisposableStartupWindow: !wasRunning || startupWindowIdentifier != nil,
                    startupWindowIdentifier: startupWindowIdentifier,
                    existingWindowIdentifier: existingWindow?.scriptingIdentifier
                )
            )
            guard let openedWindow = try BrowserScriptResultParser()
                .parse(descriptor, browser: browser)
                .first else {
                return .failed
            }
            selectSavedTab(targets: targets, window: openedWindow, browser: browser)
            return .opened(
                openedWindow,
                startupWindows: startupWindows,
                openedTargetCount: targetsToOpen.count
            )
        } catch {
            AppLogger.browserAutomation.error(
                "\(browser.displayName, privacy: .public) window restore failed."
            )
            return .failed
        }
    }

    private static func reusableWindow(targets: [WindowOpenTarget],
        remainingWindowTargets: [[WindowOpenTarget]], candidates: [CapturedBrowserWindow]) -> CapturedBrowserWindow? {
        let groups = [targets] + remainingWindowTargets
        let completeMatches = groups.map { group in
            candidates.indices.filter { missingTargets(group, in: candidates[$0]).isEmpty }
        }
        // Reserve complete matches before adding tabs; a broad group must not steal a sibling's only match.
        var groupByWindow: [Int: Int] = [:]
        func reserve(_ group: Int, visited: inout Set<Int>) -> Bool {
            let choices = completeMatches[group].filter { groupByWindow[$0] == nil } +
                completeMatches[group].filter { groupByWindow[$0] != nil }
            for window in choices where visited.insert(window).inserted {
                if let previous = groupByWindow[window], !reserve(previous, visited: &visited) { continue }
                groupByWindow[window] = group
                return true
            }
            return false
        }
        for group in groups.indices.sorted(by: { completeMatches[$0].count < completeMatches[$1].count }) {
            var visited: Set<Int> = []
            _ = reserve(group, visited: &visited)
        }
        return candidates.indices.filter { groupByWindow[$0] == nil || groupByWindow[$0] == 0 }
            .map { candidates[$0] }.min { missingTargets(targets, in: $0).count < missingTargets(targets, in: $1).count }
    }

    private static func missingTargets(_ targets: [WindowOpenTarget], in window: CapturedBrowserWindow) -> [WindowOpenTarget] {
        var available = window.tabs.map(\.URL)
        return targets.filter { target in
            guard let index = available.firstIndex(of: target.url) else { return true }
            available.remove(at: index)
            return false
        }
    }

    private func selectSavedTab(targets: [WindowOpenTarget], window: CapturedBrowserWindow, browser: BrowserAutomationBrowser) {
        guard let selected = targets.firstIndex(where: { $0.isSelectedBrowserTab == true }),
              let identifier = window.scriptingIdentifier else { return }
        let target = targets[selected]
        let occurrence = targets[...selected].filter { $0.url == target.url }.count
        let selection = browser.isChromium
            ? "set active tab index of targetWindow to selectedTabIndex"
            : "set current tab of targetWindow to browserTab"
        let script = """
        tell application id "\(browser.bundleIdentifier)"
            repeat with targetWindow in windows
                if ((id of targetWindow) as text) is \(Self.appleScriptLiteral(identifier)) then
                    set remainingOccurrence to \(occurrence)
                    set selectedTabIndex to 0
                    repeat with browserTab in tabs of targetWindow
                        set selectedTabIndex to selectedTabIndex + 1
                        considering case
                            if (URL of browserTab) is \(Self.appleScriptLiteral(target.url.absoluteString)) then
                                set remainingOccurrence to remainingOccurrence - 1
                                if remainingOccurrence is 0 then
                                    \(selection)
                                    return
                                end if
                            end if
                        end considering
                    end repeat
                end if
            end repeat
        end tell
        """
        do { _ = try scriptEvaluator.evaluate(script) }
        catch { AppLogger.browserAutomation.error("Saved browser tab could not be selected.") }
    }

    static func script(
        for browser: BrowserAutomationBrowser,
        targets: [WindowOpenTarget],
        reuseDisposableStartupWindow: Bool = false,
        startupWindowIdentifier: String? = nil,
        existingWindowIdentifier: String? = nil
    ) -> String {
        let URLs = targets.map { appleScriptLiteral($0.url.absoluteString) }
        let URLList = "{\(URLs.joined(separator: ", "))}"
        let selectExistingWindow = existingWindowIdentifier.map { identifier in
            """
            set targetWindow to missing value
            repeat with browserWindow in windows
                if ((id of browserWindow) as text) is \(appleScriptLiteral(identifier)) then
                    set targetWindow to window id (id of browserWindow)
                    exit repeat
                end if
            end repeat
            if targetWindow is missing value then error "The browser window is no longer available."
            """
        }
        let firstNewTab = existingWindowIdentifier == nil ? 2 : 1

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
                \(selectExistingWindow ?? selectTargetWindow)
                \(existingWindowIdentifier == nil ? "set URL of current tab of targetWindow to item 1 of targetURLs" : "")
                if (count targetURLs) >= \(firstNewTab) then
                    repeat with tabIndex from \(firstNewTab) to count targetURLs
                        set tabURL to item tabIndex of targetURLs
                        tell targetWindow
                            make new tab at end of tabs with properties {URL:tabURL as text}
                        end tell
                    end repeat
                end if
                \(existingWindowIdentifier == nil ? "set current tab of targetWindow to tab 1 of targetWindow" : "")
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
        case .chrome, .brave:
            let selectOwnedStartupWindow = startupWindowIdentifier.map { identifier in
                """
                repeat with browserWindow in windows
                    if ((id of browserWindow) as text) is \(appleScriptLiteral(identifier)) then
                        set candidateWindow to browserWindow
                        exit repeat
                    end if
                end repeat
                """
            } ?? ""
            let selectTargetWindow = reuseDisposableStartupWindow
                ? """
                set shouldReuseFrontWindow to false
                set candidateWindow to missing value
                if (count windows) is 1 then
                    set candidateWindow to front window
                end if
                \(selectOwnedStartupWindow)
                if candidateWindow is not missing value then
                    if (mode of candidateWindow) is "normal" and (count tabs of candidateWindow) is 1 then
                        set candidateURL to URL of active tab of candidateWindow
                        if candidateURL is missing value then
                            set shouldReuseFrontWindow to true
                        else
                            set candidateURLText to candidateURL as text
                            if candidateURLText is "" or candidateURLText starts with "chrome://newtab" or candidateURLText starts with "brave://newtab" then
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
            tell application id "\(browser.bundleIdentifier)"
                \(selectExistingWindow ?? selectTargetWindow)
                \(existingWindowIdentifier == nil ? "set URL of active tab of targetWindow to item 1 of targetURLs" : "")
                if (count targetURLs) >= \(firstNewTab) then
                    repeat with tabIndex from \(firstNewTab) to count targetURLs
                        set tabURL to item tabIndex of targetURLs
                        tell targetWindow
                            make new tab at end of tabs with properties {URL:tabURL as text}
                        end tell
                    end repeat
                end if
                \(existingWindowIdentifier == nil ? "set active tab index of targetWindow to 1" : "")
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

    static func chromiumStartupScript(for browser: BrowserAutomationBrowser) -> String {
    """
    tell application id "\(browser.bundleIdentifier)"
        repeat with browserWindow in windows
            if (mode of browserWindow) is "normal" then return {}
        end repeat
        set startupWindow to make new window with properties {mode:"normal"}
        return {(id of startupWindow) as text, (id of active tab of startupWindow) as text}
    end tell
    """
    }

    static func chromiumStartupCleanupScript(
        windowIdentifier: String,
        tabIdentifier: String,
        browser: BrowserAutomationBrowser = .chrome
    ) -> String {
        """
        tell application id "\(browser.bundleIdentifier)"
            repeat with browserWindow in windows
                if ((id of browserWindow) as text) is \(appleScriptLiteral(windowIdentifier)) then
                    repeat with browserTab in tabs of browserWindow
                        if ((id of browserTab) as text) is \(appleScriptLiteral(tabIdentifier)) then
                            set tabURL to URL of browserTab
                            if tabURL is missing value then set tabURL to ""
                            if tabURL is "" or tabURL is "about:blank" or tabURL starts with "chrome://newtab" or tabURL starts with "brave://newtab" then
                                close browserTab
                            end if
                            return
                        end if
                    end repeat
                end if
            end repeat
        end tell
        """
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
