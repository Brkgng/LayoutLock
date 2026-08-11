import AppKit
import Combine
import XCTest
@testable import LayoutLock

final class BrowserScriptResultParserTests: XCTestCase {
    func testParserPreservesHTTPURLOrderAndDuplicates() throws {
        let descriptor = makeBrowserResultDescriptor(
            windows: [
                (
                    identifier: "window-1",
                    title: "Example",
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                    URLs: [
                        "https://example.com/one",
                        "chrome://newtab/",
                        "https://example.com/one",
                        "http://example.com/two"
                    ]
                )
            ]
        )

        let windows = try BrowserScriptResultParser().parse(descriptor, browser: .chrome)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].scriptingIdentifier, "window-1")
        XCTAssertEqual(windows[0].title, "Example")
        XCTAssertEqual(windows[0].frame, CGRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(
            windows[0].tabs.map(\.URL.absoluteString),
            [
                "https://example.com/one",
                "https://example.com/one",
                "http://example.com/two"
            ]
        )
        XCTAssertEqual(
            windows[0].tabs.map(\.title),
            [
                "https://example.com/one",
                "https://example.com/one",
                "http://example.com/two"
            ]
        )
    }

    func testParserPreservesWindowOrder() throws {
        let descriptor = makeBrowserResultDescriptor(
            windows: [
                (
                    identifier: "front",
                    title: "Front",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                    URLs: ["https://front.example"]
                ),
                (
                    identifier: "back",
                    title: "Back",
                    frame: CGRect(x: 500, y: 0, width: 500, height: 400),
                    URLs: ["https://back.example"]
                )
            ]
        )

        let windows = try BrowserScriptResultParser().parse(descriptor, browser: .safari)

        XCTAssertEqual(windows.map(\.scriptingIdentifier), ["front", "back"])
        XCTAssertEqual(windows.map(\.frontToBackIndex), [0, 1])
    }
}

final class BrowserTabCaptureServiceTests: XCTestCase {
    @MainActor
    func testFixedBrowserScriptsCompile() {
        let results = BrowserAutomationBrowser.allCases.map { browser in
            let script = NSAppleScript(source: BrowserTabCaptureService.script(for: browser))
            var errorInfo: NSDictionary?
            let didCompile = script?.compileAndReturnError(&errorInfo) == true
            return (
                browser.displayName,
                didCompile,
                String(describing: errorInfo)
            )
        }

        for (browserName, didCompile, errorDescription) in results {
            XCTAssertTrue(
                didCompile,
                "\(browserName) script failed to compile: \(errorDescription)"
            )
        }
    }

    func testAppleScriptEvaluatorCanBeCalledOffMain() async throws {
        let value = try await Task.detached {
            try NSAppleScriptEvaluator()
                .evaluate("return 42")
                .int32Value
        }.value

        XCTAssertEqual(value, 42)
    }

    func testDisabledIntegrationDoesNotCheckPermissionOrExecuteScript() {
        let userDefaults = makeBrowserUserDefaults()
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(result: .list())
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator
        )

        let result = service.captureTabs(
            runningApplications: [makeRunningBrowser(.safari)]
        )

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(permissionChecker.calls.isEmpty)
        XCTAssertEqual(evaluator.callCount, 0)
    }

    func testClosedBrowserDoesNotCheckPermissionOrExecuteScript() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
        )
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(result: .list())
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator
        )

        let result = service.captureTabs(runningApplications: [])

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(permissionChecker.calls.isEmpty)
        XCTAssertEqual(evaluator.callCount, 0)
    }

    func testCaptureNeverAsksForPermission() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .chrome)
        )
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(
            result: makeBrowserResultDescriptor(
                windows: [
                    (
                        identifier: "1",
                        title: "Chrome",
                        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        URLs: ["https://example.com"]
                    )
                ]
            )
        )
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator
        )

        let result = service.captureTabs(
            runningApplications: [makeRunningBrowser(.chrome)]
        )

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(
            permissionChecker.calls,
            [.init(browser: .chrome, askUserIfNeeded: false)]
        )
        XCTAssertTrue(evaluator.lastSource?.contains("mode of browserWindow is \"normal\"") == true)
    }

    func testRevokedPermissionProducesTypedIssueWithoutExecutingScript() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
        )
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: .safari)
        )
        let permissionChecker = RecordingBrowserPermissionChecker(result: .denied)
        let evaluator = RecordingBrowserScriptEvaluator(result: .list())
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator
        )

        let result = service.captureTabs(
            runningApplications: [makeRunningBrowser(.safari)]
        )

        XCTAssertEqual(
            result.issues,
            [BrowserCaptureIssue(browser: .safari, reason: .permissionRevoked)]
        )
        XCTAssertEqual(evaluator.callCount, 0)
    }

    func testDeniedPermissionProducesTypedIssueWithoutExecutingScript() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
        )
        let evaluator = RecordingBrowserScriptEvaluator(result: .list())
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .denied),
            scriptEvaluator: evaluator
        )

        let result = service.captureTabs(
            runningApplications: [makeRunningBrowser(.safari)]
        )

        XCTAssertEqual(
            result.issues,
            [BrowserCaptureIssue(browser: .safari, reason: .permissionDenied)]
        )
        XCTAssertEqual(evaluator.callCount, 0)
    }

    func testScriptFailureProducesTypedIssueWithoutFailingCapture() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .chrome)
        )
        let service = BrowserTabCaptureService(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .authorized),
            scriptEvaluator: RecordingBrowserScriptEvaluator(
                error: BrowserScriptEvaluationError(errorDescription: "private raw error")
            )
        )

        let result = service.captureTabs(
            runningApplications: [makeRunningBrowser(.chrome)]
        )

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(
            result.issues,
            [BrowserCaptureIssue(browser: .chrome, reason: .queryFailed)]
        )
    }
}

final class BrowserAutomationWindowOpenerTests: XCTestCase {
    @MainActor
    func testRestoreScriptsCompileAndKeepURLOrder() {
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            )
        ]
        let results = BrowserAutomationBrowser.allCases.map { browser in
            let source = BrowserAutomationWindowOpener.script(
                for: browser,
                targets: targets
            )
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            let didCompile = script?.compileAndReturnError(&errorInfo) == true
            return (
                browser.displayName,
                source,
                didCompile,
                String(describing: errorInfo)
            )
        }

        for (browserName, source, didCompile, errorDescription) in results {
            XCTAssertTrue(
                didCompile,
                "\(browserName) restore script failed to compile: \(errorDescription)"
            )
            let firstRange = source.range(of: targets[0].url.absoluteString)
            let secondRange = source.range(of: targets[2].url.absoluteString)
            XCTAssertNotNil(firstRange)
            XCTAssertNotNil(secondRange)
            if let firstRange, let secondRange {
                XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
            }
            XCTAssertEqual(
                source.components(separatedBy: targets[0].url.absoluteString).count - 1,
                2
            )
        }

        let coldStartSafariSource = BrowserAutomationWindowOpener.script(
            for: .safari,
            targets: targets,
            reuseDisposableStartupWindow: true
        )
        let coldStartSafariScript = NSAppleScript(source: coldStartSafariSource)
        var coldStartSafariError: NSDictionary?
        XCTAssertTrue(
            coldStartSafariScript?.compileAndReturnError(&coldStartSafariError) == true,
            "Cold-start Safari restore script failed to compile: \(String(describing: coldStartSafariError))"
        )

        let coldStartChromeSource = BrowserAutomationWindowOpener.script(
            for: .chrome,
            targets: targets,
            reuseDisposableStartupWindow: true
        )
        let coldStartChromeScript = NSAppleScript(source: coldStartChromeSource)
        var coldStartChromeError: NSDictionary?
        XCTAssertTrue(
            coldStartChromeScript?.compileAndReturnError(&coldStartChromeError) == true,
            "Cold-start Chrome restore script failed to compile: \(String(describing: coldStartChromeError))"
        )
        XCTAssertTrue(coldStartChromeSource.contains("(count windows) is 1"))
        XCTAssertTrue(coldStartChromeSource.contains("(count tabs of candidateWindow) is 1"))
        XCTAssertTrue(coldStartChromeSource.contains("chrome://newtab"))
        XCTAssertTrue(coldStartChromeSource.contains("set targetWindow to candidateWindow"))
        XCTAssertTrue(coldStartChromeSource.contains("set targetWindow to make new window"))

        let runningChromeSource = BrowserAutomationWindowOpener.script(
            for: .chrome,
            targets: targets
        )
        XCTAssertFalse(runningChromeSource.contains("candidateWindow"))
        XCTAssertTrue(runningChromeSource.contains("set targetWindow to make new window"))
    }

    func testConnectedRunningBrowserOpensDistinctWindowWithoutPrompting() async {
        let userDefaults = makeBrowserUserDefaults()
        connect(.safari, in: userDefaults)
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(result: makeOpenedWindowDescriptor())
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com")!
        )
        let opener = BrowserAutomationWindowOpener(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator,
            applicationURLProvider: { _ in
                URL(fileURLWithPath: "/Applications/Safari.app")
            },
            runningApplicationProvider: { _ in true },
            applicationLauncher: { _ in
                XCTFail("A running browser should not be launched again.")
                return false
            }
        )

        let result = await opener.openNewWindow(
            targets: [target],
            browser: .safari
        )

        guard case let .opened(openedWindow) = result else {
            return XCTFail("Expected connected Safari window restore to succeed.")
        }
        XCTAssertEqual(openedWindow.scriptingIdentifier, "opened-window")
        XCTAssertEqual(
            permissionChecker.calls,
            [.init(browser: .safari, askUserIfNeeded: false)]
        )
        XCTAssertEqual(evaluator.callCount, 1)
        XCTAssertTrue(evaluator.lastSource?.contains(target.url.absoluteString) == true)
        XCTAssertTrue(evaluator.lastSource?.contains("make new document") == true)
        XCTAssertFalse(evaluator.lastSource?.contains("candidateWindow") == true)
    }

    func testClosedSafariReusesOnlyDisposableStartupWindow() async {
        let userDefaults = makeBrowserUserDefaults()
        connect(.safari, in: userDefaults)
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(result: makeOpenedWindowDescriptor())
        var isRunning = false
        var launchCount = 0
        let opener = BrowserAutomationWindowOpener(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator,
            applicationURLProvider: { _ in
                URL(fileURLWithPath: "/Applications/Safari.app")
            },
            runningApplicationProvider: { _ in isRunning },
            applicationLauncher: { _ in
                launchCount += 1
                isRunning = true
                return true
            },
            launchPollSleeper: { _ in }
        )

        let result = await opener.openNewWindow(
            targets: [
                WindowOpenTarget(
                    kind: .webURL,
                    url: URL(string: "https://example.com")!
                )
            ],
            browser: .safari
        )

        guard case .opened = result else {
            return XCTFail("Expected closed Safari restore to succeed.")
        }
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(evaluator.callCount, 1)
        XCTAssertTrue(evaluator.lastSource?.contains("set candidateWindow to front window") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("(count tabs of candidateWindow) is 1") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("candidateURLText starts with \"favorites://\"") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("candidateURLText is \"about:blank\"") == true)
        XCTAssertFalse(evaluator.lastSource?.contains("close ") == true)
    }

    func testOnlyFirstSafariRestoreAfterColdStartCanReuseStartupWindow() async {
        let userDefaults = makeBrowserUserDefaults()
        connect(.safari, in: userDefaults)
        let evaluator = RecordingBrowserScriptEvaluator(result: makeOpenedWindowDescriptor())
        var isRunning = false
        let opener = BrowserAutomationWindowOpener(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .authorized),
            scriptEvaluator: evaluator,
            applicationURLProvider: { _ in
                URL(fileURLWithPath: "/Applications/Safari.app")
            },
            runningApplicationProvider: { _ in isRunning },
            applicationLauncher: { _ in
                isRunning = true
                return true
            },
            launchPollSleeper: { _ in }
        )
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com")!
        )

        _ = await opener.openNewWindow(targets: [target], browser: .safari)
        _ = await opener.openNewWindow(targets: [target], browser: .safari)

        XCTAssertEqual(evaluator.sources.count, 2)
        XCTAssertTrue(evaluator.sources[0].contains("candidateWindow"))
        XCTAssertFalse(evaluator.sources[1].contains("candidateWindow"))
        XCTAssertTrue(evaluator.sources[1].contains("make new document"))
    }

    func testClosedConnectedBrowserLaunchesBeforePermissionCheck() async {
        let userDefaults = makeBrowserUserDefaults()
        connect(.chrome, in: userDefaults)
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let evaluator = RecordingBrowserScriptEvaluator(result: makeOpenedWindowDescriptor())
        var isRunning = false
        var launchCount = 0
        let opener = BrowserAutomationWindowOpener(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator,
            applicationURLProvider: { _ in
                URL(fileURLWithPath: "/Applications/Google Chrome.app")
            },
            runningApplicationProvider: { _ in isRunning },
            applicationLauncher: { _ in
                launchCount += 1
                isRunning = true
                return true
            },
            launchPollSleeper: { _ in }
        )

        let result = await opener.openNewWindow(
            targets: [
                WindowOpenTarget(
                    kind: .webURL,
                    url: URL(string: "https://example.com")!
                )
            ],
            browser: .chrome
        )

        guard case .opened = result else {
            return XCTFail("Expected Chrome to launch and open a distinct window.")
        }
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(
            permissionChecker.calls,
            [.init(browser: .chrome, askUserIfNeeded: false)]
        )
        XCTAssertEqual(evaluator.callCount, 1)
        XCTAssertTrue(evaluator.lastSource?.contains("(count windows) is 1") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("chrome://newtab") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("set targetWindow to candidateWindow") == true)
        XCTAssertTrue(evaluator.lastSource?.contains("set targetWindow to make new window") == true)
    }

    func testDisconnectedOrRevokedBrowserNeverExecutesRestoreScript() async {
        for permissionDenied in [false, true] {
            let userDefaults = makeBrowserUserDefaults()
            if permissionDenied {
                connect(.chrome, in: userDefaults)
                userDefaults.set(
                    true,
                    forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(
                        for: .chrome
                    )
                )
            }
            let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
            let evaluator = RecordingBrowserScriptEvaluator(result: .list())
            let opener = BrowserAutomationWindowOpener(
                userDefaults: userDefaults,
                permissionChecker: permissionChecker,
                scriptEvaluator: evaluator,
                runningApplicationProvider: { _ in true }
            )

            let result = await opener.openNewWindow(
                targets: [
                    WindowOpenTarget(
                        kind: .webURL,
                        url: URL(string: "https://example.com")!
                    )
                ],
                browser: .chrome
            )

            guard case .unavailable = result else {
                XCTFail("Disconnected or revoked Chrome should use the generic fallback.")
                continue
            }
            XCTAssertTrue(permissionChecker.calls.isEmpty)
            XCTAssertEqual(evaluator.callCount, 0)
        }
    }

    func testRestoreNeverPromptsWhenPermissionIsNoLongerDetermined() async {
        let userDefaults = makeBrowserUserDefaults()
        connect(.safari, in: userDefaults)
        let permissionChecker = RecordingBrowserPermissionChecker(result: .notDetermined)
        let evaluator = RecordingBrowserScriptEvaluator(result: .list())
        let opener = BrowserAutomationWindowOpener(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            scriptEvaluator: evaluator,
            runningApplicationProvider: { _ in true }
        )

        let result = await opener.openNewWindow(
            targets: [
                WindowOpenTarget(
                    kind: .webURL,
                    url: URL(string: "https://example.com")!
                )
            ],
            browser: .safari
        )

        guard case .unavailable = result else {
            return XCTFail("An undetermined permission must use generic restore.")
        }
        XCTAssertEqual(
            permissionChecker.calls,
            [.init(browser: .safari, askUserIfNeeded: false)]
        )
        XCTAssertEqual(evaluator.callCount, 0)
    }
}

final class BrowserWindowTargetEnricherTests: XCTestCase {
    func testMatchesMultipleWindowsAndPreservesDuplicateTabs() {
        let frontFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let backFrame = CGRect(x: 850, y: 20, width: 800, height: 600)
        let discoveryResult = makeBrowserDiscoveryResult(
            browser: .chrome,
            windows: [
                makeDiscoveredWindow(title: "Front", frame: frontFrame, zOrderHint: 0),
                makeDiscoveredWindow(title: "Back", frame: backFrame, zOrderHint: 1)
            ]
        )
        let firstURL = URL(string: "https://front.example")!
        let secondURL = URL(string: "https://back.example")!
        let captureResult = BrowserTabCaptureResult(
            windows: [
                CapturedBrowserWindow(
                    browser: .chrome,
                    scriptingIdentifier: "front",
                    title: "Front",
                    frame: frontFrame,
                    frontToBackIndex: 0,
                    tabs: makeCapturedBrowserTabs([firstURL, firstURL])
                ),
                CapturedBrowserWindow(
                    browser: .chrome,
                    scriptingIdentifier: "back",
                    title: "Back",
                    frame: backFrame,
                    frontToBackIndex: 1,
                    tabs: makeCapturedBrowserTabs([secondURL])
                )
            ],
            issues: []
        )

        let result = BrowserWindowTargetEnricher().enrich(
            discoveryResult,
            with: captureResult
        )
        let windows = result.discoveryResult.applications[0].windows

        XCTAssertEqual(windows.map(\.browserScriptingIdentifier), ["front", "back"])
        XCTAssertEqual(windows[0].capturedOpeningTargets.map(\.url), [firstURL, firstURL])
        XCTAssertEqual(windows[1].capturedOpeningTargets.map(\.url), [secondURL])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testReplacesAccessibilityWebURLWithCompleteTabList() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let activeURL = URL(string: "https://active.example")!
        let otherURL = URL(string: "https://other.example")!
        let discoveryResult = makeBrowserDiscoveryResult(
            browser: .safari,
            windows: [
                makeDiscoveredWindow(
                    documentURL: activeURL,
                    title: "Active",
                    frame: frame
                )
            ]
        )
        let captureResult = BrowserTabCaptureResult(
            windows: [
                CapturedBrowserWindow(
                    browser: .safari,
                    scriptingIdentifier: "1",
                    title: "Active",
                    frame: frame,
                    frontToBackIndex: 0,
                    tabs: makeCapturedBrowserTabs([otherURL, activeURL])
                )
            ],
            issues: []
        )

        let result = BrowserWindowTargetEnricher().enrich(
            discoveryResult,
            with: captureResult
        )

        XCTAssertEqual(
            result.discoveryResult.applications[0].windows[0].capturedOpeningTargets.map(\.url),
            [otherURL, activeURL]
        )
    }

    func testAmbiguousFrameDoesNotAssignTabs() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let discoveryResult = makeBrowserDiscoveryResult(
            browser: .safari,
            windows: [
                makeDiscoveredWindow(title: "Same", frame: frame),
                makeDiscoveredWindow(title: "Same", frame: frame)
            ]
        )
        let captureResult = BrowserTabCaptureResult(
            windows: [
                CapturedBrowserWindow(
                    browser: .safari,
                    scriptingIdentifier: "1",
                    title: "Same",
                    frame: frame,
                    frontToBackIndex: 0,
                    tabs: makeCapturedBrowserTabs([URL(string: "https://example.com")!])
                )
            ],
            issues: []
        )

        let result = BrowserWindowTargetEnricher().enrich(
            discoveryResult,
            with: captureResult
        )

        XCTAssertTrue(
            result.discoveryResult.applications[0].windows.allSatisfy(
                \.capturedOpeningTargets.isEmpty
            )
        )
        XCTAssertEqual(
            result.issues,
            [BrowserCaptureIssue(browser: .safari, reason: .ambiguousWindowMatch)]
        )
    }

    func testFallsBackToFrontToBackOrderWhenFramesAndTitlesChanged() {
        let discoveryResult = makeBrowserDiscoveryResult(
            browser: .chrome,
            windows: [
                makeDiscoveredWindow(title: "Changed A", zOrderHint: 0),
                makeDiscoveredWindow(
                    title: "Changed B",
                    frame: CGRect(x: 500, y: 500, width: 400, height: 300),
                    zOrderHint: 1
                )
            ]
        )
        let firstURL = URL(string: "https://first.example")!
        let secondURL = URL(string: "https://second.example")!
        let captureResult = BrowserTabCaptureResult(
            windows: [
                CapturedBrowserWindow(
                    browser: .chrome,
                    scriptingIdentifier: "1",
                    title: "Old A",
                    frame: CGRect(x: 1000, y: 1000, width: 300, height: 200),
                    frontToBackIndex: 0,
                    tabs: makeCapturedBrowserTabs([firstURL])
                ),
                CapturedBrowserWindow(
                    browser: .chrome,
                    scriptingIdentifier: "2",
                    title: "Old B",
                    frame: CGRect(x: 1400, y: 1000, width: 300, height: 200),
                    frontToBackIndex: 1,
                    tabs: makeCapturedBrowserTabs([secondURL])
                )
            ],
            issues: []
        )

        let result = BrowserWindowTargetEnricher().enrich(
            discoveryResult,
            with: captureResult
        )

        XCTAssertEqual(
            result.discoveryResult.applications[0].windows.map {
                $0.capturedOpeningTargets.map(\.url)
            },
            [[firstURL], [secondURL]]
        )
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testCanDisableOrderFallbackForPartialRestoreEvidence() {
        let discoveryResult = makeBrowserDiscoveryResult(
            browser: .chrome,
            windows: [makeDiscoveredWindow(title: "Existing Window")]
        )
        let captureResult = BrowserTabCaptureResult(
            windows: [
                CapturedBrowserWindow(
                    browser: .chrome,
                    scriptingIdentifier: "new-window",
                    title: "Opened Window",
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200),
                    frontToBackIndex: 0,
                    tabs: []
                )
            ],
            issues: []
        )

        let result = BrowserWindowTargetEnricher(
            allowsOrderFallback: false
        ).enrich(discoveryResult, with: captureResult)

        XCTAssertNil(
            result.discoveryResult.applications[0].windows[0]
                .browserScriptingIdentifier
        )
        XCTAssertEqual(
            result.issues,
            [BrowserCaptureIssue(browser: .chrome, reason: .ambiguousWindowMatch)]
        )
    }
}

@MainActor
final class BrowserAutomationControllerTests: XCTestCase {
    func testInitializationNeverPromptsForPermission() async {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
        )
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)

        let controller = BrowserAutomationController(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Browser.app") },
            runningBundleIdentifiersProvider: {
                Set(BrowserAutomationBrowser.allCases.map(\.bundleIdentifier))
            }
        )

        await waitUntil { !permissionChecker.calls.isEmpty }

        XCTAssertFalse(controller.status(for: .safari).isWorking)
        XCTAssertTrue(permissionChecker.calls.allSatisfy { !$0.askUserIfNeeded })
    }

    func testConnectExplicitlyPromptsAndPersistsConnection() async {
        let userDefaults = makeBrowserUserDefaults()
        let permissionChecker = RecordingBrowserPermissionChecker(result: .authorized)
        let controller = BrowserAutomationController(
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Browser.app") },
            runningBundleIdentifiersProvider: {
                [BrowserAutomationBrowser.safari.bundleIdentifier]
            }
        )

        controller.connect(.safari)
        await waitUntil { !controller.status(for: .safari).isWorking }

        XCTAssertEqual(controller.status(for: .safari).connectionState, .connected)
        XCTAssertTrue(
            permissionChecker.calls.contains(
                .init(browser: .safari, askUserIfNeeded: true)
            )
        )
        XCTAssertTrue(
            userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
            )
        )
    }

    func testDisconnectStopsFutureCaptureWithoutOpeningSettings() {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .chrome)
        )
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: .chrome)
        )
        var settingsOpenCount = 0
        let controller = BrowserAutomationController(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .authorized),
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Browser.app") },
            runningBundleIdentifiersProvider: {
                [BrowserAutomationBrowser.chrome.bundleIdentifier]
            },
            automationSettingsOpener: {
                settingsOpenCount += 1
            }
        )

        controller.disconnect(.chrome)

        XCTAssertEqual(controller.status(for: .chrome).connectionState, .notConnected)
        XCTAssertFalse(
            userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .chrome)
            )
        )
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testDeniedConnectionRemainsVisibleUntilDisconnect() async {
        let userDefaults = makeBrowserUserDefaults()
        let controller = BrowserAutomationController(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .denied),
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Browser.app") },
            runningBundleIdentifiersProvider: {
                [BrowserAutomationBrowser.safari.bundleIdentifier]
            }
        )

        controller.connect(.safari)
        await waitUntil { !controller.status(for: .safari).isWorking }

        XCTAssertEqual(controller.status(for: .safari).connectionState, .permissionDenied)
        XCTAssertTrue(
            userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .safari)
            )
        )

        controller.disconnect(.safari)

        XCTAssertEqual(controller.status(for: .safari).connectionState, .notConnected)
    }

    func testPreviouslyConnectedBrowserReportsRevokedPermission() async {
        let userDefaults = makeBrowserUserDefaults()
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: .chrome)
        )
        userDefaults.set(
            true,
            forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: .chrome)
        )
        let controller = BrowserAutomationController(
            userDefaults: userDefaults,
            permissionChecker: RecordingBrowserPermissionChecker(result: .denied),
            applicationURLProvider: { _ in URL(fileURLWithPath: "/Applications/Browser.app") },
            runningBundleIdentifiersProvider: {
                [BrowserAutomationBrowser.chrome.bundleIdentifier]
            }
        )

        await waitUntil {
            controller.status(for: .chrome).connectionState == .revoked
        }

        XCTAssertEqual(controller.status(for: .chrome).connectionState, .revoked)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for browser automation state.")
    }
}

private final class RecordingBrowserPermissionChecker: BrowserAutomationPermissionChecking {
    struct Call: Equatable {
        let browser: BrowserAutomationBrowser
        let askUserIfNeeded: Bool
    }

    private let lock = NSLock()
    private let result: BrowserAutomationPermissionStatus
    private var recordedCalls: [Call] = []

    init(result: BrowserAutomationPermissionStatus) {
        self.result = result
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func status(
        for browser: BrowserAutomationBrowser,
        askUserIfNeeded: Bool
    ) -> BrowserAutomationPermissionStatus {
        lock.withLock {
            recordedCalls.append(
                Call(browser: browser, askUserIfNeeded: askUserIfNeeded)
            )
        }
        return result
    }
}

private final class RecordingBrowserScriptEvaluator: BrowserScriptEvaluating {
    private(set) var callCount = 0
    private(set) var lastSource: String?
    private(set) var sources: [String] = []
    private let result: NSAppleEventDescriptor?
    private let error: Error?

    init(result: NSAppleEventDescriptor) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func evaluate(_ source: String) throws -> NSAppleEventDescriptor {
        callCount += 1
        lastSource = source
        sources.append(source)
        if let error {
            throw error
        }
        return result ?? .list()
    }
}

private func makeBrowserUserDefaults() -> UserDefaults {
    let suiteName = "BrowserAutomationTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    LayoutLockSettings.registerDefaults(in: userDefaults)
    return userDefaults
}

private func connect(
    _ browser: BrowserAutomationBrowser,
    in userDefaults: UserDefaults
) {
    userDefaults.set(
        true,
        forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
    )
    userDefaults.set(
        true,
        forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
    )
    userDefaults.set(
        false,
        forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
    )
}

private func makeRunningBrowser(
    _ browser: BrowserAutomationBrowser
) -> RunningApplicationSnapshot {
    RunningApplicationSnapshot(
        bundleIdentifier: browser.bundleIdentifier,
        processIdentifier: 42,
        localizedName: browser.displayName
    )
}

private func makeBrowserDiscoveryResult(
    browser: BrowserAutomationBrowser,
    windows: [DiscoveredWindow]
) -> WindowDiscoveryResult {
    WindowDiscoveryResult(
        applications: [
            DiscoveredApplication(
                bundleIdentifier: browser.bundleIdentifier,
                pid: 42,
                localizedName: browser.displayName,
                windows: windows
            )
        ],
        diagnostics: []
    )
}

private func makeBrowserResultDescriptor(
    windows: [(
        identifier: String,
        title: String,
        frame: CGRect,
        URLs: [String]
    )]
) -> NSAppleEventDescriptor {
    let result = NSAppleEventDescriptor.list()
    for (windowIndex, window) in windows.enumerated() {
        let row = NSAppleEventDescriptor.list()
        row.insert(NSAppleEventDescriptor(string: window.identifier), at: 1)
        row.insert(NSAppleEventDescriptor(string: window.title), at: 2)

        let bounds = NSAppleEventDescriptor.list()
        bounds.insert(NSAppleEventDescriptor(int32: Int32(window.frame.minX)), at: 1)
        bounds.insert(NSAppleEventDescriptor(int32: Int32(window.frame.minY)), at: 2)
        bounds.insert(NSAppleEventDescriptor(int32: Int32(window.frame.maxX)), at: 3)
        bounds.insert(NSAppleEventDescriptor(int32: Int32(window.frame.maxY)), at: 4)
        row.insert(bounds, at: 3)

        let tabs = NSAppleEventDescriptor.list()
        for (tabIndex, URL) in window.URLs.enumerated() {
            let tab = NSAppleEventDescriptor.list()
            tab.insert(NSAppleEventDescriptor(string: URL), at: 1)
            tab.insert(NSAppleEventDescriptor(string: URL), at: 2)
            tabs.insert(tab, at: tabIndex + 1)
        }
        row.insert(tabs, at: 4)
        result.insert(row, at: windowIndex + 1)
    }
    return result
}

private func makeOpenedWindowDescriptor() -> NSAppleEventDescriptor {
    makeBrowserResultDescriptor(
        windows: [
            (
                identifier: "opened-window",
                title: "Opened Window",
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                URLs: ["https://example.com"]
            )
        ]
    )
}

private func makeCapturedBrowserTabs(_ URLs: [URL]) -> [CapturedBrowserTab] {
    URLs.map { CapturedBrowserTab(title: nil, URL: $0) }
}
