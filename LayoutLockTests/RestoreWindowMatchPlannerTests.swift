import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import LayoutLock

final class RestoreWindowMatchPlannerTests: XCTestCase {
    func testPlansSkipWindowsWhenSavedAppIsNotRunning() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(bundleIdentifier: "com.example.missing")

        let plans = planner.plans(for: [savedWindow], candidates: [])

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(plans.first?.skip?.bundleIdentifier, "com.example.missing")
        XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.appNotRunning)
    }

    func testPlansReportWindowNotFoundWhenRunningAppHasNoCandidateWindows() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(bundleIdentifier: "com.example.running")

        let plans = planner.plans(
            for: [savedWindow],
            candidates: [],
            runningBundleIdentifiers: ["com.example.running"]
        )

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testPlansMatchByExactTitleWhenPidChanged() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            pidAtCapture: 100,
            windowTitle: "Project Notes",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.editor",
                pid: 200,
                title: "Project Notes",
                frame: CGRect(x: 200, y: 200, width: 500, height: 300)
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansMatchByOpeningTargetWhenPidTitleAndFrameChanged() {
        let planner = RestoreWindowMatchPlanner()
        let target = WindowOpenTarget(
            kind: .folder,
            url: URL(fileURLWithPath: "/Users/test/Repo/ZapPDF", isDirectory: true)
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.google.antigravity-ide",
            pidAtCapture: 100,
            windowTitle: "ZapPDF — review-issue-suggestions.md",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400),
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [target]
            )
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.google.antigravity-ide",
                pid: 200,
                documentURLs: [target.url],
                title: "review-issue-suggestions.md — ZapPDF",
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansMatchLocalTargetFromExactFullPathDocumentTitle() {
        let planner = RestoreWindowMatchPlanner()
        let targetURL = URL(fileURLWithPath: "/Users/test/solvoyo/web-react18", isDirectory: true)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.terminal",
            pidAtCapture: 100,
            windowTitle: "~/solvoyo/web-react18",
            frame: CGRect(x: -1_900, y: 20, width: 1_000, height: 700),
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [WindowOpenTarget(kind: .folder, url: targetURL)]
            )
        )
        let candidate = makeCandidate(
            id: 1,
            bundleIdentifier: "com.example.terminal",
            pid: 900,
            documentTitles: ["shell: \(targetURL.path)"],
            title: "Different title",
            frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
        )

        let plan = planner.plans(for: [savedWindow], candidates: [candidate]).first

        XCTAssertEqual(plan?.candidate?.id, 1)
        XCTAssertEqual(plan?.matchStrategy, .scored)
        XCTAssertNil(plan?.skip)
    }

    func testPlansMatchLocalTargetFromEncodedFileURLDocumentTitle() {
        let targetURL = URL(fileURLWithPath: "/Users/test/Repo/My Project/Notes.txt")
        let saved = makeWindowRecord(
            bundleIdentifier: "com.example.editor", pidAtCapture: 42,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [WindowOpenTarget(kind: .file, url: targetURL)])
        )
        let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier, pid: 900,
                                      documentTitles: ["document: \(targetURL.absoluteString)"], title: "Different title",
                                      frame: CGRect(x: 2_000, y: 2_000, width: 600, height: 400))

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate]).first

        XCTAssertEqual(plan?.candidate?.id, 1)
        XCTAssertEqual(plan?.matchStrategy, .scored)
        XCTAssertNil(plan?.skip)
    }

    func testPlansUseAutomaticTargetForMatchingWhenManualTargetsAreEmpty() {
        let planner = RestoreWindowMatchPlanner()
        let targetURL = URL(
            fileURLWithPath: "/Users/test/solvoyo/web-react18",
            isDirectory: true
        )
        let automaticTarget = WindowOpenTarget(kind: .folder, url: targetURL)
        let configuration = WindowOpeningConfiguration(
            automaticallyCapturedTargets: [automaticTarget],
            manualTargets: []
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.mitchellh.ghostty",
            pidAtCapture: 100,
            windowTitle: "~/solvoyo/web-react18",
            frame: CGRect(x: -852, y: -1_410, width: 1_653, height: 1_410),
            openingConfiguration: configuration
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.mitchellh.ghostty",
                pid: 900,
                documentTitles: [targetURL.path],
                title: "lg",
                frame: CGRect(x: 1_495, y: -1_405, width: 1_280, height: 1_410)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: "com.mitchellh.ghostty",
                pid: 901,
                documentTitles: ["/Users/test/another-project"],
                title: "Another terminal",
                frame: CGRect(x: 2_000, y: 200, width: 600, height: 500)
            )
        ]

        let plan = planner.plans(for: [savedWindow], candidates: candidates).first

        XCTAssertTrue(configuration.effectiveTargets.isEmpty)
        XCTAssertEqual(configuration.matchingTargets, [automaticTarget])
        XCTAssertEqual(plan?.candidate?.id, 1)
        XCTAssertEqual(plan?.matchStrategy, .scored)
        XCTAssertNil(plan?.skip)
    }

    func testPlansPreferNonemptyManualTargetsOverAutomaticTargetsForMatching() {
        let planner = RestoreWindowMatchPlanner()
        let automaticTarget = WindowOpenTarget(
            kind: .folder,
            url: URL(fileURLWithPath: "/Users/test/automatic", isDirectory: true)
        )
        let manualTarget = WindowOpenTarget(
            kind: .folder,
            url: URL(fileURLWithPath: "/Users/test/manual", isDirectory: true)
        )
        let configuration = WindowOpeningConfiguration(
            automaticallyCapturedTargets: [automaticTarget],
            manualTargets: [manualTarget]
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.terminal",
            pidAtCapture: 100,
            windowTitle: "Saved terminal",
            frame: CGRect(x: -1_900, y: 20, width: 1_000, height: 700),
            openingConfiguration: configuration
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.terminal",
                pid: 900,
                documentTitles: [automaticTarget.url.path],
                title: "Automatic terminal",
                frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: "com.example.terminal",
                pid: 901,
                documentTitles: [manualTarget.url.path],
                title: "Manual terminal",
                frame: CGRect(x: 2_000, y: 900, width: 400, height: 300)
            )
        ]

        let plan = planner.plans(for: [savedWindow], candidates: candidates).first

        XCTAssertEqual(configuration.matchingTargets, [manualTarget])
        XCTAssertEqual(plan?.candidate?.id, 2)
        XCTAssertEqual(plan?.matchStrategy, .scored)
        XCTAssertNil(plan?.skip)
    }

    func testPlansDoNotMatchLocalTargetByBasenameFromDifferentParent() {
        let planner = RestoreWindowMatchPlanner()
        let savedURL = URL(fileURLWithPath: "/Users/test/Second/src", isDirectory: true)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.terminal",
            pidAtCapture: 100,
            windowTitle: "Saved terminal",
            frame: CGRect(x: -1_900, y: 20, width: 1_000, height: 700),
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [WindowOpenTarget(kind: .folder, url: savedURL)]
            )
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.terminal",
                pid: 900,
                documentTitles: ["shell: /Users/test/First/src"],
                title: "Different terminal",
                frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: "com.example.terminal",
                pid: 901,
                documentTitles: ["shell: /Users/test/Third/src"],
                title: "Another terminal",
                frame: CGRect(x: 2_000, y: 900, width: 400, height: 300)
            )
        ]

        let plan = planner.plans(for: [savedWindow], candidates: candidates).first

        XCTAssertNil(plan?.candidate)
        XCTAssertEqual(plan?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testPlansReserveExactBrowserScriptingIdentifierBeforeScoring() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = BrowserAutomationBrowser.chrome.bundleIdentifier
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: -1_900, y: 20, width: 1_200, height: 900)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 100,
                browserScriptingIdentifier: "other-window",
                documentURLs: [URL(string: "https://saved.example")!],
                title: "Saved Tab",
                frame: savedWindow.frame.cgRect
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: bundleIdentifier,
                pid: 900,
                browserScriptingIdentifier: "opened-window",
                documentURLs: [URL(string: "https://redirected.example")!],
                title: "Redirected Tab",
                frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
            )
        ]

        let plans = planner.plans(
            for: [savedWindow],
            candidates: candidates,
            preferredBrowserScriptingIdentifiers: [savedWindow.id: "opened-window"],
            openedBrowserWindowIDs: [savedWindow.id]
        )

        XCTAssertEqual(plans.first?.candidate?.id, 2)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansDoNotFallBackWhenAutomatedBrowserEvidenceIsAmbiguous() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = BrowserAutomationBrowser.chrome.bundleIdentifier
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: -1_900, y: 20, width: 1_200, height: 900)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 900,
                browserScriptingIdentifier: "opened-window",
                title: "Saved Tab",
                frame: savedWindow.frame.cgRect
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: bundleIdentifier,
                pid: 900,
                browserScriptingIdentifier: "opened-window",
                title: "Unrelated Window",
                frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
            )
        ]

        let plans = planner.plans(
            for: [savedWindow],
            candidates: candidates,
            preferredBrowserScriptingIdentifiers: [savedWindow.id: "opened-window"],
            openedBrowserWindowIDs: [savedWindow.id]
        )

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(
            plans.first?.skip?.reason,
            RestoreSkipReason.openedBrowserWindowNotIdentified
        )
    }

    func testPlansUseSingletonFallbackOnlyForGenericColdBrowserWindow() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = BrowserAutomationBrowser.chrome.bundleIdentifier
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: -1_900, y: 20, width: 1_200, height: 900)
        )
        let candidate = makeCandidate(
            id: 1,
            bundleIdentifier: bundleIdentifier,
            pid: 900,
            title: "New Tab",
            frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
        )

        let plans = planner.plans(
            for: [savedWindow],
            candidates: [candidate],
            genericColdOpenedBrowserWindowIDs: [savedWindow.id],
            openedBrowserWindowIDs: [savedWindow.id]
        )

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansSkipLowConfidenceSameBundleCandidate() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.browser",
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            role: "AXWindow",
            subrole: "AXStandardWindow"
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.browser",
                pid: 200,
                title: "Different Tab",
                role: "AXDialog",
                subrole: nil
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testPlansUseSingletonFallbackForFarStandardWindow() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.browser",
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.browser",
                pid: 200,
                title: "Different Tab",
                frame: CGRect(x: 900, y: 700, width: 600, height: 400)
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertEqual(plans.first?.matchStrategy, .singleton)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansMatchNearbyRoleMatchWhenTitleDoesNotMatch() {
        let planner = RestoreWindowMatchPlanner()
        let savedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.browser",
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.browser",
                pid: 200,
                title: "Different Tab",
                frame: CGRect(x: 90, y: 120, width: 650, height: 350)
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansMatchSingletonRoleWhenTitleAndFrameChanged() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = "com.example.browser"
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab",
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            )
        ]

        let plans = planner.plans(for: [savedWindow], candidates: candidates)

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertEqual(plans.first?.matchStrategy, .singleton)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansSkipSingletonWhenRoleOrSubroleDoesNotMatch() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = "com.example.browser"
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab",
                role: "AXDialog",
                subrole: nil,
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab",
                subrole: nil,
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            )
        ]

        for candidate in candidates {
            let plans = planner.plans(
                for: [savedWindow],
                candidates: [candidate]
            )

            XCTAssertNil(plans.first?.candidate, "Unexpectedly matched candidate \(candidate.id).")
            XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
        }
    }

    func testMinimizedMailSubroleFallbackRequiresUniqueStandardWindow() {
        let saved = makeWindowRecord(bundleIdentifier: "com.apple.mail", pidAtCapture: 100,
            windowTitle: "All Inboxes – 2,732 messages", subrole: "AXDialog", isMinimized: true)
        let standard = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier, pid: 200,
            title: "All Inboxes – 2,735 messages", frame: CGRect(x: 900, y: 700, width: 600, height: 500))
        let sibling = makeCandidate(id: 2, bundleIdentifier: saved.bundleIdentifier, pid: 200,
            title: "New Message", frame: standard.frame)
        let dialog = makeCandidate(id: 3, bundleIdentifier: saved.bundleIdentifier, pid: 200,
            title: "Account Settings", subrole: "AXDialog", frame: standard.frame)
        let planner = RestoreWindowMatchPlanner()

        let plan = planner.plans(for: [saved], candidates: [standard]).first
        XCTAssertEqual(plan?.candidate?.id, 1)
        XCTAssertEqual(plan?.matchStrategy, .singleton)
        XCTAssertNil(planner.plans(for: [saved], candidates: [standard, sibling]).first?.candidate)
        XCTAssertNil(planner.plans(for: [saved], candidates: [dialog]).first?.candidate)

        let secondSaved = makeWindowRecord(bundleIdentifier: saved.bundleIdentifier, pidAtCapture: 100,
            windowTitle: "Saved Draft", subrole: "AXDialog", isMinimized: true)
        XCTAssertTrue(planner.plans(for: [saved, secondSaved], candidates: [standard])
            .allSatisfy { $0.candidate == nil })
    }

    func testMailSubroleFallbackDoesNotApplyToVisibleWindowsOrOtherApps() {
        for (bundle, minimized) in [("com.apple.mail", false), ("com.example.editor", true)] {
            let saved = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 100,
                windowTitle: "Saved Dialog", subrole: "AXDialog", isMinimized: minimized)
            let candidate = makeCandidate(id: 1, bundleIdentifier: bundle, pid: 200,
                title: "Main Window", frame: CGRect(x: 900, y: 700, width: 600, height: 500))

            XCTAssertNil(RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate]).first?.candidate)
        }
    }

    func testMinimizedMailSubroleFallbackPreservesDocumentRequirements() {
        let target = WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Saved/message.eml"))
        let saved = makeWindowRecord(bundleIdentifier: "com.apple.mail", pidAtCapture: 100,
            windowTitle: "Saved Message", subrole: "AXDialog", isMinimized: true,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier, pid: 200,
            title: "All Inboxes", frame: CGRect(x: 900, y: 700, width: 600, height: 500))

        XCTAssertNil(RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate]).first?.candidate)
    }

    func testPlansDoNotApplySingletonFallbackWithMultipleSavedWindows() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = "com.example.browser"
        let savedWindows = [
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                pidAtCapture: 100,
                windowTitle: "Saved Tab 1"
            ),
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                pidAtCapture: 101,
                windowTitle: "Saved Tab 2"
            )
        ]
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab",
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            )
        ]

        let plans = planner.plans(
            for: savedWindows,
            candidates: candidates
        )

        XCTAssertTrue(plans.allSatisfy { $0.candidate == nil })
        XCTAssertTrue(plans.allSatisfy { $0.skip?.reason == RestoreSkipReason.windowNotFound })
    }

    func testPlansDoNotApplySingletonFallbackWithMultipleCandidates() {
        let planner = RestoreWindowMatchPlanner()
        let bundleIdentifier = "com.example.browser"
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab"
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab 1",
                frame: CGRect(x: 900, y: 700, width: 300, height: 200)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: bundleIdentifier,
                pid: 200,
                title: "Different Tab 2",
                frame: CGRect(x: 1_200, y: 900, width: 300, height: 200)
            )
        ]

        let plans = planner.plans(
            for: [savedWindow],
            candidates: candidates
        )

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testPlansMatchSameTitleWindowsByNearestFrame() {
        let planner = RestoreWindowMatchPlanner()
        let firstSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            pidAtCapture: 100,
            windowTitle: "Project",
            frame: CGRect(x: 20, y: 30, width: 500, height: 400)
        )
        let secondSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            pidAtCapture: 101,
            windowTitle: "Project",
            frame: CGRect(x: 700, y: 30, width: 500, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.editor",
                pid: 200,
                title: "Project",
                frame: CGRect(x: 705, y: 35, width: 500, height: 400)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: "com.example.editor",
                pid: 201,
                title: "Project",
                frame: CGRect(x: 25, y: 35, width: 500, height: 400)
            )
        ]

        let plans = planner.plans(
            for: [firstSavedWindow, secondSavedWindow],
            candidates: candidates
        )

        XCTAssertEqual(plans.map { $0.candidate?.id }, [2, 1])
        XCTAssertTrue(plans.allSatisfy { $0.skip == nil })
    }

    func testPlansPreferStrongerLaterMatchOverEarlierNearestRoleMatch() {
        let planner = RestoreWindowMatchPlanner()
        let firstSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.browser",
            pidAtCapture: 100,
            windowTitle: nil,
            frame: CGRect(x: 20, y: 30, width: 500, height: 400)
        )
        let secondSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.browser",
            pidAtCapture: 101,
            windowTitle: "Important",
            frame: CGRect(x: 700, y: 30, width: 500, height: 400)
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.browser",
                pid: 200,
                title: "Important",
                frame: CGRect(x: 25, y: 35, width: 500, height: 400)
            ),
            makeCandidate(
                id: 2,
                bundleIdentifier: "com.example.browser",
                pid: 201,
                title: nil,
                frame: CGRect(x: 90, y: 100, width: 500, height: 400)
            )
        ]

        let plans = planner.plans(
            for: [firstSavedWindow, secondSavedWindow],
            candidates: candidates
        )

        XCTAssertEqual(plans.map { $0.candidate?.id }, [2, 1])
        XCTAssertTrue(plans.allSatisfy { $0.skip == nil })
    }

    func testPlansDoNotAssignOneLiveWindowToTwoSavedWindows() {
        let planner = RestoreWindowMatchPlanner()
        let firstSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.notes",
            pidAtCapture: 100,
            windowTitle: "Shared Title"
        )
        let secondSavedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.notes",
            pidAtCapture: 101,
            windowTitle: "Shared Title"
        )
        let candidates = [
            makeCandidate(
                id: 1,
                bundleIdentifier: "com.example.notes",
                pid: 200,
                title: "Shared Title"
            )
        ]

        let plans = planner.plans(
            for: [firstSavedWindow, secondSavedWindow],
            candidates: candidates
        )

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
        XCTAssertNil(plans.last?.candidate)
        XCTAssertEqual(plans.last?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testExplicitLocalTargetRejectsHomeAtCapturedPIDAndFrame() {
        let saved = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [
                WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Workspace"))
            ])
        )
        let home = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                 pid: saved.pidAtCapture, title: "Home", frame: saved.frame.cgRect)

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [home]).first

        XCTAssertNil(plan?.candidate)
        XCTAssertEqual(plan?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testExplicitLocalTargetsAllowConfirmedContentWhenAnotherTargetIsAbsent() {
        let first = URL(fileURLWithPath: "/Projects/First")
        let second = URL(fileURLWithPath: "/Projects/Second")
        let saved = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [
                WindowOpenTarget(kind: .folder, url: first),
                WindowOpenTarget(kind: .folder, url: second)
            ])
        )
        let partial = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                    pid: saved.pidAtCapture, documentURLs: [first],
                                    title: saved.windowTitle, frame: saved.frame.cgRect)
        let complete = makeCandidate(id: 2, bundleIdentifier: saved.bundleIdentifier,
                                     pid: 900, documentURLs: [first],
                                     documentTitles: ["shell: \(second.path)"], title: "Workspace")
        let planner = RestoreWindowMatchPlanner()

        XCTAssertEqual(planner.plans(for: [saved], candidates: [partial]).first?.candidate?.id, 1)
        XCTAssertEqual(planner.plans(for: [saved], candidates: [complete]).first?.candidate?.id, 2)
    }

    func testUnityProjectFolderDoesNotReplaceRequiredSavedSceneEvidence() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnitySceneMatching-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("ProjectSettings"),
                                                withIntermediateDirectories: true)
        try "m_EditorVersion: 6000.6.7f1\n".write(
            to: project.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true, encoding: .utf8)
        let savedScene = project.appendingPathComponent("Assets/SceneA.unity")
        let otherScene = project.appendingPathComponent("Assets/SceneB.unity")
        try Data().write(to: savedScene)
        try Data().write(to: otherScene)
        let saved = makeWindowRecord(
            bundleIdentifier: "com.unity3d.UnityEditor5.x", windowTitle: "Scene A",
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [
                WindowOpenTarget(kind: .file, url: savedScene),
                WindowOpenTarget(kind: .folder, url: project)
            ])
        )
        let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                      pid: saved.pidAtCapture, documentURLs: [otherScene, project],
                                      title: "Scene B", frame: saved.frame.cgRect)

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate]).first

        XCTAssertNil(plan?.candidate)
        XCTAssertEqual(plan?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testLocalTargetMatchingReassignsBroadMatchToRestoreConstrainedWindow() {
        let bundle = "com.example.editor"
        let targets = ["A.txt", "B.txt"].map {
            WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/\($0)"))
        }
        let saved = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, windowTitle: index == 0 ? "A" : "B",
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let candidates = [
            makeCandidate(id: 1, bundleIdentifier: bundle, pid: 900,
                          documentURLs: targets.map(\.url), title: "A"),
            makeCandidate(id: 2, bundleIdentifier: bundle, pid: 900,
                          documentURLs: [targets[0].url], title: "Only A")
        ]

        let plans = RestoreWindowMatchPlanner().plans(for: saved, candidates: candidates)

        XCTAssertEqual(plans.map { $0.candidate?.id }, [2, 1])
        XCTAssertTrue(plans.compactMap(\.skip).isEmpty)
    }

    func testPreferredRuntimePIDRejectsIdenticalContentInASiblingInstance() {
        let target = WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Shared"))
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor", pidAtCapture: 42,
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let sibling = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                    pid: 42, documentURLs: [target.url], title: saved.windowTitle)
        let preferred = makeCandidate(id: 2, bundleIdentifier: saved.bundleIdentifier,
                                      pid: 900, documentURLs: [target.url], title: "Runtime workspace")
        let planner = RestoreWindowMatchPlanner()

        XCTAssertEqual(planner.plans(for: [saved], candidates: [sibling, preferred],
                                     preferredProcessIdentifiers: [saved.id: 900]).first?.candidate?.id, 2)
        XCTAssertNil(planner.plans(for: [saved], candidates: [sibling],
                                  preferredProcessIdentifiers: [saved.id: 900]).first?.candidate)
    }

    func testRuntimePIDCannotReplaceSavedStandardWindowWithAnUnconfirmedRole() {
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor")
        for (role, subrole) in [("AXWindow", Optional("AXDialog")), ("AXDialog", nil), ("AXWindow", nil)] {
            let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier, pid: 900,
                title: "Unrelated dialog", role: role, subrole: subrole,
                frame: CGRect(x: 900, y: 700, width: 100, height: 100))

            let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate],
                preferredProcessIdentifiers: [saved.id: 900]).first

            XCTAssertNil(plan?.candidate, "Role: \(role), subrole: \(subrole ?? "nil")")
        }
    }

    func testRuntimePIDStillMatchesALegitimatelySavedDialog() {
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor", subrole: "AXDialog")
        let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier, pid: 900,
            title: "Dialog", subrole: "AXDialog")

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate],
            preferredProcessIdentifiers: [saved.id: 900]).first

        XCTAssertEqual(plan?.candidate?.id, 1)
    }

    func testRecoveredTitlelessCGWindowUsesExactCurrentCandidateAmongSiblings() {
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor", windowTitle: nil,
                                     subrole: nil, captureSource: .coreGraphics)
        let candidates = [1, 2].map { id in
            makeCandidate(id: id, bundleIdentifier: saved.bundleIdentifier, pid: 900, title: nil)
        }
        let planner = RestoreWindowMatchPlanner()

        XCTAssertEqual(planner.plans(for: [saved], candidates: candidates,
            preferredProcessIdentifiers: [saved.id: 900], preferredCandidateIdentifiers: [saved.id: 2])
            .first?.candidate?.id, 2)
        XCTAssertNil(planner.plans(for: [saved], candidates: [candidates[0]],
            preferredProcessIdentifiers: [saved.id: 900], preferredCandidateIdentifiers: [saved.id: 2])
            .first?.candidate)
    }

    func testTitlelessCGInstanceFallbackKeepsAmbiguousAndNonstandardOwnersUnmatched() {
        let bundle = "com.example.editor"
        let saved = [42, 43].map {
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0), windowTitle: nil,
                             subrole: nil, captureSource: .coreGraphics)
        }
        let ambiguous = [1, 2].map { makeCandidate(id: $0, bundleIdentifier: bundle, pid: 900, title: nil) }
        let dialog = [makeCandidate(id: 1, bundleIdentifier: bundle, pid: 900, title: nil, subrole: "AXDialog")]
        for firstOwner in [ambiguous, dialog] {
            let candidates = firstOwner + [makeCandidate(id: 3, bundleIdentifier: bundle, pid: 901, title: nil)]
            let plans = RestoreWindowMatchPlanner().plans(for: saved, candidates: candidates,
                preferredProcessIdentifiers: [saved[0].id: 900, saved[1].id: 901])

            XCTAssertNil(plans[0].candidate)
            XCTAssertEqual(plans[1].candidate?.id, 3)
        }
    }

    func testTitlelessCGFallbackDoesNotSplitMultipleSavedWindowsInOneProcess() {
        let bundle = "com.example.editor"
        let saved = (0..<2).map { _ in
            makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil, captureSource: .coreGraphics)
        }
        let candidates = [1, 2].map { makeCandidate(id: $0, bundleIdentifier: bundle, pid: 900, title: nil) }

        let plans = RestoreWindowMatchPlanner().plans(for: saved, candidates: candidates,
            preferredProcessIdentifiers: [saved[0].id: 900, saved[1].id: 900])

        XCTAssertTrue(plans.allSatisfy { $0.candidate == nil })
    }

    func testTitlelessCGFallbackRequiresCurrentProcessBindings() {
        let bundle = "com.example.editor"
        let saved = [42, 43].map {
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0), windowTitle: nil,
                             subrole: nil, captureSource: .coreGraphics)
        }
        let candidates = [900, 901].map { makeCandidate(id: $0, bundleIdentifier: bundle, pid: Int32($0), title: nil) }

        let plans = RestoreWindowMatchPlanner().plans(for: saved, candidates: candidates)

        XCTAssertTrue(plans.allSatisfy { $0.candidate == nil })
    }

    func testLocalTargetPathInsideAnotherAbsolutePathDoesNotConfirmContent() {
        let target = WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Users/test/Repo/Project"))
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor",
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let candidate = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                      pid: saved.pidAtCapture,
                                      documentTitles: ["shell: /Volumes/Backup/Users/test/Repo/Project"],
                                      title: saved.windowTitle, frame: saved.frame.cgRect)

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [candidate]).first

        XCTAssertNil(plan?.candidate)
        XCTAssertEqual(plan?.skip?.reason, RestoreSkipReason.windowNotFound)
    }

    func testManualEmptyTargetsPreserveAppOnlySingletonFallback() {
        let saved = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            openingConfiguration: WindowOpeningConfiguration(
                automaticallyCapturedTargets: [WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Saved"))],
                manualTargets: []
            )
        )
        let home = makeCandidate(id: 1, bundleIdentifier: saved.bundleIdentifier,
                                 pid: 900, title: "Home", frame: CGRect(x: 2_000, y: 2_000, width: 600, height: 400))

        let plan = RestoreWindowMatchPlanner().plans(for: [saved], candidates: [home]).first

        XCTAssertEqual(plan?.candidate?.id, 1)
        XCTAssertEqual(plan?.matchStrategy, .singleton)
    }

    func testZOrderPlannerRaisesBackToFront() {
        let planner = RestoreWindowZOrderPlanner()
        let backWindow = makeWindowRecord(bundleIdentifier: "com.example.back", zOrderHint: 3)
        let frontWindow = makeWindowRecord(bundleIdentifier: "com.example.front", zOrderHint: 1)
        let middleWindow = makeWindowRecord(bundleIdentifier: "com.example.middle", zOrderHint: 2)

        let raiseOrder = planner.raiseOrder(for: [
            makeZOrderItem(savedWindow: backWindow),
            makeZOrderItem(savedWindow: frontWindow),
            makeZOrderItem(savedWindow: middleWindow)
        ])

        XCTAssertEqual(raiseOrder.map(\.savedWindow.bundleIdentifier), [
            "com.example.back",
            "com.example.middle",
            "com.example.front"
        ])
        XCTAssertEqual(planner.frontmostItem(for: [
            makeZOrderItem(savedWindow: backWindow),
            makeZOrderItem(savedWindow: frontWindow),
            makeZOrderItem(savedWindow: middleWindow)
        ])?.savedWindow.bundleIdentifier, "com.example.front")
    }

    func testZOrderPlannerSkipsIneligibleWindows() {
        let planner = RestoreWindowZOrderPlanner()
        let visibleWindow = makeWindowRecord(bundleIdentifier: "com.example.visible", zOrderHint: 2)
        let missingHintWindow = makeWindowRecord(bundleIdentifier: "com.example.missingHint")
        let minimizedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.minimized",
            zOrderHint: 1,
            isMinimized: true
        )
        let hiddenWindow = makeWindowRecord(
            bundleIdentifier: "com.example.hidden",
            zOrderHint: 3,
            isVisible: false
        )

        let raiseOrder = planner.raiseOrder(for: [
            makeZOrderItem(savedWindow: missingHintWindow),
            makeZOrderItem(savedWindow: minimizedWindow),
            makeZOrderItem(savedWindow: visibleWindow),
            makeZOrderItem(savedWindow: hiddenWindow)
        ])

        XCTAssertEqual(raiseOrder.map(\.savedWindow.bundleIdentifier), ["com.example.visible"])
        XCTAssertEqual(
            planner.frontmostItem(for: [
                makeZOrderItem(savedWindow: missingHintWindow),
                makeZOrderItem(savedWindow: minimizedWindow),
                makeZOrderItem(savedWindow: visibleWindow),
                makeZOrderItem(savedWindow: hiddenWindow)
            ])?.savedWindow.bundleIdentifier,
            "com.example.visible"
        )
    }

    func testZOrderRestorerSelectsWindowBeforeActivatingAndRaisingBackToFront() async {
        var events: [String] = []
        let windowApplier = RecordingRestoreWindowApplier { events.append($0) }
        let applicationActivator = RecordingApplicationActivator { events.append($0) }
        let restorer = RestoreWindowZOrderRestorer(
            windowApplier: windowApplier,
            applicationActivator: applicationActivator
        )
        let backWindow = makeWindowRecord(bundleIdentifier: "com.example.back", zOrderHint: 3)
        let middleWindow = makeWindowRecord(bundleIdentifier: "com.example.middle", zOrderHint: 2)
        let frontWindow = makeWindowRecord(bundleIdentifier: "com.example.front", zOrderHint: 1)

        await restorer.restore([
            makeZOrderItem(savedWindow: frontWindow, processIdentifier: 101),
            makeZOrderItem(savedWindow: backWindow, processIdentifier: 303),
            makeZOrderItem(savedWindow: middleWindow, processIdentifier: 202)
        ])

        XCTAssertEqual(events, [
            "focus:com.example.back",
            "activate:303",
            "raise:com.example.back",
            "focus:com.example.middle",
            "activate:202",
            "raise:com.example.middle",
            "focus:com.example.front",
            "activate:101",
            "raise:com.example.front"
        ])
    }

    func testZOrderRestorerWaitsForDelayedWindowServerRaise() async {
        let result = await runZOrderSettleTest(frontWindowOrder: [2, 1])

        XCTAssertEqual(result.backWaits, 2)
        XCTAssertEqual(result.frontWaits, 3)
        XCTAssertEqual(result.events.filter { $0 == "raise:com.example.front" }.count, 2)
        let nextFocus = result.events.firstIndex(of: "focus:com.example.front")!
        XCTAssertEqual(result.events[..<nextFocus].filter { $0 == "wait:202" }.count, 2)
    }

    func testZOrderRestorerRequiresStableOrderAfterLateRaise() async {
        let result = await runZOrderSettleTest(frontWindowOrder: [1, 2, 1])

        XCTAssertEqual(result.frontWaits, 4)
        XCTAssertEqual(result.events.filter { $0 == "raise:com.example.front" }.count, 2)
    }

    func testZOrderRestorerBoundsWaitWhenRaiseNeverTakesEffect() async {
        let result = await runZOrderSettleTest(frontWindowOrder: [2])

        XCTAssertEqual(result.frontWaits, 19)
        XCTAssertEqual(result.events.filter { $0 == "raise:com.example.front" }.count, 21)
    }

    func testZOrderRestorerDoesNotWaitForWindowsOnSeparateDisplays() async {
        let result = await runZOrderSettleTest(frontWindowOrder: [2], overlapping: false)

        XCTAssertEqual(result.backWaits, 0)
        XCTAssertEqual(result.frontWaits, 0)
        XCTAssertEqual(result.events.filter { $0 == "raise:com.example.front" }.count, 1)
    }

    private func runZOrderSettleTest(
        frontWindowOrder: [CGWindowID],
        overlapping: Bool = true
    ) async -> (events: [String], backWaits: Int, frontWaits: Int) {
        var events: [String] = []
        var activePID: pid_t = 0
        var waits: [pid_t: Int] = [:]
        let reader = CGWindowMetadataReader { _ in
            let poll = waits[101, default: 0]
            let frontID: CGWindowID = activePID == 101
                ? frontWindowOrder[min(poll, frontWindowOrder.count - 1)] : 2
            let orderedIDs: [CGWindowID] = [frontID, frontID == 1 ? 2 : 1]
            return orderedIDs.map { id -> [String: Any] in
                let frame = CGRect(
                    x: !overlapping && id == 2 ? 500 : 0,
                    y: 0, width: 300, height: 200
                )
                return [
                    kCGWindowNumber as String: NSNumber(value: id),
                    kCGWindowOwnerPID as String: NSNumber(value: id == 1 ? 101 : 202),
                    kCGWindowLayer as String: 0,
                    kCGWindowIsOnscreen as String: true,
                    kCGWindowBounds as String: frame.dictionaryRepresentation
                ]
            }
        }
        let restorer = RestoreWindowZOrderRestorer(
            windowApplier: RecordingRestoreWindowApplier { events.append($0) },
            applicationActivator: RecordingApplicationActivator { event in
                events.append(event)
                activePID = event == "activate:101" ? 101 : 202
            },
            metadataReader: reader,
            settleSleeper: {
                events.append("wait:\(activePID)")
                waits[activePID, default: 0] += 1
            }
        )
        await restorer.restore([
            makeZOrderItem(
                savedWindow: makeWindowRecord(bundleIdentifier: "com.example.front", zOrderHint: 1),
                processIdentifier: 101, cgWindowID: 1
            ),
            makeZOrderItem(
                savedWindow: makeWindowRecord(bundleIdentifier: "com.example.back", zOrderHint: 2),
                processIdentifier: 202, cgWindowID: 2
            )
        ])
        return (events, waits[202, default: 0], waits[101, default: 0])
    }

    private func makeWindowRecord(
        bundleIdentifier: String,
        pidAtCapture: Int32 = 42,
        windowTitle: String? = "Window",
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
        zOrderHint: Int? = nil,
        isMinimized: Bool = false,
        isVisible: Bool = true,
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration(),
        captureSource: WindowCaptureSource? = nil
    ) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            frame: CGRectCodable(frame),
            displayID: 1,
            normalizedFrame: NormalizedRect(
                xRatio: 0,
                yRatio: 0,
                widthRatio: 0.5,
                heightRatio: 0.5
            ),
            zOrderHint: zOrderHint,
            isMinimized: isMinimized,
            isFullscreen: false,
            isVisible: isVisible,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: pidAtCapture,
                windowTitle: windowTitle,
                role: role,
                subrole: subrole,
                capturedFrame: CGRectCodable(frame),
                cgWindowID: nil,
                source: captureSource
            ),
            openingConfiguration: openingConfiguration
        )
    }

    private func makeCandidate(
        id: Int,
        bundleIdentifier: String,
        pid: pid_t,
        browserScriptingIdentifier: String? = nil,
        documentURLs: [URL] = [],
        documentTitles: [String] = [],
        title: String?,
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)
    ) -> RestoreWindowCandidate {
        RestoreWindowCandidate(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            browserScriptingIdentifier: browserScriptingIdentifier,
            documentURLs: documentURLs,
            documentTitles: documentTitles,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame
        )
    }

    private func makeZOrderItem(
        savedWindow: WindowRecord,
        processIdentifier: pid_t = 42,
        cgWindowID: CGWindowID? = nil
    ) -> RestoreWindowZOrderItem {
        RestoreWindowZOrderItem(
            savedWindow: savedWindow,
            processIdentifier: processIdentifier,
            liveWindow: DiscoveredWindow(
                axElement: AXUIElementCreateSystemWide(),
                title: savedWindow.bundleIdentifier,
                role: savedWindow.role,
                subrole: savedWindow.subrole,
                frame: savedWindow.frame.cgRect,
                isMinimized: savedWindow.isMinimized,
                isFullscreen: savedWindow.isFullscreen,
                isMain: false,
                isVisible: savedWindow.isVisible,
                cgWindowID: cgWindowID ?? savedWindow.captureSignature.cgWindowID,
                ownerName: nil,
                cgLayer: 0,
                zOrderHint: savedWindow.zOrderHint,
                isOnScreen: savedWindow.isVisible
            )
        )
    }
}

private final class RecordingRestoreWindowApplier: RestoreWindowApplying {
    private let record: (String) -> Void

    init(record: @escaping (String) -> Void) {
        self.record = record
    }

    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult {
        .restored()
    }

    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool {
        record("raise:\(discoveredWindow.title ?? "")")
        return true
    }

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult {
        record("focus:\(discoveredWindow.title ?? "")")
        return RestoreWindowFocusResult(
            didRaise: true,
            didSetMain: true,
            didSetFocused: true
        )
    }
}

private final class RecordingApplicationActivator: RestoreApplicationActivating {
    private let record: (String) -> Void

    init(record: @escaping (String) -> Void) {
        self.record = record
    }

    func activate(processIdentifier: pid_t) -> Bool {
        record("activate:\(processIdentifier)")
        return true
    }
}

final class RestoreEngineTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func testRestoreLogsStageTimingsAndTotalOnSuccessAndEarlyFailure() async throws {
        for isTrusted in [true, false] {
            let snapshot = makeSnapshot(windows: [])
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let logURL = temporaryDirectoryURL.appendingPathComponent("timing-\(isTrusted).log")
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { isTrusted },
                displayResolver: DisplayResolver(screenProvider: { [] }),
                applicationLauncher: RecordingApplicationLauncher(results: [:]),
                browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                applicationActivator: RecordingApplicationActivator { _ in },
                telemetryLogger: TelemetryLogger(eventsLogURL: logURL),
                discoveredApplicationsProvider: { [] }, runningApplicationBundleProvider: { [] })

            do {
                _ = try await engine.restoreSnapshot(id: snapshot.id)
                XCTAssertTrue(isTrusted)
            } catch RestoreEngineError.accessibilityPermissionDenied {
                XCTAssertFalse(isTrusted)
            }

            let events = try readTelemetryEvents(from: logURL)
            XCTAssertEqual(events.map(\.name), ["restore.started", isTrusted ? "restore.completed" : "restore.failed", "restore.timing"])
            XCTAssertTrue(events.allSatisfy { $0.snapshotID == snapshot.id })
            let timings = try XCTUnwrap(events.last?.timingsMilliseconds)
            let stages = isTrusted
                ? ["discovery", "spaceRecovery", "opening", "readiness", "matching", "positioning", "stacking", "total"]
                : ["discovery", "total"]
            XCTAssertEqual(Set(timings.keys), Set(stages))
            XCTAssertTrue(timings.values.allSatisfy { $0.isFinite && $0 >= 0 })
            let total = try XCTUnwrap(timings["total"])
            XCTAssertGreaterThanOrEqual(total, timings.filter { $0.key != "total" }.values.reduce(0, +))
        }
    }

    func testMissingInstalledAppRequestsLaunchBeforePlanning() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [
            makeWindowRecord(bundleIdentifier: bundleIdentifier)
        ])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([[], []])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.appNotRunning)
    }

    func testSuccessfulLaunchRediscoveryAllowsSavedWindowToRestore() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Project Notes"
        )
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([
            [],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: "Project Notes",
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])
        let windowApplier = RecordingEngineWindowApplier()

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            windowApplier: windowApplier
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(windowApplier.appliedBundleIdentifiers, [bundleIdentifier])
    }

    func testUnverifiedWindowIsSkippedAndExcludedFromZOrderReplay() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Project Notes",
            zOrderHint: 0
        )
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let windowApplier = RecordingEngineWindowApplier(
            result: .failed(reason: RestoreSkipReason.windowGeometryDidNotSettle)
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application]]),
            windowApplier: windowApplier
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(
            result.skippedItems.first?.reason,
            RestoreSkipReason.windowGeometryDidNotSettle
        )
        XCTAssertEqual(windowApplier.raiseCount, 0)
        XCTAssertEqual(windowApplier.focusCount, 0)
    }

    func testUnresolvableLaunchLeavesSavedWindowSkippedAsAppNotRunning() async throws {
        let bundleIdentifier = "com.example.missing"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [
            makeWindowRecord(bundleIdentifier: bundleIdentifier)
        ])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: false])
        let discovery = DiscoverySequence([[]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.appNotRunning)
        XCTAssertEqual(discovery.callCount, 1)
    }

    func testColdLaunchedSingletonUsesRoleFallback() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                windowTitle: "Saved Document"
            )
        ])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([
            [],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: "Welcome",
                            frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
    }

    func testColdLaunchedMinimizedMailMatchesChangedSubroleAndMessageCounts() async throws {
        let bundle = "com.apple.mail"
        let saved = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 100,
            windowTitle: "All Inboxes – All Mail · 2,732 messages, 1,590 unread",
            subrole: "AXDialog", frame: CGRect(x: 49, y: 197, width: 1512, height: 810),
            zOrderHint: 1, isMinimized: true)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [saved])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundle: true])
        let discovery = DiscoverySequence([[], [makeApplication(bundleIdentifier: bundle, pid: 200, windows: [
            makeDiscoveredWindow(title: "All Inboxes – All Mail · 2,735 messages, 1,587 unread",
                frame: CGRect(x: 140, y: 134, width: 1512, height: 810))
        ])]])
        let applier = RecordingEngineWindowApplier()
        let clock = TestClock()

        let result = try await makeEngine(store: store, launcher: launcher, discovery: discovery,
            windowApplier: applier, launchTimeout: 1, launchClock: clock.now,
            launchPollSleeper: clock.sleep).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundle])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
        XCTAssertEqual(result.windowDiagnostics.first?.readinessTimedOut, false)
        XCTAssertEqual(applier.appliedSavedWindowIDs, [saved.id])
        XCTAssertEqual(applier.raiseCount, 0)
        XCTAssertEqual(applier.focusCount, 0)
        XCTAssertEqual(discovery.callCount, 2)
    }

    func testRunningTitlelessCGSingletonRestoresItsPositionWithoutLaunching() async throws {
        for bundle in ["com.apple.Safari", "net.whatsapp.WhatsApp", "com.example.editor"] {
            for pid: pid_t in [42, 900] {
                let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil,
                    subrole: nil, captureSource: .coreGraphics)
                let snapshot = makeSnapshot(windows: [saved])
                let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
                try store.save(snapshot)
                let launcher = RecordingApplicationLauncher(results: [:])
                let opener = RecordingTargetOpener()
                let applier = RecordingEngineWindowApplier()
                let live = makeApplication(bundleIdentifier: bundle, pid: pid, windows: [
                    makeDiscoveredWindow(title: "Current window", frame: CGRect(x: 900, y: 700, width: 800, height: 600),
                        cgWindowID: 901)
                ])

                let result = try await makeEngine(store: store, launcher: launcher,
                    discovery: DiscoverySequence([[live]]), windowApplier: applier, targetOpener: opener)
                    .restoreSnapshot(id: snapshot.id)

                XCTAssertEqual(result.restoredWindows, 1, "\(bundle), PID \(pid)")
                XCTAssertTrue(result.skippedItems.isEmpty)
                XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
                XCTAssertEqual(applier.appliedCGWindowIDs, [901])
                XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
                XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
                XCTAssertTrue(opener.requests.isEmpty)
            }
        }
    }

    func testRunningCGWindowRestoresWhenMinimizedWindowReportsNonmodalDialog() async throws {
        for bundle in ["net.whatsapp.WhatsApp", "com.example.editor"] {
            for savedMinimized in [false, true] {
                let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil,
                    isMinimized: savedMinimized, captureSource: .coreGraphics, cgWindowID: 901)
                let snapshot = makeSnapshot(windows: [saved])
                let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
                try store.save(snapshot)
                let applier = RecordingEngineWindowApplier()
                let launcher = RecordingApplicationLauncher(results: [:])
                let live = makeApplication(bundleIdentifier: bundle, pid: saved.pidAtCapture, windows: [
                    makeDiscoveredWindow(title: nil, subrole: "AXDialog", frame: saved.frame.cgRect,
                        cgWindowID: 901, isMinimized: true, isModal: false)
                ])

                let result = try await makeEngine(store: store, launcher: launcher,
                    discovery: DiscoverySequence([[live]]), windowApplier: applier).restoreSnapshot(id: snapshot.id)

                XCTAssertEqual(result.restoredWindows, 1)
                XCTAssertTrue(result.skippedItems.isEmpty)
                XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
                XCTAssertEqual(applier.appliedCGWindowIDs, [901])
                XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
            }
        }
    }

    func testRunningCGWindowRejectsUnconfirmedMinimizedDialogs() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil,
            captureSource: .coreGraphics, cgWindowID: 901)
        let cases: [(pid: pid_t, id: CGWindowID?, minimized: Bool, modal: Bool?)] = [
            (42, 901, true, true), (42, 901, true, nil), (42, 901, false, false),
            (42, nil, true, false), (42, 902, true, false), (200, 901, true, false)
        ]
        for item in cases {
            let snapshot = makeSnapshot(windows: [saved])
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let applier = RecordingEngineWindowApplier()
            let live = makeApplication(bundleIdentifier: bundle, pid: item.pid, windows: [
                makeDiscoveredWindow(title: nil, subrole: "AXDialog", frame: saved.frame.cgRect,
                    cgWindowID: item.id, isMinimized: item.minimized, isModal: item.modal)
            ])

            let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                discovery: DiscoverySequence([[live]]), windowApplier: applier).restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 0, "\(item)")
            XCTAssertEqual(result.skippedItems.count, 1)
            XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
        }
    }

    func testRunningCGMinimizedDialogDoesNotBypassAmbiguityChecks() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil,
            captureSource: .coreGraphics, cgWindowID: 901)
        let dialog = makeDiscoveredWindow(title: nil, subrole: "AXDialog", frame: saved.frame.cgRect,
            cgWindowID: 901, isMinimized: true, isModal: false)
        let cases: [(saved: [WindowRecord], applications: [DiscoveredApplication])] = [
            ([saved], [makeApplication(bundleIdentifier: bundle, pid: 42, windows: [dialog,
                makeDiscoveredWindow(title: nil, frame: saved.frame.cgRect, cgWindowID: 902)])]),
            ([saved], [makeApplication(bundleIdentifier: bundle, pid: 42, windows: [dialog]),
                makeApplication(bundleIdentifier: bundle, pid: 200, windows: [dialog])]),
            ([saved, makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil,
                captureSource: .coreGraphics)], [makeApplication(bundleIdentifier: bundle, pid: 42, windows: [dialog])])
        ]
        for item in cases {
            let snapshot = makeSnapshot(windows: item.saved)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let applier = RecordingEngineWindowApplier()

            let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                discovery: DiscoverySequence([item.applications]), windowApplier: applier).restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 0)
            XCTAssertEqual(result.skippedItems.count, item.saved.count)
            XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
        }
    }

    func testVerifiedMinimizedDialogMovesUsingFreshWindowIdentity() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil,
            captureSource: .coreGraphics, cgWindowID: 901)
        let display = makeDisplayRecord(id: 1)
        let snapshot = Snapshot(name: "Minimized app window",
            sourceDisplayState: DisplayState(displays: [display], primaryDisplayID: 1), windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = makeApplication(bundleIdentifier: bundle, pid: saved.pidAtCapture, windows: [
            makeDiscoveredWindow(title: nil, subrole: "AXDialog", frame: saved.frame.cgRect,
                cgWindowID: 901, isMinimized: true, isModal: false)
        ])
        let inventory = RestoreSpaceInventory(activeByDisplay: [1: 11], ordinarySpaceIDs: [3, 11])
        var membership: Set<UInt64> = [3]
        var movedIDs: [CGWindowID] = []
        let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
            inventory: { _ in inventory }, membership: { _ in membership },
            submitMove: { id, space in
                movedIDs.append(id)
                membership = [space]
                return true
            }), sleeper: {})
        let applier = RecordingEngineWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: DisplayResolver(screenProvider: {
                [DisplayResolver.ScreenSnapshot(id: 1, localizedName: display.localizedName,
                    frame: display.frameRect, visibleFrame: display.visibleFrameRect, backingScaleFactor: 1,
                    isPrimary: true, vendorID: nil, productID: nil, serialNumber: nil)]
            }), applicationLauncher: RecordingApplicationLauncher(results: [:]),
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in }, spaces: spaces,
            discoveredApplicationsProvider: { [live] }, runningApplicationBundleProvider: { [bundle] })

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(movedIDs, [901])
        XCTAssertEqual(applier.appliedCGWindowIDs, [901])
    }

    func testRunningTitlelessCGSingletonRejectsAmbiguousAndNonstandardWindows() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil,
            subrole: nil, captureSource: .coreGraphics)
        let standard = makeDiscoveredWindow(title: nil, frame: saved.frame.cgRect, cgWindowID: 901)
        let cases: [[DiscoveredApplication]] = [
            [makeApplication(bundleIdentifier: bundle, windows: [standard,
                makeDiscoveredWindow(title: nil, frame: saved.frame.cgRect, cgWindowID: 902)])],
            [makeApplication(bundleIdentifier: bundle, windows: [standard]),
             makeApplication(bundleIdentifier: bundle, pid: 201, windows: [standard])],
            [makeApplication(bundleIdentifier: bundle, windows: [standard]),
             makeApplication(bundleIdentifier: bundle, pid: 201, windows: [])],
            [makeApplication(bundleIdentifier: bundle, windows: [
                makeDiscoveredWindow(title: nil, subrole: "AXDialog", frame: saved.frame.cgRect)])],
            [makeApplication(bundleIdentifier: bundle, windows: [
                makeDiscoveredWindow(title: nil, subrole: nil, frame: saved.frame.cgRect)])],
            [makeApplication(bundleIdentifier: bundle, windows: [
                makeDiscoveredWindow(title: nil, role: "AXSheet", frame: saved.frame.cgRect)])],
            [makeApplication(bundleIdentifier: "com.example.other", windows: [standard])]
        ]
        for (index, applications) in cases.enumerated() {
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [saved])
            try store.save(snapshot)
            let applier = RecordingEngineWindowApplier()
            let launcher = RecordingApplicationLauncher(results: [:])

            let result = try await makeEngine(store: store, launcher: launcher,
                discovery: DiscoverySequence([applications]), windowApplier: applier, launchTimeout: 0)
                .restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 0, "case \(index)")
            XCTAssertEqual(result.skippedItems.count, 1)
            XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
        }
    }

    func testRunningTitlelessCGFallbackDoesNotChooseBetweenSavedWindows() async throws {
        let bundle = "com.example.editor"
        let saved = (0..<2).map { _ in
            makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil, captureSource: .coreGraphics)
        }
        let snapshot = makeSnapshot(windows: saved)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = makeApplication(bundleIdentifier: bundle, windows: [
            makeDiscoveredWindow(title: nil, frame: saved[0].frame.cgRect, cgWindowID: 901)
        ])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[live]]), windowApplier: applier).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 2)
        XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
    }

    func testRunningTitlelessCGSingletonDoesNotIgnoreUnexposedWindows() async throws {
        let bundle = "com.example.editor"
        let cases: [(pid_t, Bool, Bool)] = [(200, true, false), (201, true, false), (201, false, false),
            (200, true, true), (201, true, true), (201, false, true)]
        for (hiddenPID, hasWindow, dialog) in cases {
            let saved = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 200, windowTitle: nil,
                subrole: nil, captureSource: .coreGraphics, cgWindowID: 901)
            let snapshot = makeSnapshot(windows: [saved])
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let applier = RecordingEngineWindowApplier()
            let live = makeApplication(bundleIdentifier: bundle, windows: [
                makeDiscoveredWindow(title: nil, subrole: dialog ? "AXDialog" : "AXStandardWindow",
                    frame: saved.frame.cgRect, cgWindowID: 901, isMinimized: dialog, isModal: false)
            ])
            let unexposed = UnexposedApplicationWindows(bundleIdentifier: bundle, pid: hiddenPID, windows: hasWindow ? [
                CGWindowMetadata(windowID: 902, processIdentifier: hiddenPID, ownerName: nil, layer: 0,
                    bounds: saved.frame.cgRect, title: nil, isOnScreen: false, zOrderHint: nil)
            ] : [])
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                applicationLauncher: RecordingApplicationLauncher(results: [:]),
                browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                applicationActivator: RecordingApplicationActivator { _ in },
                discoveryResultProvider: {
                    WindowDiscoveryResult(applications: [live], diagnostics: [], unexposedApplications: [unexposed])
                }, runningApplicationBundleProvider: { [bundle] })

            let result = try await engine.restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 0)
            XCTAssertEqual(result.skippedItems.count, 1)
            XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
        }
    }

    func testColdLaunchedTitlelessCGSingletonRestoresItsPosition() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil, captureSource: .coreGraphics)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [saved])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundle: true])
        let applier = RecordingEngineWindowApplier()
        let discovery = DiscoverySequence([[], [makeApplication(bundleIdentifier: bundle, windows: [
            makeDiscoveredWindow(title: nil, frame: CGRect(x: 900, y: 700, width: 100, height: 100), cgWindowID: 901)
        ])]])

        let result = try await makeEngine(store: store, launcher: launcher, discovery: discovery,
            windowApplier: applier, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundle])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedCGWindowIDs, [901])
    }

    func testColdLaunchedTitlelessCGCaptureDoesNotChooseBetweenSeveralWindows() async throws {
        let bundle = "com.example.editor"
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil, captureSource: .coreGraphics)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [saved])
        try store.save(snapshot)
        let applier = RecordingEngineWindowApplier()
        let discovery = DiscoverySequence([[], [makeApplication(bundleIdentifier: bundle, windows: [
            makeDiscoveredWindow(title: nil, frame: saved.frame.cgRect, cgWindowID: 901),
            makeDiscoveredWindow(title: "Another", frame: saved.frame.cgRect, cgWindowID: 902)
        ])]])

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [bundle: true]),
            discovery: discovery, windowApplier: applier, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.windowNotFound])
        XCTAssertTrue(applier.appliedCGWindowIDs.isEmpty)
    }

    func testColdTitlelessCGRestoreUsesOnlyTheReturnedProcess() async throws {
        for returnedPID: pid_t in [200, 999] {
            let bundle = "com.example.editor"
            let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: nil, subrole: nil, captureSource: .coreGraphics)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [saved])
            try store.save(snapshot)
            let applier = RecordingEngineWindowApplier()
            let applications = [200, 201].map { pid in
                makeApplication(bundleIdentifier: bundle, pid: pid_t(pid), windows: [
                    makeDiscoveredWindow(title: nil, frame: saved.frame.cgRect, cgWindowID: CGWindowID(pid))
                ])
            }
            let result = try await makeEngine(store: store,
                launcher: RecordingApplicationLauncher(results: [bundle: true], launchPID: returnedPID),
                discovery: DiscoverySequence([[], applications]), windowApplier: applier, launchTimeout: 0)
                .restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, returnedPID == 200 ? 1 : 0)
            XCTAssertEqual(applier.appliedCGWindowIDs, returnedPID == 200 ? [200] : [])
        }
    }

    func testReadyAppInstancesRestoreBeforePendingAppWithinSharedDeadline() async throws {
        for applyDuration: TimeInterval in [0, 5] {
            let readyBundle = "com.example.ready"
            let pendingBundle = "com.example.pending"
            let targets = try ["Ready-A.txt", "Ready-B.txt", "Pending.txt"].map {
                WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
            }
            let readyWindows = targets.prefix(2).enumerated().map { index, target in
                makeWindowRecord(bundleIdentifier: readyBundle, pidAtCapture: Int32(42 + index),
                    openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
            }
            let pendingWindow = makeWindowRecord(bundleIdentifier: pendingBundle,
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [targets[2]]))
            let snapshot = makeSnapshot(windows: readyWindows + [pendingWindow])
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let clock = TestClock()
            let start = clock.now()
            let applier = RecordingEngineWindowApplier(onApply: { await clock.sleep(interval: applyDuration) })
            let opener = RecordingTargetOpener()
            let live = targets.prefix(2).enumerated().map { index, target in
                makeApplication(bundleIdentifier: readyBundle, pid: Int32(900 + index), windows: [
                    makeDiscoveredWindow(documentURL: target.url, title: "Ready \(index)",
                        frame: readyWindows[index].frame.cgRect, cgWindowID: CGWindowID(9001 + index))
                ])
            }
            var sleeps = 0
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
                browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                applicationActivator: RecordingApplicationActivator { _ in },
                discoveredApplicationsProvider: { live },
                runningApplicationBundleProvider: { [readyBundle, pendingBundle] }, launchClock: clock.now,
                launchPollSleeper: { _ in
                    XCTAssertEqual(Set(applier.appliedSavedWindowIDs), Set(readyWindows.map(\.id)))
                    XCTAssertEqual(applier.raiseCount, 0)
                    XCTAssertEqual(applier.focusCount, 0)
                    sleeps += 1
                    await clock.sleep(interval: 5)
                })

            let result = try await engine.restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertEqual(result.skippedItems.count, 1)
            XCTAssertEqual(result.windowDiagnostics.filter(\.readinessTimedOut).map(\.windowID), [pendingWindow.id])
            XCTAssertEqual(clock.now().timeIntervalSince(start), 15)
            XCTAssertEqual(sleeps, applyDuration == 0 ? 3 : 1)
            XCTAssertEqual(opener.requests.map(\.bundleIdentifier), [pendingBundle])
            XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [9001, 9002])
        }
    }

    func testPendingTargetKeepsSameAppWindowsTogetherWhenOpeningReusesWindow() async throws {
        let bundle = "com.example.editor"
        let targets = try ["Reused-A.txt", "Reused-B.txt"].map {
            WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
        }
        let saved = targets.map { target in
            makeWindowRecord(bundleIdentifier: bundle,
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: saved)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let clock = TestClock()
        let start = clock.now()
        let applier = RecordingEngineWindowApplier()
        let opener = RecordingTargetOpener()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in },
            discoveredApplicationsProvider: {
                let index = clock.now() == start ? 0 : 1
                return [self.makeApplication(bundleIdentifier: bundle, windows: [
                    self.makeDiscoveredWindow(documentURL: targets[index].url, title: "Reused window",
                        frame: saved[index].frame.cgRect, cgWindowID: 9001)
                ])]
            }, runningApplicationBundleProvider: { [bundle] }, launchClock: clock.now,
            launchPollSleeper: { _ in
                XCTAssertTrue(applier.appliedSavedWindowIDs.isEmpty)
                await clock.sleep(interval: 5)
            })

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(applier.appliedSavedWindowIDs, [saved[1].id])
        XCTAssertEqual(opener.requests.flatMap(\.targets).map(\.url), [targets[1].url])
    }

    func testDefaultReadinessBudgetRestoresFastAndSlowAppInstancesWithoutReopening() async throws {
        let bundle = "com.example.editor"
        for readyAfter: TimeInterval in [0, 10, 15] {
            let targets = try ["Slow-A.txt", "Slow-B.txt"].map {
                WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
            }
            let saved = targets.enumerated().map { index, target in
                makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(42 + index),
                    openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
            }
            let snapshot = makeSnapshot(windows: saved)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let clock = TestClock()
            let start = clock.now()
            var openedCount = 0
            let opener = RecordingTargetOpener(results: [.openedApplicationInstance(900), .openedApplicationInstance(901)],
                onOpen: { _ in openedCount += 1 })
            let launcher = RecordingApplicationLauncher(results: [:])
            let applier = RecordingEngineWindowApplier()
            let live = targets.enumerated().map { index, target in
                makeApplication(bundleIdentifier: bundle, pid: Int32(900 + index), windows: [
                    makeDiscoveredWindow(documentURL: target.url, title: "Ready document \(index)",
                        frame: saved[index].frame.cgRect, cgWindowID: CGWindowID(9001 + index))
                ])
            }
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                applicationLauncher: launcher, targetOpener: opener,
                browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                applicationActivator: RecordingApplicationActivator { _ in },
                discoveredApplicationsProvider: {
                    openedCount == 2 && clock.now().timeIntervalSince(start) >= readyAfter ? live : []
                }, runningApplicationBundleProvider: { [] }, launchClock: clock.now,
                launchPollSleeper: { _ in await clock.sleep(interval: 5) })

            let result = try await engine.restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertTrue(result.skippedItems.isEmpty)
            XCTAssertTrue(result.targetIssues.isEmpty)
            XCTAssertFalse(result.windowDiagnostics.contains(where: \.readinessTimedOut))
            XCTAssertEqual(clock.now().timeIntervalSince(start), readyAfter)
            XCTAssertEqual(opener.requests.count, 2)
            XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [9001, 9002])
            XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        }
    }

    func testDefaultReadinessBudgetStillFinishesWhenAnAppNeverBecomesReady() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Never-ready.txt"))
        let saved = makeWindowRecord(bundleIdentifier: bundle,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let clock = TestClock()
        let start = clock.now()
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in }, discoveredApplicationsProvider: { [] },
            runningApplicationBundleProvider: { [] }, launchClock: clock.now,
            launchPollSleeper: { _ in await clock.sleep(interval: 5) })

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(clock.now().timeIntervalSince(start), 15)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openingNotConfirmed])
        XCTAssertEqual(result.windowDiagnostics.map(\.readinessTimedOut), [true])
        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertTrue(applier.appliedCGWindowIDs.isEmpty)
    }

    func testCancelledReadinessStopsPollingWithoutReopeningTargets() async throws {
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Cancelled-startup.txt"))
        let snapshot = makeSnapshot(windows: [makeWindowRecord(bundleIdentifier: "com.example.editor",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let clock = TestClock()
        let start = clock.now()
        var sleeps = 0
        let logURL = temporaryDirectoryURL.appendingPathComponent("cancelled-timing.log")
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in },
            telemetryLogger: TelemetryLogger(eventsLogURL: logURL), discoveredApplicationsProvider: { [] },
            runningApplicationBundleProvider: { [] }, launchClock: clock.now,
            launchPollSleeper: { _ in
                sleeps += 1
                await clock.sleep(interval: 10)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        let restore = Task { try await engine.restoreSnapshot(id: snapshot.id) }

        do {
            _ = try await restore.value
            XCTFail("Expected cancellation while waiting for the document")
        } catch is CancellationError {}

        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 10)
        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertTrue(applier.appliedCGWindowIDs.isEmpty)
        let events = try readTelemetryEvents(from: logURL)
        XCTAssertEqual(events.first?.name, "restore.started")
        XCTAssertEqual(events.last?.name, "restore.timing")
        let timings = try XCTUnwrap(events.last?.timingsMilliseconds)
        XCTAssertNotNil(timings["readiness"])
        XCTAssertNotNil(timings["total"])
        XCTAssertNil(timings["positioning"])
    }

    func testColdSingletonReadinessReturnsAtFirstStandardWindow() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Project Notes",
            frame: CGRect(x: 10, y: 20, width: 500, height: 400)
        )
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([
            [],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: "Welcome",
                            frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                        )
                    ]
                )
            ],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: "Project Notes",
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])
        let clock = TestClock()

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            launchTimeout: 1,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(discovery.callCount, 2)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
    }

    func testAlreadyRunningAppDoesNotRequestLaunch() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let savedWindow = makeWindowRecord(bundleIdentifier: bundleIdentifier)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testAlreadyRunningSingletonUsesRoleFallback() async throws {
        let bundleIdentifier = "com.example.editor"
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Saved Document",
            frame: CGRect(x: 10, y: 20, width: 500, height: 400)
        )
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let discovery = DiscoverySequence([
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: "Renamed Document",
                            frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                        )
                    ]
                )
            ]
        ])
        let windowApplier = RecordingEngineWindowApplier()

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            windowApplier: windowApplier
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
        XCTAssertEqual(windowApplier.appliedBundleIdentifiers, [bundleIdentifier])
    }

    func testWorkGhosttyUsesAutomaticTargetEvidenceWithoutOpeningTarget() async throws {
        let bundleIdentifier = "com.mitchellh.ghostty"
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("solvoyo/web-react18", isDirectory: true)
        let automaticTarget = WindowOpenTarget(kind: .folder, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 20_351,
            windowTitle: "~/solvoyo/web-react18",
            frame: CGRect(x: -852, y: -1_410, width: 1_653, height: 1_410),
            zOrderHint: 1,
            openingConfiguration: WindowOpeningConfiguration(
                automaticallyCapturedTargets: [automaticTarget],
                manualTargets: []
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let windowApplier = RecordingEngineWindowApplier()
        let liveWindow = makeDiscoveredWindow(
            documentTitles: ["~/solvoyo/web-react18"],
            title: "lg",
            frame: CGRect(x: 1_495, y: -1_405, width: 1_280, height: 1_410)
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([
                [
                    makeApplication(
                        bundleIdentifier: bundleIdentifier,
                        pid: 694,
                        windows: [liveWindow]
                    )
                ]
            ]),
            windowApplier: windowApplier,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .scored)
        XCTAssertEqual(windowApplier.appliedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(windowApplier.focusCount, 0)
    }

    func testLocalTargetsAreOpenedSequentiallyInOrderIncludingDuplicates() async throws {
        let bundleIdentifier = "com.example.editor"
        let firstURL = try makeFile(named: "First.txt")
        let secondURL = try makeFile(named: "Second.txt")
        let folderURL = try makeFolder(named: "Project")
        let targets = [
            WindowOpenTarget(kind: .file, url: firstURL),
            WindowOpenTarget(kind: .folder, url: folderURL),
            WindowOpenTarget(kind: .file, url: secondURL),
            WindowOpenTarget(kind: .file, url: firstURL)
        ]
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: targets)
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let targetOpener = RecordingTargetOpener()
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(bundleIdentifier: bundleIdentifier, windows: [
            makeDiscoveredWindow(documentURLs: targets.map(\.url), title: savedWindow.windowTitle, frame: savedWindow.frame.cgRect)
        ])
        let discovery = DiscoverySequence([[application], [readyApplication]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener,
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.map(\.bundleIdentifier), Array(
            repeating: bundleIdentifier,
            count: targets.count
        ))
        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            targets.map { [$0.url] }
        )
        XCTAssertEqual(result.requestedTargetCount, 4)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
    }

    func testSuccessfulTargetOpeningCanLaunchClosedApplication() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Project.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Project",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let targetOpener = RecordingTargetOpener()
        let discovery = DiscoverySequence([
            [],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            documentURL: targetURL,
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect,
                            cgWindowID: 9001
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertEqual(discovery.callCount, 2)
    }

    func testMissingTargetIsReportedWhileValidTargetsContinue() async throws {
        let bundleIdentifier = "com.example.editor"
        let missingURL = temporaryDirectoryURL.appendingPathComponent("Missing.txt")
        let validURL = try makeFile(named: "Valid.txt")
        let missingTarget = WindowOpenTarget(kind: .file, url: missingURL)
        let validTarget = WindowOpenTarget(kind: .file, url: validURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [missingTarget, validTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let initialApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: validURL,
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[initialApplication], [readyApplication]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.first?.targets.map(\.url), [validURL])
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.targetIssues.count, 1)
        XCTAssertEqual(result.targetIssues.first?.target.url, missingURL)
        XCTAssertEqual(result.targetIssues.first?.reason, .missingTarget)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testTargetKindMismatchIsReportedWithoutOpeningTarget() async throws {
        let bundleIdentifier = "com.example.editor"
        let fileURL = try makeFile(named: "NotAFolder.txt")
        let target = WindowOpenTarget(kind: .folder, url: fileURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[application]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.targetIssues.first?.reason, .targetKindMismatch)
        XCTAssertEqual(discovery.callCount, 1)
    }

    func testFailedTargetBatchFallsBackToNormalApplicationLaunch() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Project.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let targetOpener = RecordingTargetOpener(
            results: [.failed(.openRequestFailed)]
        )
        let discovery = DiscoverySequence([
            [],
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.targetIssues.first?.reason, .openRequestFailed)
        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
    }

    func testFailedTargetRequestDoesNotPreventFollowingTarget() async throws {
        let bundleIdentifier = "com.example.editor"
        let firstTarget = WindowOpenTarget(
            kind: .file,
            url: try makeFile(named: "First.txt")
        )
        let secondTarget = WindowOpenTarget(
            kind: .file,
            url: try makeFile(named: "Second.txt")
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [firstTarget, secondTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let initialApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: secondTarget.url,
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let targetOpener = RecordingTargetOpener(
            results: [.failed(.openRequestFailed), .opened]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[initialApplication], [readyApplication]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            [[firstTarget.url], [secondTarget.url]]
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.targetIssues.map(\.target.url), [firstTarget.url])
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openRequestFailed])
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testUnavailableApplicationReportsTargetsAndDoesNotCountThemAsSubmitted() async throws {
        let bundleIdentifier = "com.example.missing"
        let targetURL = try makeFile(named: "Project.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: false])
        let targetOpener = RecordingTargetOpener(
            results: [.failed(.applicationUnavailable)]
        )
        let discovery = DiscoverySequence([[]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.targetIssues.first?.reason, .applicationUnavailable)
        XCTAssertEqual(launcher.requestedBundleIdentifiers, [bundleIdentifier])
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.appNotRunning)
        XCTAssertEqual(discovery.callCount, 1)
    }

    func testSeparateSavedWindowsProduceSeparateTargetBatches() async throws {
        let bundleIdentifier = "com.example.editor"
        let firstTarget = WindowOpenTarget(
            kind: .file,
            url: try makeFile(named: "First.txt")
        )
        let secondTarget = WindowOpenTarget(
            kind: .file,
            url: try makeFile(named: "Second.txt")
        )
        let firstWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "First",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [firstTarget])
        )
        let secondWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Second",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [secondTarget])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let initialApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(title: "First", frame: firstWindow.frame.cgRect),
                makeDiscoveredWindow(title: "Second", frame: secondWindow.frame.cgRect)
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: firstTarget.url,
                    title: "First",
                    frame: firstWindow.frame.cgRect
                ),
                makeDiscoveredWindow(
                    documentURL: secondTarget.url,
                    title: "Second",
                    frame: secondWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[initialApplication], [readyApplication]])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.map { $0.targets.map(\.url) }, [
            [firstTarget.url],
            [secondTarget.url]
        ])
        XCTAssertEqual(result.requestedTargetCount, 2)
    }

    func testVisualStudioCodeOpensEachSavedWindowInANewWindow() async throws {
        let bundleIdentifier = "com.microsoft.VSCode"
        let scrollSnapTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "ScrollSnap")
        )
        let zapPDFTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "ZapPDF")
        )
        let scrollSnapWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "ScrollSnap",
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [scrollSnapTarget]
            )
        )
        let zapPDFWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "ZapPDF",
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [zapPDFTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [scrollSnapWindow, zapPDFWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: scrollSnapTarget.url,
                    title: scrollSnapWindow.windowTitle,
                    frame: scrollSnapWindow.frame.cgRect
                ),
                makeDiscoveredWindow(
                    documentURL: zapPDFTarget.url,
                    title: zapPDFWindow.windowTitle,
                    frame: zapPDFWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            [[scrollSnapTarget.url], [zapPDFTarget.url]]
        )
        XCTAssertEqual(
            targetOpener.requests.map(\.disposition),
            [.newWindow, .newWindow]
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testAntigravityRestoresOpenedWindowsWhenTitlesAndFramesChange() async throws {
        let bundleIdentifier = "com.google.antigravity-ide"
        let zapPDFTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "ZapPDF")
        )
        let webReactTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "web-react18")
        )
        let zapPDFWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "ZapPDF — review-issue-suggestions.md",
            frame: CGRect(x: 20, y: 30, width: 600, height: 400),
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [zapPDFTarget]
            )
        )
        let webReactWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "web-react18 — index.tsx",
            frame: CGRect(x: 700, y: 30, width: 600, height: 400),
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [webReactTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [zapPDFWindow, webReactWindow])
        try store.save(snapshot)
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: zapPDFTarget.url,
                    title: "review-issue-suggestions.md — ZapPDF",
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                ),
                makeDiscoveredWindow(
                    documentURL: webReactTarget.url,
                    title: "index.tsx — web-react18",
                    frame: CGRect(x: 100, y: 700, width: 300, height: 200)
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: RecordingTargetOpener()
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testVisualStudioCodeKeepsTargetsForOneSavedWindowInOneRequest() async throws {
        let bundleIdentifier = "com.microsoft.VSCode"
        let firstTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "FirstProject")
        )
        let secondTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "SecondProject")
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Projects",
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [firstTarget, secondTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURLs: [firstTarget.url, secondTarget.url],
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 1)
        XCTAssertEqual(
            targetOpener.requests.first?.targets.map(\.url),
            [firstTarget.url, secondTarget.url]
        )
        XCTAssertEqual(targetOpener.requests.first?.disposition, .newWindow)
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testAntigravityUsesNewWindowRequestStrategy() throws {
        let targets = [
            WindowOpenTarget(
                kind: .folder,
                url: try makeFolder(named: "AntigravityFirst")
            ),
            WindowOpenTarget(
                kind: .folder,
                url: try makeFolder(named: "AntigravitySecond")
            )
        ]

        let requests = RestoreTargetOpenRequestPlanner().requests(
            targets: targets,
            bundleIdentifier: "com.google.antigravity-ide"
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.targets.map(\.url), targets.map(\.url))
        XCTAssertEqual(requests.first?.disposition, .newWindow)
    }

    func testSafariAndChromeWebTargetsUseDistinctBrowserWindowStrategy() {
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            )
        ]

        for browser in BrowserAutomationBrowser.allCases {
            let requests = RestoreTargetOpenRequestPlanner().requests(
                targets: targets,
                bundleIdentifier: browser.bundleIdentifier
            )

            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.targets.map(\.url), targets.map(\.url))
            XCTAssertEqual(requests.first?.disposition, .newBrowserWindow)
        }
    }

    func testCodeBasedEditorNewWindowUsesBundledCommandWithOrderedPaths() async throws {
        let firstTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "ScrollSnap")
        )
        let secondTarget = WindowOpenTarget(
            kind: .folder,
            url: try makeFolder(named: "ZapPDF")
        )
        let editors = [
            (
                bundleIdentifier: "com.microsoft.VSCode",
                applicationName: "Visual Studio Code.app",
                commandName: "code"
            ),
            (
                bundleIdentifier: "com.google.antigravity-ide",
                applicationName: "Antigravity IDE.app",
                commandName: "antigravity-ide"
            )
        ]

        for editor in editors {
            let applicationURL = temporaryDirectoryURL
                .appendingPathComponent(editor.applicationName, isDirectory: true)
            let commandURL = applicationURL
                .appendingPathComponent("Contents/Resources/app/bin", isDirectory: true)
                .appendingPathComponent(editor.commandName)
            try FileManager.default.createDirectory(
                at: commandURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: commandURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: commandURL.path
            )
            let commandRunner = RecordingCommandRunner()
            let opener = NSWorkspaceRestoreTargetOpener(
                applicationURLProvider: { _ in applicationURL },
                commandRunner: commandRunner.run
            )

            let result = await opener.open(
                targets: [firstTarget, secondTarget],
                bundleIdentifier: editor.bundleIdentifier,
                disposition: .newWindow
            )

            guard case .opened = result else {
                XCTFail("Expected \(editor.applicationName) opening command to succeed.")
                continue
            }
            XCTAssertEqual(commandRunner.executableURLs, [commandURL])
            XCTAssertEqual(commandRunner.arguments, [[
                "--new-window",
                firstTarget.url.path,
                secondTarget.url.path
            ]])
        }
    }

    func testWorkspaceOpenerUsesSavedApplicationForOrderedWebBatch() async throws {
        let applicationURL = temporaryDirectoryURL
            .appendingPathComponent("Saved Browser.app", isDirectory: true)
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            )
        ]
        let workspaceOpener = RecordingWorkspaceOpener()
        let opener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in applicationURL },
            workspaceOpener: workspaceOpener.open
        )

        let result = await opener.open(
            targets: targets,
            bundleIdentifier: "com.example.saved-browser",
            disposition: .applicationDefault
        )

        guard case .opened = result else {
            return XCTFail("Expected the saved application request to succeed.")
        }
        XCTAssertEqual(
            workspaceOpener.requests.first?.urls,
            targets.map(\.url)
        )
        XCTAssertEqual(
            workspaceOpener.requests.first?.applicationURL,
            applicationURL
        )

        let unavailableOpener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in nil },
            workspaceOpener: workspaceOpener.open
        )
        let unavailableResult = await unavailableOpener.open(
            targets: targets,
            bundleIdentifier: "com.example.missing-browser",
            disposition: .applicationDefault
        )
        guard case .failed(.applicationUnavailable) = unavailableResult else {
            return XCTFail("Expected unavailable saved application failure.")
        }
        XCTAssertEqual(workspaceOpener.requests.count, 1)
    }

    func testWorkspaceOpenerReversesChromeWebBatchForRenderedTabOrder() async throws {
        let applicationURL = temporaryDirectoryURL
            .appendingPathComponent("Google Chrome.app", isDirectory: true)
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/third")!
            )
        ]
        let workspaceOpener = RecordingWorkspaceOpener()
        let opener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in applicationURL },
            workspaceOpener: workspaceOpener.open
        )

        let result = await opener.open(
            targets: targets,
            bundleIdentifier: BrowserAutomationBrowser.chrome.bundleIdentifier,
            disposition: .applicationDefault
        )

        guard case .opened = result else {
            return XCTFail("Expected the Chrome request to succeed.")
        }
        XCTAssertEqual(
            workspaceOpener.requests.first?.urls,
            targets.reversed().map(\.url)
        )
    }

    func testConnectedBrowserUsesAutomationWindowOpenerBeforeWorkspace() async {
        let applicationURL = temporaryDirectoryURL
            .appendingPathComponent("Safari.app", isDirectory: true)
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            )
        ]
        let browserWindowOpener = RecordingBrowserWindowOpener(
            results: [.opened(makeCapturedBrowserWindow(browser: .safari))]
        )
        let workspaceOpener = RecordingWorkspaceOpener()
        let opener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in applicationURL },
            browserWindowOpener: browserWindowOpener,
            workspaceOpener: workspaceOpener.open
        )

        let result = await opener.open(
            targets: targets,
            bundleIdentifier: BrowserAutomationBrowser.safari.bundleIdentifier,
            disposition: .newBrowserWindow
        )

        guard case .openedNewBrowserWindow = result else {
            return XCTFail("Expected Safari Automation window restore to succeed.")
        }
        XCTAssertEqual(browserWindowOpener.requests.count, 1)
        XCTAssertEqual(
            browserWindowOpener.requests.first?.targets.map(\.url),
            targets.map(\.url)
        )
        XCTAssertEqual(browserWindowOpener.requests.first?.browser, .safari)
        XCTAssertTrue(workspaceOpener.requests.isEmpty)
    }

    func testUnavailableBrowserAutomationFallsBackToSavedApplication() async {
        let applicationURL = temporaryDirectoryURL
            .appendingPathComponent("Google Chrome.app", isDirectory: true)
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            )
        ]
        let browserWindowOpener = RecordingBrowserWindowOpener(results: [.unavailable])
        let workspaceOpener = RecordingWorkspaceOpener()
        let opener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in applicationURL },
            browserWindowOpener: browserWindowOpener,
            workspaceOpener: workspaceOpener.open
        )

        let result = await opener.open(
            targets: targets,
            bundleIdentifier: BrowserAutomationBrowser.chrome.bundleIdentifier,
            disposition: .newBrowserWindow
        )

        guard case .opened = result else {
            return XCTFail("Expected Chrome generic fallback to succeed.")
        }
        XCTAssertEqual(browserWindowOpener.requests.count, 1)
        XCTAssertEqual(
            workspaceOpener.requests.first?.urls,
            targets.reversed().map(\.url)
        )
        XCTAssertEqual(
            workspaceOpener.requests.first?.applicationURL,
            applicationURL
        )
    }

    func testAlreadyOpenLocalTargetIsNotRequestedAgain() async throws {
        let bundleIdentifier = "com.example.terminal"
        let targetURL = try makeFolder(named: "Workspace")
        let target = WindowOpenTarget(kind: .folder, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Workspace",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let discovery = DiscoverySequence([
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            documentURL: targetURL,
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(discovery.callCount, 1)
    }

    func testDuplicateLocalTargetAcrossSavedWindowsRequestsEveryMissingOccurrence() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Shared.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let firstWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "First",
            frame: CGRect(x: 10, y: 20, width: 500, height: 400),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let secondWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Second",
            frame: CGRect(x: 600, y: 20, width: 500, height: 400),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: firstWindow.windowTitle,
                    frame: firstWindow.frame.cgRect
                ),
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: secondWindow.windowTitle,
                    frame: secondWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[], [readyApplication]])

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 2)
        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            [[targetURL], [targetURL]]
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testOneOpenDuplicateLocalTargetRequestsOneMissingOccurrence() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Shared.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let firstWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "First",
            frame: CGRect(x: 10, y: 20, width: 500, height: 400),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let secondWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Second",
            frame: CGRect(x: 600, y: 20, width: 500, height: 400),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let firstApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: firstWindow.windowTitle,
                    frame: firstWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: firstWindow.windowTitle,
                    frame: firstWindow.frame.cgRect
                ),
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: secondWindow.windowTitle,
                    frame: secondWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[firstApplication], [readyApplication]])

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 1)
        XCTAssertEqual(targetOpener.requests.first?.targets.map(\.url), [targetURL])
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testURLAndTitleEvidenceRemainScopedToTheirDiscoveredWindows() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Shared.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let savedWindows = [
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                windowTitle: "First",
                frame: CGRect(x: 10, y: 20, width: 500, height: 400),
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
            ),
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                windowTitle: "Second",
                frame: CGRect(x: 600, y: 20, width: 500, height: 400),
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
            ),
            makeWindowRecord(
                bundleIdentifier: bundleIdentifier,
                windowTitle: "Third",
                frame: CGRect(x: 1_190, y: 20, width: 500, height: 400),
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
            )
        ]
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: savedWindows)
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let firstTwoWindows = [
            makeDiscoveredWindow(
                documentURL: targetURL,
                title: savedWindows[0].windowTitle,
                frame: savedWindows[0].frame.cgRect,
                cgWindowID: 9001
            ),
            makeDiscoveredWindow(
                documentTitles: ["shell: \(targetURL.path)"],
                title: savedWindows[1].windowTitle,
                frame: savedWindows[1].frame.cgRect,
                cgWindowID: 9002
            )
        ]
        let staleApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: firstTwoWindows
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: firstTwoWindows + [
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: savedWindows[2].windowTitle,
                    frame: savedWindows[2].frame.cgRect,
                    cgWindowID: 9003
                )
            ]
        )
        let discovery = DiscoverySequence([
            [staleApplication],
            [staleApplication],
            [readyApplication]
        ])
        let clock = TestClock()

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            targetOpener: targetOpener,
            launchTimeout: 1,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 1)
        XCTAssertEqual(targetOpener.requests.first?.targets.map(\.url), [targetURL])
        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 3)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testSameBasenameDoesNotCountAsAnOpenLocalTarget() async throws {
        let bundleIdentifier = "com.example.editor"
        let firstParentURL = try makeFolder(named: "First")
        let secondParentURL = try makeFolder(named: "Second")
        let openURL = firstParentURL.appendingPathComponent("src", isDirectory: true)
        let targetURL = secondParentURL.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: openURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let target = WindowOpenTarget(kind: .folder, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: openURL,
                    documentTitles: ["src"],
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application], [application]]),
            targetOpener: targetOpener,
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 1)
        XCTAssertEqual(targetOpener.requests.first?.targets.map(\.url), [targetURL])
        XCTAssertEqual(result.requestedTargetCount, 1)
    }

    func testInactiveTabTargetsAreNotRequestedAgain() async throws {
        let bundleIdentifier = "com.example.terminal"
        let firstURL = try makeFolder(named: "LayoutLockFiles")
        let secondURL = try makeFolder(named: "ZapPDF")
        let targets = [
            WindowOpenTarget(kind: .folder, url: firstURL),
            WindowOpenTarget(kind: .folder, url: secondURL)
        ]
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Terminal",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: targets)
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let discovery = DiscoverySequence([
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            documentURL: secondURL,
                            documentTitles: [
                                "shell: \(firstURL.path)",
                                "shell: \(secondURL.path)"
                            ],
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(discovery.callCount, 1)
    }

    func testTargetPollingWaitsForRequestedDocumentBeforeRestoring() async throws {
        let bundleIdentifier = "com.example.editor"
        let targetURL = try makeFile(named: "Project.txt")
        let target = WindowOpenTarget(kind: .file, url: targetURL)
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Project",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let staleApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: "Project",
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: "Welcome",
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200),
                    cgWindowID: 9001
                ),
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: "Project",
                    frame: savedWindow.frame.cgRect,
                    cgWindowID: 9002
                )
            ]
        )
        let discovery = DiscoverySequence([
            [staleApplication],
            [staleApplication],
            [readyApplication]
        ])
        let clock = TestClock()

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener,
            launchTimeout: 1,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.requestedTargetCount, 1)
    }

    func testBrowserWithoutAutomationRequestsOnlyMissingAXTargetOccurrences() async throws {
        let bundleIdentifier = "com.example.browser"
        let firstTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/first")!
        )
        let secondTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/second")!
        )
        let targets = [firstTarget, secondTarget, firstTarget]
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: targets)
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let discovery = DiscoverySequence([
            [
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    windows: [
                        makeDiscoveredWindow(
                            documentURL: firstTarget.url,
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect
                        )
                    ]
                )
            ]
        ])
        let engine = makeEngine(
            store: store,
            launcher: launcher,
            discovery: discovery,
            targetOpener: targetOpener,
            launchTimeout: 0
        )

        let firstResult = try await engine.restoreSnapshot(id: snapshot.id)
        let secondResult = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.count, 2)
        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            [
                [secondTarget.url, firstTarget.url],
                [secondTarget.url, firstTarget.url]
            ]
        )
        XCTAssertEqual(
            targetOpener.requests.map(\.disposition),
            [.applicationDefault, .applicationDefault]
        )
        XCTAssertEqual(firstResult.requestedTargetCount, 2)
        XCTAssertEqual(secondResult.requestedTargetCount, 2)
        XCTAssertEqual(firstResult.restoredWindows, 1)
        XCTAssertEqual(secondResult.restoredWindows, 1)
        XCTAssertTrue(firstResult.skippedItems.isEmpty)
        XCTAssertTrue(secondResult.skippedItems.isEmpty)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
    }

    func testColdNonBrowserWebHandlerUsesStrictSingletonFallback() async throws {
        let bundleIdentifier = "com.example.slack"
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://app.example.com/client/workspace/channel")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved conversation",
            frame: CGRect(x: -1_900, y: 20, width: 1_000, height: 700),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [:])
        let targetOpener = RecordingTargetOpener()
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            pid: 900,
            windows: [
                makeDiscoveredWindow(
                    title: "Loading",
                    frame: CGRect(x: 1_500, y: 900, width: 400, height: 300)
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.map(\.disposition), [.applicationDefault])
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(result.windowDiagnostics.first?.matchStrategy, .singleton)
    }

    func testConnectedBrowserSkipsWebTargetThatIsAlreadyOpenOnRepeatedRestores() async throws {
        for browser in BrowserAutomationBrowser.allCases {
            let target = WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/open")!
            )
            let savedWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
            )
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [savedWindow])
            try store.save(snapshot)
            let targetOpener = RecordingTargetOpener()
            let application = makeApplication(
                bundleIdentifier: browser.bundleIdentifier,
                windows: [
                    makeDiscoveredWindow(
                        documentURL: target.url,
                        title: savedWindow.windowTitle,
                        frame: savedWindow.frame.cgRect
                    )
                ]
            )

            let engine = makeEngine(
                store: store,
                launcher: RecordingApplicationLauncher(results: [:]),
                discovery: DiscoverySequence([[application]]),
                targetOpener: targetOpener,
                browserTabCapturer: StubRestoreBrowserTabCapturer(
                    result: BrowserTabCaptureResult(
                        windows: [
                            CapturedBrowserWindow(
                                browser: browser,
                                scriptingIdentifier: "1",
                                title: savedWindow.windowTitle,
                                frame: savedWindow.frame.cgRect,
                                frontToBackIndex: 0,
                                tabs: [CapturedBrowserTab(title: "Open", URL: target.url)]
                            )
                        ],
                        issues: []
                    )
                )
            )

            for _ in 0..<2 {
                let result = try await engine.restoreSnapshot(id: snapshot.id)

                XCTAssertTrue(targetOpener.requests.isEmpty)
                XCTAssertEqual(result.requestedTargetCount, 0)
                XCTAssertEqual(result.restoredWindows, 1)
                XCTAssertTrue(result.targetIssues.isEmpty)
            }
        }
    }

    func testChromeStartupInventoryIsSharedAcrossSavedWindowsAndPreservesOccurrences() async throws {
        let browser = BrowserAutomationBrowser.chrome
        let inboxURL = URL(string: "https://mail.google.com/mail/u/0/#inbox")!
        let otherURL = URL(string: "https://example.com/other")!
        for secondURL in [otherURL, inboxURL] {
            let firstFrame = CGRect(x: 10, y: 20, width: 600, height: 500)
            let secondFrame = CGRect(x: 800, y: 20, width: 600, height: 500)
            let firstWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                windowTitle: "Inbox",
                frame: firstFrame,
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [
                    WindowOpenTarget(kind: .webURL, url: inboxURL)
                ])
            )
            let secondWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                windowTitle: "Second",
                frame: secondFrame,
                openingConfiguration: WindowOpeningConfiguration(manualTargets: [
                    WindowOpenTarget(kind: .webURL, url: secondURL)
                ])
            )
            let startupWindows = [
                CapturedBrowserWindow(
                    browser: browser, scriptingIdentifier: "session-inbox", title: "Inbox",
                    frame: firstFrame, frontToBackIndex: 0,
                    tabs: [CapturedBrowserTab(title: "Inbox", URL: inboxURL)]
                ),
                CapturedBrowserWindow(
                    browser: browser, scriptingIdentifier: "session-other", title: "Other",
                    frame: secondFrame, frontToBackIndex: 1,
                    tabs: [CapturedBrowserTab(title: "Other", URL: otherURL)]
                )
            ]
            let targetOpener = RecordingTargetOpener(results: [
                .openedNewBrowserWindow(
                    startupWindows[0], startupWindows: startupWindows, openedTargetCount: 0
                ),
                .openedNewBrowserWindow(CapturedBrowserWindow(
                    browser: browser, scriptingIdentifier: "new-inbox", title: "Second",
                    frame: secondFrame, frontToBackIndex: 0,
                    tabs: [CapturedBrowserTab(title: "Inbox", URL: inboxURL)]
                ))
            ])
            let application = makeApplication(
                bundleIdentifier: browser.bundleIdentifier,
                windows: [
                    makeDiscoveredWindow(documentURL: inboxURL, title: "Inbox", frame: firstFrame),
                    makeDiscoveredWindow(documentURL: secondURL, title: "Second", frame: secondFrame)
                ]
            )
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
            try store.save(snapshot)

            let result = try await makeEngine(
                store: store,
                launcher: RecordingApplicationLauncher(results: [:]),
                discovery: DiscoverySequence([[], [application]]),
                targetOpener: targetOpener
            ).restoreSnapshot(id: snapshot.id)

            let expectsSecondInbox = secondURL == inboxURL
            XCTAssertEqual(targetOpener.requests.count, expectsSecondInbox ? 2 : 1)
            XCTAssertEqual(result.requestedTargetCount, expectsSecondInbox ? 1 : 0)
            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertTrue(result.targetIssues.isEmpty)
            XCTAssertTrue(result.skippedItems.isEmpty)
        }
    }

    func testAXDiscoveredWebTargetIsNotRequestedWhenAutomationIsUnavailable() async throws {
        let bundleIdentifier = "org.mozilla.firefox"
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/open")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: target.url,
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application]]),
            targetOpener: targetOpener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty)
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testAutomationWebTargetsTakePrecedenceOverAXDiscoveredURLs() async throws {
        let browser = BrowserAutomationBrowser.safari
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/ax-only")!
        )
        let automationTarget = URL(string: "https://example.com/automation")!
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let openedFrame = CGRect(x: 700, y: 100, width: 600, height: 500)
        let targetOpener = RecordingTargetOpener(
            results: [
                .openedNewBrowserWindow(
                    makeCapturedBrowserWindow(browser: browser, frame: openedFrame)
                )
            ]
        )
        let application = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: target.url,
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            windows: application.windows + [
                makeDiscoveredWindow(
                    documentURL: target.url,
                    title: "Opened Window",
                    frame: openedFrame
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application], [readyApplication]]),
            targetOpener: targetOpener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(
                result: BrowserTabCaptureResult(
                    windows: [
                        CapturedBrowserWindow(
                            browser: browser,
                            scriptingIdentifier: "1",
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect,
                            frontToBackIndex: 0,
                            tabs: [
                                CapturedBrowserTab(
                                    title: "Automation",
                                    URL: automationTarget
                                )
                            ]
                        )
                    ],
                    issues: []
                )
            )
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.first?.targets.map(\.url),
            [target.url]
        )
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testConnectedBrowserSubtractsOpenTabsByOccurrenceAndPreservesOrder() async throws {
        let browser = BrowserAutomationBrowser.chrome
        let repeatedTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/repeated")!
        )
        let otherTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/other")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [repeatedTarget, repeatedTarget, otherTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let application = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: repeatedTarget.url,
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            windows: application.windows + [
                makeDiscoveredWindow(
                    documentURLs: [repeatedTarget.url, otherTarget.url],
                    title: "Opened Window",
                    frame: CGRect(x: 700, y: 100, width: 600, height: 500)
                )
            ]
        )
        let targetOpener = RecordingTargetOpener(
            results: [
                .openedNewBrowserWindow(
                    makeCapturedBrowserWindow(
                        browser: browser,
                        frame: CGRect(x: 700, y: 100, width: 600, height: 500)
                    )
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application], [readyApplication]]),
            targetOpener: targetOpener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(
                result: BrowserTabCaptureResult(
                    windows: [
                        CapturedBrowserWindow(
                            browser: browser,
                            scriptingIdentifier: "1",
                            title: savedWindow.windowTitle,
                            frame: savedWindow.frame.cgRect,
                            frontToBackIndex: 0,
                            tabs: [
                                CapturedBrowserTab(
                                    title: "Repeated",
                                    URL: repeatedTarget.url
                                )
                            ]
                        )
                    ],
                    issues: []
                )
            )
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.first?.targets.map(\.url),
            [repeatedTarget.url, otherTarget.url]
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testClosedBrowserWebBatchMatchesChangedWindowByURL() async throws {
        let bundleIdentifier = "com.example.browser"
        let targets = [
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/first")!
            ),
            WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://example.com/second")!
            )
        ]
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Browser Tab",
            frame: CGRect(x: 10, y: 20, width: 500, height: 400),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: targets)
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundleIdentifier: true])
        let targetOpener = RecordingTargetOpener()
        let readyApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURL: targets[1].url,
                    title: "Changed Browser Tab",
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.first?.targets.map(\.url),
            targets.map(\.url)
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
    }

    func testColdChromeUsesOpenedWindowEvidenceAcrossPidTitleURLAndMonitor() async throws {
        let browser = BrowserAutomationBrowser.chrome
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://saved.example")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: -1_900, y: 40, width: 1_200, height: 900),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let openedFrame = CGRect(x: 1_400, y: 800, width: 500, height: 350)
        let evidence = makeCapturedBrowserWindow(
            scriptingIdentifier: "chrome-window-42",
            frame: openedFrame
        )
        let discoveredWindow = makeDiscoveredWindow(
            documentURL: URL(string: "https://redirected.example")!,
            title: "Redirected Tab",
            frame: openedFrame
        )
        let readyApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            pid: 900,
            windows: [discoveredWindow]
        )
        let discovery = DiscoverySequence([[], [readyApplication]])
        let windowApplier = RecordingEngineWindowApplier()

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            windowApplier: windowApplier,
            targetOpener: RecordingTargetOpener(
                results: [.openedNewBrowserWindow(evidence)]
            )
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(discovery.callCount, 2)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(windowApplier.appliedWindowTitles, ["Redirected Tab"])
    }

    func testColdGenericBrowserFallbackRestoresOnlySingletonRoleMatch() async throws {
        let browser = BrowserAutomationBrowser.chrome
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://saved.example")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            pidAtCapture: 100,
            windowTitle: "Saved Tab",
            frame: CGRect(x: -1_900, y: 40, width: 1_200, height: 900),
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let readyApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            pid: 900,
            windows: [
                makeDiscoveredWindow(
                    title: "New Tab",
                    frame: CGRect(x: 1_400, y: 800, width: 500, height: 350)
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [readyApplication]]),
            targetOpener: RecordingTargetOpener(results: [.opened])
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testAmbiguousOpenedBrowserEvidenceSkipsGeometryAndZOrder() async throws {
        let browser = BrowserAutomationBrowser.chrome
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://saved.example")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            windowTitle: "Saved Tab",
            zOrderHint: 1,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let openedFrame = CGRect(x: 1_400, y: 800, width: 500, height: 350)
        let evidence = makeCapturedBrowserWindow(
            scriptingIdentifier: "chrome-window-42",
            frame: openedFrame
        )
        let ambiguousApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            windows: [
                makeDiscoveredWindow(title: "Opened Window", frame: openedFrame),
                makeDiscoveredWindow(title: "Opened Window", frame: openedFrame)
            ]
        )
        let windowApplier = RecordingEngineWindowApplier()

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [ambiguousApplication]]),
            windowApplier: windowApplier,
            targetOpener: RecordingTargetOpener(
                results: [.openedNewBrowserWindow(evidence)]
            ),
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(
            result.skippedItems.first?.reason,
            RestoreSkipReason.openedBrowserWindowNotIdentified
        )
        XCTAssertTrue(windowApplier.appliedWindowTitles.isEmpty)
        XCTAssertEqual(windowApplier.raiseCount, 0)
        XCTAssertEqual(windowApplier.focusCount, 0)
        XCTAssertEqual(result.windowDiagnostics.first?.candidateCount, 2)
        XCTAssertEqual(result.windowDiagnostics.first?.readinessTimedOut, true)
        XCTAssertEqual(result.windowDiagnostics.first?.geometryAttempted, false)
    }

    func testBrowserWindowPollingWaitsForEvidencedWindowInsteadOfMatchingStalePID() async throws {
        let browser = BrowserAutomationBrowser.safari
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/new-window")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            pidAtCapture: 200,
            windowTitle: "Saved Browser Window",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let staleWindow = makeDiscoveredWindow(
            title: savedWindow.windowTitle,
            frame: savedWindow.frame.cgRect
        )
        let staleApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            pid: 200,
            windows: [staleWindow]
        )
        let readyApplication = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            pid: 200,
            windows: [
                staleWindow,
                makeDiscoveredWindow(
                    documentURL: target.url,
                    title: "Opened Browser Window",
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                )
            ]
        )
        let discovery = DiscoverySequence([
            [staleApplication],
            [staleApplication],
            [readyApplication]
        ])
        let clock = TestClock()
        let windowApplier = RecordingEngineWindowApplier()

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            windowApplier: windowApplier,
            targetOpener: RecordingTargetOpener(
                results: [
                    .openedNewBrowserWindow(
                        makeCapturedBrowserWindow(
                            browser: browser,
                            frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                        )
                    )
                ]
            ),
            launchTimeout: 1,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(
            windowApplier.appliedWindowTitles.compactMap { $0 },
            ["Opened Browser Window"]
        )
    }

    func testGenericRunningBrowserFallbackDoesNotMoveExistingWindow() async throws {
        let browser = BrowserAutomationBrowser.safari
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/fallback-tab")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: browser.bundleIdentifier,
            pidAtCapture: 200,
            windowTitle: "Existing Browser Window",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let application = makeApplication(
            bundleIdentifier: browser.bundleIdentifier,
            pid: 200,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )
        let discovery = DiscoverySequence([[application], [application]])
        let targetOpener = RecordingTargetOpener(results: [.opened])
        let clock = TestClock()

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: discovery,
            targetOpener: targetOpener,
            launchTimeout: 0,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.first?.disposition, .newBrowserWindow)
        XCTAssertEqual(discovery.callCount, 2)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(
            result.skippedItems.first?.reason,
            RestoreSkipReason.openedBrowserWindowNotIdentified
        )
    }

    func testSeparateNonAutomatedWebBatchesRestoreMatchableWindowAndSkipShortage() async throws {
        let bundleIdentifier = "com.example.browser"
        let firstTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://first.example.com/")!
        )
        let secondTarget = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://second.example.com/")!
        )
        let firstWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "First",
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [firstTarget]
            )
        )
        let secondWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            windowTitle: "Second",
            openingConfiguration: WindowOpeningConfiguration(
                manualTargets: [secondTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let mergedApplication = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    documentURLs: [firstTarget.url, secondTarget.url],
                    title: "Merged",
                    frame: firstWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[], [mergedApplication]]),
            targetOpener: targetOpener,
            launchTimeout: 0
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(
            targetOpener.requests.map { $0.targets.map(\.url) },
            [[firstTarget.url], [secondTarget.url]]
        )
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.windowNotFound)
    }

    func testConnectedBrowsersRequestOneDistinctWindowPerSavedWindow() async throws {
        for browser in BrowserAutomationBrowser.allCases {
            let firstTarget = WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://first.example.com/\(browser.rawValue)")!
            )
            let secondTarget = WindowOpenTarget(
                kind: .webURL,
                url: URL(string: "https://second.example.com/\(browser.rawValue)")!
            )
            let firstWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                pidAtCapture: 42,
                windowTitle: "First",
                openingConfiguration: WindowOpeningConfiguration(
                    manualTargets: [firstTarget]
                )
            )
            let secondWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                pidAtCapture: 43,
                windowTitle: "Second",
                openingConfiguration: WindowOpeningConfiguration(
                    manualTargets: [secondTarget]
                )
            )
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
            try store.save(snapshot)
            let firstOpenedFrame = CGRect(x: 100, y: 100, width: 600, height: 500)
            let secondOpenedFrame = CGRect(x: 800, y: 100, width: 600, height: 500)
            let targetOpener = RecordingTargetOpener(
                results: [
                    .openedNewBrowserWindow(
                        makeCapturedBrowserWindow(
                            browser: browser,
                            scriptingIdentifier: "first-opened-window",
                            frame: firstOpenedFrame
                        )
                    ),
                    .openedNewBrowserWindow(
                        makeCapturedBrowserWindow(
                            browser: browser,
                            scriptingIdentifier: "second-opened-window",
                            frame: secondOpenedFrame
                        )
                    )
                ]
            )
            let readyApplication = makeApplication(
                bundleIdentifier: browser.bundleIdentifier,
                windows: [
                    makeDiscoveredWindow(
                        documentURL: firstTarget.url,
                        title: firstWindow.windowTitle,
                        frame: firstOpenedFrame
                    ),
                    makeDiscoveredWindow(
                        documentURL: secondTarget.url,
                        title: secondWindow.windowTitle,
                        frame: secondOpenedFrame
                    )
                ]
            )

            let result = try await makeEngine(
                store: store,
                launcher: RecordingApplicationLauncher(results: [:]),
                discovery: DiscoverySequence([[], [readyApplication]]),
                targetOpener: targetOpener
            ).restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(
                targetOpener.requests.map { $0.targets.map(\.url) },
                [[firstTarget.url], [secondTarget.url]]
            )
            XCTAssertEqual(
                targetOpener.requests.map(\.disposition),
                [.newBrowserWindow, .newBrowserWindow]
            )
            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertTrue(result.skippedItems.isEmpty)
        }
    }

    func testUnsupportedWebURLIsReportedWithoutOpeningTarget() async throws {
        let bundleIdentifier = "com.example.browser"
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "ftp://example.com/private")!
        )
        let savedWindow = makeWindowRecord(
            bundleIdentifier: bundleIdentifier,
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [savedWindow])
        try store.save(snapshot)
        let targetOpener = RecordingTargetOpener()
        let application = makeApplication(
            bundleIdentifier: bundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
                )
            ]
        )

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application]]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.targetIssues.first?.target, target)
        XCTAssertEqual(result.targetIssues.first?.reason, .unsupportedURL)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testFailedWebBatchFallsBackToSavedAppLaunchAndRestoresOtherWindows() async throws {
        let browserBundleIdentifier = "com.example.browser"
        let otherBundleIdentifier = "com.example.notes"
        let target = WindowOpenTarget(
            kind: .webURL,
            url: URL(string: "https://example.com/")!
        )
        let browserWindow = makeWindowRecord(
            bundleIdentifier: browserBundleIdentifier,
            windowTitle: "Browser",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target])
        )
        let otherWindow = makeWindowRecord(
            bundleIdentifier: otherBundleIdentifier,
            windowTitle: "Notes"
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshot = makeSnapshot(windows: [browserWindow, otherWindow])
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(
            results: [browserBundleIdentifier: true]
        )
        let targetOpener = RecordingTargetOpener(
            results: [.failed(.openRequestFailed)]
        )
        let otherApplication = makeApplication(
            bundleIdentifier: otherBundleIdentifier,
            windows: [
                makeDiscoveredWindow(
                    title: otherWindow.windowTitle,
                    frame: otherWindow.frame.cgRect
                )
            ]
        )
        let readyApplications = [
            makeApplication(
                bundleIdentifier: browserBundleIdentifier,
                windows: [
                    makeDiscoveredWindow(
                        title: browserWindow.windowTitle,
                        frame: browserWindow.frame.cgRect
                    )
                ]
            ),
            otherApplication
        ]

        let result = try await makeEngine(
            store: store,
            launcher: launcher,
            discovery: DiscoverySequence([[otherApplication], readyApplications]),
            targetOpener: targetOpener
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.targetIssues.first?.reason, .openRequestFailed)
        XCTAssertEqual(
            launcher.requestedBundleIdentifiers,
            [browserBundleIdentifier]
        )
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testAcceptedLocalOpenWithoutObservedDocumentReportsIssueAndSkipsGeometry() async throws {
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Workspace.txt"))
        let saved = makeWindowRecord(bundleIdentifier: "com.example.editor", windowTitle: "Home",
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let home = makeApplication(bundleIdentifier: saved.bundleIdentifier, pid: saved.pidAtCapture,
                                   windows: [makeDiscoveredWindow(title: "Home", frame: saved.frame.cgRect)])
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: DiscoverySequence([[home]]), windowApplier: applier,
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openingNotConfirmed])
        XCTAssertEqual(result.targetIssues.map(\.target.url), [target.url])
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertTrue(applier.appliedWindowTitles.isEmpty)
        XCTAssertEqual(applier.raiseCount, 0)
        XCTAssertEqual(applier.focusCount, 0)
    }

    func testPartiallyObservedAcceptedBatchReportsOnlyMissingTargetAndRestoresConfirmedWindow() async throws {
        let targets = try ["Observed.txt", "Unobserved.txt"].map {
            WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
        }
        let saved = makeWindowRecord(bundleIdentifier: "com.microsoft.VSCode",
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: targets))
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let partial = makeApplication(bundleIdentifier: saved.bundleIdentifier, windows: [
            makeDiscoveredWindow(documentURL: targets[0].url, title: "Confirmed document", frame: saved.frame.cgRect)
        ])
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: DiscoverySequence([[], [partial]]), windowApplier: applier,
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [targets.map(\.url)])
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.targetIssues.map(\.target.url), [targets[1].url])
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openingNotConfirmed])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedWindowTitles, ["Confirmed document"])
    }

    func testUnityDifferentSceneInSavedProjectReportsMissingSceneAndSkipsGeometry() async throws {
        let project = try makeFolder(named: "Unity Project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("ProjectSettings"),
                                                withIntermediateDirectories: true)
        try "m_EditorVersion: 6000.6.7f1\n".write(
            to: project.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true, encoding: .utf8)
        let savedScene = project.appendingPathComponent("Assets/SceneA.unity")
        let otherScene = project.appendingPathComponent("Assets/SceneB.unity")
        try Data().write(to: savedScene)
        try Data().write(to: otherScene)
        let saved = makeWindowRecord(
            bundleIdentifier: "com.unity3d.UnityEditor5.x", windowTitle: "Scene A",
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [
                WindowOpenTarget(kind: .file, url: savedScene),
                WindowOpenTarget(kind: .folder, url: project)
            ])
        )
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let application = makeApplication(bundleIdentifier: saved.bundleIdentifier, pid: saved.pidAtCapture,
            windows: [makeDiscoveredWindow(documentURLs: [otherScene, project],
                                          title: "Scene B", frame: saved.frame.cgRect)])
        let opener = RecordingTargetOpener(results: [.failed(.openingNotConfirmed)])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application]]), windowApplier: applier,
            targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [[savedScene]])
        XCTAssertTrue(result.targetIssues.contains { $0.target.url == savedScene && $0.reason == .openingNotConfirmed })
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.windowNotFound])
        XCTAssertTrue(applier.appliedWindowTitles.isEmpty)
        XCTAssertEqual(applier.raiseCount, 0)
        XCTAssertEqual(applier.focusCount, 0)
    }

    func testSeparateInstancesLaunchOneBatchPerCaptureGroupAndReuseCompleteGroups() async throws {
        let bundle = "com.example.editor"
        let targets = try ["First.txt", "Second.txt", "Third.txt"].map {
            WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
        }
        let windows = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: index < 2 ? 42 : 43,
                             windowTitle: "Saved \(index)",
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [
            makeApplication(bundleIdentifier: bundle, pid: 900, windows: targets.prefix(2).enumerated().map { index, target in
                makeDiscoveredWindow(documentURL: target.url, title: "Live \(index)", frame: windows[index].frame.cgRect)
            }),
            makeApplication(bundleIdentifier: bundle, pid: 901, windows: [
                makeDiscoveredWindow(documentURL: targets[2].url, title: "Live 2", frame: windows[2].frame.cgRect)
            ])
        ]
        let opener = RecordingTargetOpener(results: [.openedApplicationInstance(900), .openedApplicationInstance(901)])
        let launcher = RecordingApplicationLauncher(results: [:])
        let applier = RecordingEngineWindowApplier()
        let engine = makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([[], live]),
                                windowApplier: applier, targetOpener: opener, launchTimeout: 0)

        let first = try await engine.restoreSnapshot(id: snapshot.id)
        let repeated = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [Array(targets.prefix(2)).map(\.url), [targets[2].url]])
        XCTAssertEqual(opener.requests.map(\.disposition), [.newApplicationInstance, .newApplicationInstance])
        XCTAssertEqual(first.requestedTargetCount, 3)
        XCTAssertEqual(first.restoredWindows, 3)
        XCTAssertTrue(first.targetIssues.isEmpty)
        XCTAssertEqual(repeated.requestedTargetCount, 0)
        XCTAssertEqual(repeated.restoredWindows, 3)
        XCTAssertTrue(repeated.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedWindowTitles, ["Live 0", "Live 1", "Live 2", "Live 0", "Live 1", "Live 2"])
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
    }

    func testWindowsCapturedInOneProcessKeepNormalWindowStrategy() async throws {
        let bundle = "com.microsoft.VSCode"
        let targets = try ["First", "Second"].map { WindowOpenTarget(kind: .folder, url: try makeFolder(named: $0)) }
        let windows = targets.map { target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42,
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = makeApplication(bundleIdentifier: bundle, windows: targets.map {
            makeDiscoveredWindow(documentURL: $0.url, title: $0.url.lastPathComponent, frame: windows[0].frame.cgRect)
        })
        let opener = RecordingTargetOpener()
        let launcher = RecordingApplicationLauncher(results: [:])

        let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([[], [live]]),
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map(\.disposition), [.newWindow, .newWindow])
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
    }

    func testSeparateInstanceReturnedPIDDisappearsWithoutMovingSiblingContent() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Shared.txt"))
        let windows = [42, 43].map { pid in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(pid),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let sibling = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(documentURL: target.url, title: "Correct instance", frame: windows[0].frame.cgRect),
            makeDiscoveredWindow(documentURL: target.url, title: "Consolidated sibling", frame: windows[1].frame.cgRect)
        ])
        let opener = RecordingTargetOpener(results: [.openedApplicationInstance(900), .openedApplicationInstance(901)])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: DiscoverySequence([[], [sibling]]), windowApplier: applier,
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openingNotConfirmed])
        XCTAssertEqual(applier.appliedWindowTitles, ["Correct instance"])
        XCTAssertEqual(opener.requests.count, 2)
    }

    func testFailedSeparateInstanceDoesNotFallBackToNormalLaunch() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Project.txt"))
        let windows = [42, 43].map { pid in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(pid),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let opener = RecordingTargetOpener(results: [.failed(.openRequestFailed), .failed(.openRequestFailed)])
        let launcher = RecordingApplicationLauncher(results: [bundle: true])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([[]]),
                                          windowApplier: applier, targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        XCTAssertEqual(opener.requests.map(\.disposition), [.newApplicationInstance, .newApplicationInstance])
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), Array(repeating: RestoreSkipReason.appInstanceUnconfirmed, count: 2))
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openRequestFailed, .openRequestFailed])
        XCTAssertTrue(applier.appliedWindowTitles.isEmpty)
    }

    func testSeparateInstancesWithoutTargetsUseLaunchInstancePID() async throws {
        let bundle = "com.example.editor"
        let windows = [42, 43].map { makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0)) }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [900, 901].map { pid in
            makeApplication(bundleIdentifier: bundle, pid: Int32(pid), windows: [
                makeDiscoveredWindow(title: "Window", frame: windows[0].frame.cgRect)
            ])
        }
        let launcher = RecordingApplicationLauncher(results: [:], instanceResults: [900, 901])
        let opener = RecordingTargetOpener()

        let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([[], live]),
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(launcher.requestedInstanceBundleIdentifiers, [bundle, bundle])
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(result.restoredWindows, 2)
    }

    func testFreshInstancesWaitForStandardWindowsInsteadOfApplyingGeometryToDialogs() async throws {
        let bundle = "com.example.editor"
        let windows = [42, 43].map { makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0)) }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let dialog = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(title: "Startup dialog", subrole: "AXDialog",
                frame: CGRect(x: 900, y: 700, width: 100, height: 100), cgWindowID: 900)
        ])
        let standard = [900, 901].map { pid in
            makeApplication(bundleIdentifier: bundle, pid: Int32(pid), windows: [
                makeDiscoveredWindow(title: "Window", frame: windows[0].frame.cgRect, cgWindowID: CGWindowID(pid + 10))
            ])
        }
        let discovery = DiscoverySequence([[], [dialog, standard[1]], standard])
        let clock = TestClock()
        let applier = RecordingEngineWindowApplier()
        let launcher = RecordingApplicationLauncher(results: [:], instanceResults: [900, 901])

        let result = try await makeEngine(store: store, launcher: launcher, discovery: discovery,
            windowApplier: applier, launchTimeout: 1, launchClock: clock.now, launchPollSleeper: clock.sleep)
            .restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [910, 911])
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testTitlelessCGSeparateInstancesRestoreAndReuseWithoutAdditionalLaunches() async throws {
        let bundle = "com.example.editor"
        let windows = [42, 43].map {
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0), windowTitle: nil,
                             subrole: nil, captureSource: .coreGraphics)
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [900, 901].map { pid in
            makeApplication(bundleIdentifier: bundle, pid: Int32(pid), windows: [
                makeDiscoveredWindow(title: nil, frame: windows[0].frame.cgRect, cgWindowID: CGWindowID(pid))
            ])
        }
        let launcher = RecordingApplicationLauncher(results: [:], instanceResults: [900, 901, 902, 903])
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let engine = makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([[], live, live]),
                                windowApplier: applier, targetOpener: opener, launchTimeout: 0)

        for _ in 0..<2 {
            let result = try await engine.restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertTrue(result.skippedItems.isEmpty)
            XCTAssertEqual(result.requestedTargetCount, 0)
            XCTAssertEqual(launcher.requestedInstanceBundleIdentifiers, [bundle, bundle])
        }
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [900, 900, 901, 901])
    }

    func testSeparateInstanceReusePreservesPreferredOwnersWithIdenticalTitles() async throws {
        let bundle = "com.example.editor"
        let first = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42, windowTitle: "Document",
            frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        let second = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43, windowTitle: "Document",
            frame: CGRect(x: 1_000, y: 700, width: 500, height: 400))
        for reverseGroups in [false, true] {
            for changedPIDs in [false, true] {
                let windows = reverseGroups ? [second, first] : [first, second]
                let snapshot = makeSnapshot(windows: windows)
                let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
                try store.save(snapshot)
                let live = [
                    makeApplication(bundleIdentifier: bundle, pid: changedPIDs ? 901 : 42, windows: [
                        makeDiscoveredWindow(title: "Document", frame: first.frame.cgRect, cgWindowID: 501)
                    ]),
                    makeApplication(bundleIdentifier: bundle, pid: changedPIDs ? 900 : 43, windows: [
                        makeDiscoveredWindow(title: "Document", frame: second.frame.cgRect, cgWindowID: 502)
                    ])
                ]
                let launcher = RecordingApplicationLauncher(results: [:])
                let opener = RecordingTargetOpener()
                let applier = RecordingEngineWindowApplier()
                let engine = makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([live]),
                    windowApplier: applier, targetOpener: opener, launchTimeout: 0)

                for _ in 0..<2 {
                    let result = try await engine.restoreSnapshot(id: snapshot.id)
                    XCTAssertEqual(result.restoredWindows, 2)
                    XCTAssertTrue(result.skippedItems.isEmpty)
                }

                XCTAssertEqual(applier.appliedSavedWindowIDs.count, 4)
                for (savedID, currentID) in zip(applier.appliedSavedWindowIDs, applier.appliedCGWindowIDs) {
                    XCTAssertEqual(currentID, savedID == first.id ? 501 : 502)
                }
                XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
                XCTAssertTrue(opener.requests.isEmpty)
            }
        }
    }

    func testSeparateInstanceReuseRequiresStandardRoleEvenWhenCapturePIDStillRuns() async throws {
        let bundle = "com.example.editor"
        let roles: [(String, String?)] = [("AXWindow", "AXDialog"), ("AXDialog", nil), ("AXWindow", nil)]
        for (role, subrole) in roles {
            let windows = [
                makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42, windowTitle: "Document"),
                makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43, windowTitle: "Sibling")
            ]
            let snapshot = makeSnapshot(windows: windows)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let dialog = makeApplication(bundleIdentifier: bundle, pid: 42, windows: [
                makeDiscoveredWindow(title: "Preferences", role: role, subrole: subrole,
                    frame: CGRect(x: 900, y: 700, width: 100, height: 100), cgWindowID: 4200)
            ])
            let sibling = makeApplication(bundleIdentifier: bundle, pid: 43, windows: [
                makeDiscoveredWindow(title: "Sibling", frame: windows[1].frame.cgRect, cgWindowID: 4300)
            ])
            let replacement = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
                makeDiscoveredWindow(title: "Document", frame: windows[0].frame.cgRect, cgWindowID: 9000)
            ])
            let launcher = RecordingApplicationLauncher(results: [:], instanceResults: [900])
            let applier = RecordingEngineWindowApplier()

            let result = try await makeEngine(store: store, launcher: launcher,
                discovery: DiscoverySequence([[dialog, sibling], [dialog, sibling, replacement]]),
                windowApplier: applier, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 2)
            XCTAssertTrue(result.skippedItems.isEmpty)
            XCTAssertEqual(launcher.requestedInstanceBundleIdentifiers, [bundle])
            XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
            XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [4300, 9000])
        }
    }

    func testSeparateInstanceReuseFindsStandardWindowAlongsideAMoreAttractiveDialog() async throws {
        let bundle = "com.example.editor"
        let windows = [
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42, windowTitle: "Document"),
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43, windowTitle: "Sibling")
        ]
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [
            makeApplication(bundleIdentifier: bundle, pid: 42, windows: [
                makeDiscoveredWindow(title: "Document", subrole: "AXDialog", frame: windows[0].frame.cgRect, cgWindowID: 4200),
                makeDiscoveredWindow(title: "Other title", frame: CGRect(x: 900, y: 700, width: 100, height: 100), cgWindowID: 4201)
            ]),
            makeApplication(bundleIdentifier: bundle, pid: 43, windows: [
                makeDiscoveredWindow(title: "Sibling", frame: windows[1].frame.cgRect, cgWindowID: 4300)
            ])
        ]
        let launcher = RecordingApplicationLauncher(results: [:])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([live]),
            windowApplier: applier, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }, [4201, 4300])
    }

    func testSeparateInstanceReuseDoesNotPromoteAnUnrelatedAXDialogThroughItsPID() async throws {
        let bundle = "com.example.editor"
        let windows = [42, 43].map { makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32($0)) }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let dialog = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(title: "Unrelated dialog", subrole: "AXDialog",
                frame: CGRect(x: 900, y: 700, width: 100, height: 100), cgWindowID: 900)
        ])
        let standard = [901, 902].map { pid in
            makeApplication(bundleIdentifier: bundle, pid: Int32(pid), windows: [
                makeDiscoveredWindow(title: "Window", frame: windows[0].frame.cgRect, cgWindowID: CGWindowID(pid))
            ])
        }
        let launcher = RecordingApplicationLauncher(results: [:], instanceResults: [902])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: launcher,
            discovery: DiscoverySequence([[dialog, standard[0]], [dialog] + standard]),
            windowApplier: applier, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertEqual(launcher.requestedInstanceBundleIdentifiers, [bundle])
        XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [901, 902])
    }

    func testSeparateInstanceIncompleteGroupReopensAllTargetsAndReusesCompleteSibling() async throws {
        let bundle = "com.example.editor"
        let targets = try ["First.txt", "Second.txt", "Third.txt"].map {
            WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
        }
        let windows = [
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42,
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: Array(targets.prefix(2)))),
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43,
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [targets[2]]))
        ]
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let incomplete = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(documentURL: targets[0].url, title: "Incomplete old instance", frame: windows[0].frame.cgRect)
        ])
        let completeSibling = makeApplication(bundleIdentifier: bundle, pid: 901, windows: [
            makeDiscoveredWindow(documentURL: targets[2].url, title: "Complete sibling", frame: windows[1].frame.cgRect)
        ])
        let replacement = makeApplication(bundleIdentifier: bundle, pid: 902, windows: [
            makeDiscoveredWindow(documentURLs: Array(targets.prefix(2)).map(\.url), title: "Complete replacement", frame: windows[0].frame.cgRect)
        ])
        let opener = RecordingTargetOpener(results: [.openedApplicationInstance(902)])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: DiscoverySequence([[incomplete, completeSibling], [incomplete, completeSibling, replacement]]),
                                          windowApplier: applier, targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [Array(targets.prefix(2)).map(\.url)])
        XCTAssertEqual(opener.requests.first?.disposition, .newApplicationInstance)
        XCTAssertEqual(result.requestedTargetCount, 2)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertEqual(applier.appliedWindowTitles, ["Complete replacement", "Complete sibling"])
    }

    func testUnexposedApplicationOwnerBlocksSpeculativeSeparateInstanceLaunch() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Project.txt"))
        let windows = [42, 43].map { pid in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(pid),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let launcher = RecordingApplicationLauncher(results: [bundle: true])
        let opener = RecordingTargetOpener()
        let discovery = WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [
            UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [
                CGWindowMetadata(windowID: 9001, processIdentifier: 900, ownerName: nil, layer: 0,
                                 bounds: CGRect(x: 10, y: 20, width: 600, height: 400), title: "Project",
                                 isOnScreen: false, zOrderHint: nil)
            ])
        ])
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                                   windowApplier: RecordingEngineWindowApplier(),
                                   displayResolver: DisplayResolver(screenProvider: { [] }),
                                   applicationLauncher: launcher, targetOpener: opener,
                                   browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                                   applicationActivator: RecordingApplicationActivator { _ in },
                                   discoveryResultProvider: { discovery }, runningApplicationBundleProvider: { [bundle] },
                                   launchTimeout: 0)

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), Array(repeating: RestoreSkipReason.desktopUnconfirmed, count: 2))
    }

    func testSeparateInstanceReuseReservesConstrainedGroupsRegardlessOfCaptureAndPIDOrder() async throws {
        let bundle = "com.example.editor"
        let targets = try ["A.txt", "B.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let single = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42,
                                      openingConfiguration: WindowOpeningConfiguration(manualTargets: [targets[0]]))
        let combined = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43,
                                        openingConfiguration: WindowOpeningConfiguration(manualTargets: targets))
        for reverseGroups in [false, true] {
            for reversePIDs in [false, true] {
                let windows = reverseGroups ? [combined, single] : [single, combined]
                let snapshot = makeSnapshot(windows: windows)
                let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
                try store.save(snapshot)
                let live = [
                    makeApplication(bundleIdentifier: bundle, pid: reversePIDs ? 901 : 900, windows: [
                        makeDiscoveredWindow(documentURLs: targets.map(\.url), title: "A and B", frame: combined.frame.cgRect)
                    ]),
                    makeApplication(bundleIdentifier: bundle, pid: reversePIDs ? 900 : 901, windows: [
                        makeDiscoveredWindow(documentURL: targets[0].url, title: "Only A", frame: single.frame.cgRect)
                    ])
                ]
                let opener = RecordingTargetOpener()
                let launcher = RecordingApplicationLauncher(results: [:])
                let applier = RecordingEngineWindowApplier()

                let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([live]),
                                                  windowApplier: applier, targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

                XCTAssertTrue(opener.requests.isEmpty)
                XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
                XCTAssertEqual(result.requestedTargetCount, 0)
                XCTAssertEqual(result.restoredWindows, 2)
                XCTAssertTrue(result.skippedItems.isEmpty)
                XCTAssertEqual(applier.appliedWindowTitles, reverseGroups ? ["A and B", "Only A"] : ["Only A", "A and B"])
            }
        }
    }

    func testSeparateInstanceReuseReassignsOverlappingWindowsWithoutLaunchingReplacement() async throws {
        let bundle = "com.example.editor"
        let targets = try ["A.txt", "B.txt", "C.txt"].map {
            WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
        }
        let windows = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: index < 2 ? 42 : 43,
                             windowTitle: index == 0 ? "A" : target.url.lastPathComponent,
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [
            makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
                makeDiscoveredWindow(documentURLs: Array(targets.prefix(2)).map(\.url),
                                     title: "A", frame: windows[0].frame.cgRect),
                makeDiscoveredWindow(documentURL: targets[0].url,
                                     title: "Only A", frame: windows[0].frame.cgRect)
            ]),
            makeApplication(bundleIdentifier: bundle, pid: 901, windows: [
                makeDiscoveredWindow(documentURL: targets[2].url,
                                     title: "Only C", frame: windows[2].frame.cgRect)
            ])
        ]
        let opener = RecordingTargetOpener()
        let launcher = RecordingApplicationLauncher(results: [:])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: launcher, discovery: DiscoverySequence([live]),
                                          windowApplier: applier, targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 3)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertEqual(applier.appliedWindowTitles, ["Only A", "A", "Only C"])
    }

    func testSeparateInstanceReuseFindsCompleteAssignmentWhenTargetCountsTie() async throws {
        let bundle = "com.example.editor"
        let targets = try ["A.txt", "B.txt", "C.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let first = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42,
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [targets[0], targets[1]]))
        let constrained = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43,
                                           openingConfiguration: WindowOpeningConfiguration(manualTargets: [targets[0], targets[2]]))
        let snapshot = makeSnapshot(windows: [first, constrained])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let live = [
            makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
                makeDiscoveredWindow(documentURLs: targets.map(\.url), title: "A B C", frame: constrained.frame.cgRect)
            ]),
            makeApplication(bundleIdentifier: bundle, pid: 901, windows: [
                makeDiscoveredWindow(documentURLs: [targets[0].url, targets[1].url], title: "A B", frame: first.frame.cgRect)
            ])
        ]
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: DiscoverySequence([live]), windowApplier: applier,
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedWindowTitles, ["A B", "A B C"])
    }

    func testNewInstanceCallbackCannotClaimInitiallyRunningSiblingProcess() async throws {
        let bundle = "com.example.editor"
        let targets = try ["MissingA.txt", "ExistingB.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let windows = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(42 + index),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let existing = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(documentURL: targets[1].url, title: "Existing B", frame: windows[1].frame.cgRect)
        ])
        let consolidated = makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
            makeDiscoveredWindow(documentURLs: targets.map(\.url), title: "Existing B", frame: windows[1].frame.cgRect)
        ])
        let opener = RecordingTargetOpener(results: [.openedApplicationInstance(900)])
        let launcher = RecordingApplicationLauncher(results: [bundle: true])
        let applier = RecordingEngineWindowApplier()

        let result = try await makeEngine(store: store, launcher: launcher,
                                          discovery: DiscoverySequence([[existing], [consolidated]]), windowApplier: applier,
                                          targetOpener: opener, launchTimeout: 0).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [[targets[0].url]])
        XCTAssertEqual(opener.requests.first?.disposition, .newApplicationInstance)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.appInstanceUnconfirmed])
        XCTAssertEqual(applier.appliedWindowTitles, ["Existing B"])
    }

    func testUnexposedOwnerAllowsOrdinaryOpeningButRequiresDocumentEvidence() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Project.txt"))
        let saved = makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 42,
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let discovery = WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [
            UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [
            CGWindowMetadata(windowID: 9001, processIdentifier: 900, ownerName: nil, layer: 0,
                             bounds: CGRect(x: 10, y: 20, width: 600, height: 400), title: "Project",
                             isOnScreen: false, zOrderHint: nil)
        ])
        ])
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                                   windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                                   applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
                                   browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                                   applicationActivator: RecordingApplicationActivator { _ in },
                                   discoveryResultProvider: { discovery }, runningApplicationBundleProvider: { [bundle] },
                                   launchTimeout: 0)

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [[target.url]])
        XCTAssertEqual(opener.requests.first?.disposition, .applicationDefault)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.targetIssues.map(\.reason), [.openingNotConfirmed])
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertTrue(applier.appliedWindowTitles.isEmpty)
    }

    func testWindowlessUnexposedOwnerAllowsLocalOpeningAndConfirmedRestore() async throws {
        let bundle = "com.example.editor"
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Project.txt"))
        let saved = makeWindowRecord(bundleIdentifier: bundle,
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let snapshot = makeSnapshot(windows: [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let initial = WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [
            UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [])
        ])
        let ready = WindowDiscoveryResult(applications: [
            makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
                makeDiscoveredWindow(documentURL: target.url, title: "Opened project", frame: saved.frame.cgRect)
            ])
        ], diagnostics: [])
        var discoveryCalls = 0
        let opener = RecordingTargetOpener()
        let launcher = RecordingApplicationLauncher(results: [:])
        let applier = RecordingEngineWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                                   windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                                   applicationLauncher: launcher, targetOpener: opener,
                                   browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                                   applicationActivator: RecordingApplicationActivator { _ in },
                                   discoveryResultProvider: {
                                       discoveryCalls += 1
                                       return discoveryCalls == 1 ? initial : ready
                                   }, runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0)

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map { $0.targets.map(\.url) }, [[target.url]])
        XCTAssertEqual(opener.requests.first?.disposition, .applicationDefault)
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedWindowTitles, ["Opened project"])
    }

    func testInitiallyUnexposedLocalTargetConfirmedDuringOtherAppRediscoveryHasNoStaleIssue() async throws {
        let firstBundle = "com.microsoft.VSCode"
        let secondBundle = "com.example.second-editor"
        let firstTarget = WindowOpenTarget(kind: .file, url: try makeFile(named: "First.txt"))
        let secondTarget = WindowOpenTarget(kind: .file, url: try makeFile(named: "Second.txt"))
        let first = makeWindowRecord(bundleIdentifier: firstBundle,
                                     openingConfiguration: WindowOpeningConfiguration(manualTargets: [firstTarget]))
        let second = makeWindowRecord(bundleIdentifier: secondBundle,
                                      openingConfiguration: WindowOpeningConfiguration(manualTargets: [secondTarget]))
        let snapshot = makeSnapshot(windows: [first, second])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let initial = WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [
            UnexposedApplicationWindows(bundleIdentifier: firstBundle, pid: 900, windows: [
                CGWindowMetadata(windowID: 9001, processIdentifier: 900, ownerName: nil, layer: 0,
                                 bounds: first.frame.cgRect, title: "Initially hidden", isOnScreen: false, zOrderHint: nil)
            ])
        ])
        let ready = WindowDiscoveryResult(applications: [
            makeApplication(bundleIdentifier: firstBundle, pid: 900, windows: [
                makeDiscoveredWindow(documentURL: firstTarget.url, title: "Now exposed", frame: first.frame.cgRect)
            ]),
            makeApplication(bundleIdentifier: secondBundle, pid: 901, windows: [
                makeDiscoveredWindow(documentURL: secondTarget.url, title: "Opened second", frame: second.frame.cgRect)
            ])
        ], diagnostics: [])
        var discoveryCalls = 0
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                                   windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                                   applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
                                   browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                                   applicationActivator: RecordingApplicationActivator { _ in },
                                   discoveryResultProvider: {
                                       discoveryCalls += 1
                                       return discoveryCalls == 1 ? initial : ready
                                   }, runningApplicationBundleProvider: { [firstBundle] }, launchTimeout: 0)

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map(\.bundleIdentifier), [secondBundle])
        XCTAssertEqual(opener.requests.first?.targets.map(\.url), [secondTarget.url])
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedWindowTitles, ["Now exposed", "Opened second"])
    }

    func testNewSeparateInstancesWaitForConfirmedWindowIDsBeforeApplyingGeometry() async throws {
        let bundle = "com.example.editor"
        let targets = try ["First.txt", "Second.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let windows = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(42 + index),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let unresolved = targets.enumerated().map { index, target in
            makeApplication(bundleIdentifier: bundle, pid: Int32(900 + index), windows: [
                makeDiscoveredWindow(documentURL: target.url, title: "Document \(index)", frame: windows[index].frame.cgRect)
            ])
        }
        let confirmed = targets.enumerated().map { index, target in
            makeApplication(bundleIdentifier: bundle, pid: Int32(900 + index), windows: [
                makeDiscoveredWindow(documentURL: target.url, title: "Document \(index)", frame: windows[index].frame.cgRect,
                                     cgWindowID: CGWindowID(9001 + index))
            ])
        }
        let discovery = DiscoverySequence([[], unresolved, confirmed])
        let opener = RecordingTargetOpener(results: [.openedApplicationInstance(900), .openedApplicationInstance(901)])
        let applier = RecordingEngineWindowApplier()
        let clock = TestClock()
        var pollIntervals: [TimeInterval] = []

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: discovery, windowApplier: applier, targetOpener: opener,
                                          launchTimeout: 1, launchClock: clock.now, launchPollSleeper: { interval in
                                              pollIntervals.append(interval)
                                              await clock.sleep(interval: interval)
                                          }).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(pollIntervals, [0.05])
        XCTAssertEqual(applier.appliedCGWindowIDs, [9001, 9002])
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(result.targetIssues.isEmpty)
    }

    func testOrdinaryLocalOpenWaitsForConfirmedWindowIDsBeforeApplyingGeometry() async throws {
        let bundle = "com.example.editor"
        let targets = try ["First.txt", "Second.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let windows = targets.map {
            makeWindowRecord(bundleIdentifier: bundle,
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [$0]))
        }
        let snapshot = makeSnapshot(windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let unresolved = makeApplication(bundleIdentifier: bundle, pid: 900, windows: targets.enumerated().map { index, target in
            makeDiscoveredWindow(documentURL: target.url, title: "Document \(index)", frame: windows[index].frame.cgRect)
        })
        let confirmed = makeApplication(bundleIdentifier: bundle, pid: 900, windows: targets.enumerated().map { index, target in
            makeDiscoveredWindow(documentURL: target.url, title: "Document \(index)", frame: windows[index].frame.cgRect,
                                 cgWindowID: CGWindowID(9001 + index))
        })
        let discovery = DiscoverySequence([[], [unresolved], [confirmed]])
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let clock = TestClock()
        var pollIntervals: [TimeInterval] = []

        let result = try await makeEngine(store: store, launcher: RecordingApplicationLauncher(results: [:]),
                                          discovery: discovery, windowApplier: applier, targetOpener: opener,
                                          launchTimeout: 1, launchClock: clock.now, launchPollSleeper: { interval in
                                              pollIntervals.append(interval)
                                              await clock.sleep(interval: interval)
                                          }).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(opener.requests.map(\.disposition), [.applicationDefault, .applicationDefault])
        XCTAssertEqual(discovery.callCount, 3)
        XCTAssertEqual(pollIntervals, [0.05])
        XCTAssertEqual(applier.appliedCGWindowIDs, [9001, 9002])
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(result.targetIssues.isEmpty)
    }

    func testForcedNewWindowOpeningIgnoresOnlyExplicitlyEmptySpaceMembership() async throws {
        try await assertUnexposedWindowMembershipPolicy(separateProcesses: false)
    }

    func testSeparateInstanceOpeningIgnoresOnlyExplicitlyEmptySpaceMembership() async throws {
        try await assertUnexposedWindowMembershipPolicy(separateProcesses: true)
    }

    private func assertUnexposedWindowMembershipPolicy(separateProcesses: Bool) async throws {
        let bundle = separateProcesses ? "com.example.editor" : "com.microsoft.VSCode"
        let targets = try ["First.txt", "Second.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let windows = targets.prefix(separateProcesses ? 2 : 1).enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: Int32(42 + index),
                             openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        }
        let cases: [(name: String, membership: Set<UInt64>?, allowsOpening: Bool)] = [
            ("unknown", nil, false), ("empty", [], true), ("ordinary", [10], false),
            ("fullscreen", [99], false), ("multiple", [10, 11], false)
        ]
        for item in cases {
            let snapshot = makeSnapshot(windows: windows)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let unexposed = UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [
                CGWindowMetadata(windowID: 9001, processIdentifier: 900, ownerName: nil, layer: 0,
                                 bounds: windows[0].frame.cgRect, title: "Retained CG window", isOnScreen: false, zOrderHint: nil)
            ])
            let initial = WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [unexposed])
            let ready = WindowDiscoveryResult(applications: windows.enumerated().map { index, saved in
                makeApplication(bundleIdentifier: bundle, pid: Int32(901 + index), windows: [
                    makeDiscoveredWindow(documentURL: targets[index].url, title: "Confirmed \(index)", frame: saved.frame.cgRect,
                                         cgWindowID: CGWindowID(9011 + index))
                ])
            }, diagnostics: [], unexposedApplications: [unexposed])
            let opener = RecordingTargetOpener(results: separateProcesses
                ? [.openedApplicationInstance(901), .openedApplicationInstance(902)] : [.opened])
            let launcher = RecordingApplicationLauncher(results: [:])
            let applier = RecordingEngineWindowApplier()
            let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
                inventory: { _ in nil }, membership: { _ in item.membership }, submitMove: { _, _ in false }), sleeper: {})
            var discoveryCalls = 0
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                                       windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
                                       applicationLauncher: launcher, targetOpener: opener,
                                       browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                                       applicationActivator: RecordingApplicationActivator { _ in }, spaces: spaces,
                                       discoveryResultProvider: {
                                           discoveryCalls += 1
                                           return discoveryCalls == 1 ? initial : ready
                                       }, runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0)

            let result = try await engine.restoreSnapshot(id: snapshot.id)

            let expectedCount = item.allowsOpening ? windows.count : 0
            let disposition: RestoreTargetOpenDisposition = separateProcesses ? .newApplicationInstance : .newWindow
            XCTAssertEqual(opener.requests.count, expectedCount, item.name)
            XCTAssertEqual(opener.requests.map(\.disposition), Array(repeating: disposition, count: expectedCount), item.name)
            XCTAssertEqual(result.requestedTargetCount, expectedCount, item.name)
            XCTAssertEqual(result.restoredWindows, expectedCount, item.name)
            XCTAssertEqual(applier.appliedWindowTitles.count, expectedCount, item.name)
            XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty, item.name)
            if item.allowsOpening {
                XCTAssertTrue(result.targetIssues.isEmpty, item.name)
                XCTAssertTrue(result.skippedItems.isEmpty, item.name)
            } else {
                XCTAssertEqual(result.skippedItems.count, windows.count, item.name)
            }
        }
    }

    func testNewInstanceWorkspaceOpenerPreservesOrderedTargetsAndReturnedPID() async throws {
        let applicationURL = temporaryDirectoryURL.appendingPathComponent("Editor.app")
        let targets = try ["First.txt", "Second.txt"].map { WindowOpenTarget(kind: .file, url: try makeFile(named: $0)) }
        let opener = NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in applicationURL },
            commandRunner: { _, _ in XCTFail("Instance launch must use NSWorkspace"); return false },
            workspaceOpener: { _, _, _ in XCTFail("Expected instance callback"); return false },
            instanceWorkspaceOpener: { urls, appURL, configuration in
                XCTAssertEqual(urls, targets.map(\.url))
                XCTAssertEqual(appURL, applicationURL)
                XCTAssertTrue(configuration.createsNewApplicationInstance)
                XCTAssertFalse(configuration.activates)
                return 900
            }
        )

        let result = await opener.open(targets: targets, bundleIdentifier: "com.microsoft.VSCode",
                                       disposition: .newApplicationInstance)

        guard case .openedApplicationInstance(let pid) = result else {
            return XCTFail("Expected the actual runtime process identifier")
        }
        XCTAssertEqual(pid, 900)
        XCTAssertTrue(result.wasSubmitted)
    }

    func testAutomaticLocalTargetInspectionReusesConfirmedHiddenDocumentWithoutOpening() async throws {
        let fixture = try makeLocalTargetInspection()

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.moveDestinations, [11])
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9001])
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testLayoutRefreshFailureReturnsConfirmedInspectionBeforeThrowing() async throws {
        for returnSucceeds in [true, false] {
            let fixture = try makeLocalTargetInspection()
            fixture.state.confirmsReturnMove = returnSucceeds
            fixture.state.onDiscovery = { [unowned state = fixture.state] in
                if state.didInspect {
                    XCTAssertEqual(state.membership, [11])
                    throw WindowDiscoveryError.accessibilityPermissionDenied
                }
            }

            do {
                _ = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)
                XCTFail("Expected the layout refresh to fail")
            } catch WindowDiscoveryError.accessibilityPermissionDenied {
                XCTAssertTrue(returnSucceeds)
            } catch RestoreEngineError.inspectionNotReturned {
                XCTAssertFalse(returnSucceeds)
            }

            XCTAssertEqual(fixture.state.moveDestinations, [11, 10])
            XCTAssertEqual(fixture.state.returnTaskWasCancelled, false)
            XCTAssertEqual(fixture.state.membership, returnSucceeds ? [10] : [11])
            XCTAssertEqual(fixture.state.frame, returnSucceeds ? fixture.state.originalFrame : fixture.state.gatheredFrame)
            XCTAssertTrue(fixture.opener.requests.isEmpty)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
            XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
            XCTAssertEqual(fixture.applier.raiseCount, 0)
            XCTAssertEqual(fixture.applier.focusCount, 0)
        }
    }

    func testGenericMultipleProjectsRecoverHiddenCGWindowWithoutOpeningOnRepeatedRestores() async throws {
        let fixture = try makeMultipleProjectInspection()

        for _ in 0..<2 {
            let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)
            XCTAssertEqual(result.restoredWindows, 3)
            XCTAssertEqual(result.requestedTargetCount, 0)
            XCTAssertTrue(result.targetIssues.isEmpty)
            XCTAssertTrue(result.skippedItems.isEmpty)
        }

        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(fixture.state.moveDestinations, [11])
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs.compactMap { $0 }.sorted(),
                       [9001, 9001, 9002, 9002, 9003, 9003])
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testPartiallyExposedSameProcessProjectsRecoverOnlyHiddenCGWindow() async throws {
        let fixture = try makeMultipleProjectInspection(sameProcess: true)

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(result.restoredWindows, 3)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(fixture.state.moveDestinations, [11])
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), [9001, 9002, 9003])
    }

    func testCoreGraphicsCaptureRevealingAXDialogReturnsBeforeOpeningReplacement() async throws {
        let fixture = try makeLocalTargetInspection(captureSource: .coreGraphics)
        fixture.state.inspectedWindowSubrole = "AXDialog"
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "open"])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testTargetlessCoreGraphicsCaptureRevealingAXDialogReturnsAndSkipsGeometry() async throws {
        let fixture = try makeLocalTargetInspection(captureSource: .coreGraphics, hasOpeningTarget: false)
        fixture.state.inspectedWindowSubrole = "AXDialog"

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10"])
        XCTAssertEqual(fixture.state.membership, [10])
        XCTAssertEqual(fixture.state.frame, fixture.state.originalFrame)
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testLocalTargetInspectionReturnsSameNamedWrongDocumentBeforeOpeningAndMatchingReplacement() async throws {
        let otherDirectory = try makeFolder(named: "Other project")
        let otherURL = otherDirectory.appendingPathComponent("Project.txt")
        try Data().write(to: otherURL)
        let fixture = try makeLocalTargetInspection(observedURL: otherURL)
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "open"])
        XCTAssertEqual(fixture.opener.requests.map { $0.targets.map(\.url) }, [[fixture.target.url]])
        XCTAssertEqual(fixture.opener.requests.first?.disposition, .applicationDefault)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.targetIssues.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testLocalTargetInspectionReturnsWindowBeforeOpeningWhenAXDoesNotReappear() async throws {
        let otherURL = try makeFolder(named: "Other project").appendingPathComponent("Project.txt")
        try Data().write(to: otherURL)
        let fixture = try makeLocalTargetInspection(observedURL: otherURL)
        fixture.state.inspectedWindowExposed = false
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "open"])
        XCTAssertEqual(fixture.state.membership, [10])
        XCTAssertEqual(fixture.state.frame, fixture.state.originalFrame)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
    }

    func testLocalTargetInspectionBlocksOpeningAndGeometryUntilReturnMembershipAndFrameAreConfirmed() async throws {
        for missingProof in ["membership", "frame"] {
            let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-\(missingProof).txt"))
            if missingProof == "membership" {
                fixture.state.confirmsReturnMove = false
            } else {
                fixture.state.returnRestoresFrame = false
            }

            let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

            XCTAssertEqual(fixture.state.moveDestinations, [11, 10], missingProof)
            XCTAssertTrue(fixture.opener.requests.isEmpty, missingProof)
            XCTAssertEqual(result.requestedTargetCount, 0, missingProof)
            XCTAssertEqual(result.restoredWindows, 0, missingProof)
            XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.inspectionNotReturned], missingProof)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty, missingProof)
            XCTAssertTrue(fixture.applier.restoredFrames.isEmpty, missingProof)
            XCTAssertEqual(fixture.applier.raiseCount, 0, missingProof)
            XCTAssertEqual(fixture.applier.focusCount, 0, missingProof)
        }
    }

    func testReplacementInstanceSupersedesRecoveredWindowForIncompleteCaptureGroup() async throws {
        let bundle = "com.example.editor"
        let scenarios = ["AX-hidden original", "visible original", "reused original", "closed original", "failed return", "cancelled launch", "intervening frame"]
        var completedScenarios: Set<String> = []
        defer { XCTAssertEqual(completedScenarios, Set(scenarios)) }
        for scenario in scenarios {
            defer { completedScenarios.insert(scenario) }
            let reuseOriginal = scenario == "reused original"
            let originalClosed = scenario == "closed original"
            let oldWindowRemains = scenario != "AX-hidden original" && !originalClosed
            let targets = try ["Recovered-A.txt", "Missing-B.txt", "Complete-C.txt"].map {
                WindowOpenTarget(kind: .file, url: try makeFile(named: $0))
            }
            let savedTargets = [targets[0], targets[1], reuseOriginal ? targets[0] : targets[2]]
            let saved = savedTargets.enumerated().map { index, target in
                makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: index < 2 ? 42 : 43,
                    windowTitle: index == 0 ? "Hidden A" : target.url.lastPathComponent,
                    subrole: index == 0 ? nil : "AXStandardWindow",
                    openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]),
                    captureSource: index == 0 ? .coreGraphics : .accessibility)
            }
            let display = makeDisplayRecord()
            let snapshot = Snapshot(name: "Automatic separate instances",
                sourceDisplayState: DisplayState(displays: [display], primaryDisplayID: display.id), windows: saved)
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            try store.save(snapshot)
            let state = LocalTargetInspectionState()
            state.metadataTitle = "Hidden A"
            let opener = RecordingTargetOpener(results: [.openedApplicationInstance(902)], onOpen: { _ in
                XCTAssertEqual(state.membership, [11])
                state.didOpen = true
                if scenario == "cancelled launch" { withUnsafeCurrentTask { $0?.cancel() } }
                if scenario == "intervening frame" { state.frame.origin.x += 30 }
            })
            let applier = RecordingEngineWindowApplier()
            let launcher = RecordingApplicationLauncher(results: [:])
            let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
                inventory: { _ in RestoreSpaceInventory(activeByDisplay: [display.id: 11], ordinarySpaceIDs: [10, 11]) },
                membership: { $0 == 9001 ? state.membership : [11] },
                submitMove: { id, destination in
                    XCTAssertEqual(id, 9001)
                    state.moveDestinations.append(destination)
                    if destination == 10 && scenario == "failed return" { return false }
                    state.membership = [destination]
                    state.frame = destination == 10 ? state.originalFrame : state.gatheredFrame
                    return true
                },
                applicationWindowIDs: { $0 == 900 ? (state.didOpen && originalClosed ? [] : [9001]) : ($0 == 902 ? [9021, 9022] : [9011]) },
                windowMetadata: { pid, id in pid == 900 && id == 9001 && !(state.didOpen && originalClosed) ? state.metadata : nil }
            ), sleeper: {})
            let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
                windowApplier: applier, displayResolver: DisplayResolver(screenProvider: {
                    [DisplayResolver.ScreenSnapshot(id: display.id, localizedName: display.localizedName,
                        frame: display.frameRect, visibleFrame: display.visibleFrameRect, backingScaleFactor: 1,
                        isPrimary: true, vendorID: nil, productID: nil, serialNumber: nil)]
                }), applicationLauncher: launcher, targetOpener: opener,
                browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
                applicationActivator: RecordingApplicationActivator { _ in }, spaces: spaces,
                discoveryResultProvider: {
                    var applications = [self.makeApplication(bundleIdentifier: bundle, pid: 901, windows: [
                        self.makeDiscoveredWindow(documentURL: targets[2].url, title: "Complete C",
                            frame: saved[2].frame.cgRect, cgWindowID: 9011)
                    ])]
                    if state.membership == [11], !state.didOpen || oldWindowRemains {
                        applications.append(self.makeApplication(bundleIdentifier: bundle, pid: 900, windows: [
                            self.makeDiscoveredWindow(documentURL: targets[0].url, title: "Hidden A",
                                frame: state.frame, cgWindowID: 9001)
                        ]))
                    }
                    if state.didOpen {
                        applications.append(self.makeApplication(bundleIdentifier: bundle, pid: 902, windows: (0..<2).map { index in
                            self.makeDiscoveredWindow(documentURL: targets[index].url, title: "Replacement \(index)",
                                frame: saved[index].frame.cgRect, cgWindowID: CGWindowID(9021 + index))
                        }))
                    }
                    return WindowDiscoveryResult(applications: applications, diagnostics: [], unexposedApplications:
                        state.membership == [10] ? [UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900,
                            windows: [state.metadata], documentURLs: [targets[0].url])] : [])
                }, runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0)

            let restore = Task { try await engine.restoreSnapshot(id: snapshot.id) }
            if scenario == "cancelled launch" {
                do {
                    _ = try await restore.value
                    XCTFail("Expected cancellation after returning the unused inspection")
                } catch is CancellationError {}
                XCTAssertFalse(Task.isCancelled)
                XCTAssertEqual(state.moveDestinations, [11, 10])
                XCTAssertEqual(state.membership, [10])
                XCTAssertEqual(state.frame, state.originalFrame)
                XCTAssertTrue(applier.appliedCGWindowIDs.isEmpty)
                continue
            }
            let result = try await restore.value
            if scenario == "failed return" || scenario == "intervening frame" {
                XCTAssertEqual(result.restoredWindows, 1)
                XCTAssertEqual(result.skippedItems.map(\.reason), Array(repeating: RestoreSkipReason.inspectionNotReturned, count: 2))
                XCTAssertEqual(applier.appliedCGWindowIDs, [9011])
                XCTAssertEqual(state.moveDestinations, scenario == "failed return" ? [11, 10] : [11])
                continue
            }

            XCTAssertEqual(result.restoredWindows, 3)
            XCTAssertTrue(result.skippedItems.isEmpty)
            XCTAssertTrue(result.targetIssues.isEmpty)
            XCTAssertEqual(result.requestedTargetCount, 2)
            XCTAssertEqual(opener.requests.map(\.disposition), [.newApplicationInstance])
            XCTAssertEqual(opener.requests.first?.targets.map(\.url), Array(targets.prefix(2)).map(\.url))
            XCTAssertEqual(applier.appliedCGWindowIDs.compactMap { $0 }.sorted(), reuseOriginal ? [9001, 9021, 9022] : [9011, 9021, 9022])
            XCTAssertEqual(state.moveDestinations, reuseOriginal || originalClosed ? [11] : [11, 10])
            if !reuseOriginal && !originalClosed {
                XCTAssertEqual(state.membership, [10])
                XCTAssertEqual(state.frame, state.originalFrame)
            }
            XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
            XCTAssertTrue(launcher.requestedInstanceBundleIdentifiers.isEmpty)
        }
    }

    func testLocalTargetInspectionDoesNotForceReturnAfterObservedOwnerFrameOrActiveSpaceChanges() async throws {
        for interveningChange in ["owner", "frame", "active Space"] {
            let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-\(interveningChange).txt"))
            fixture.state.onInspection = { [unowned state = fixture.state] in
                switch interveningChange {
                case "owner": state.ownerPID = 901
                case "frame": state.frame.origin.x += 30
                default: state.activeSpaceID = 10
                }
            }

            let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

            XCTAssertEqual(fixture.state.moveDestinations, [11], interveningChange)
            XCTAssertTrue(fixture.opener.requests.isEmpty, interveningChange)
            XCTAssertEqual(result.restoredWindows, 0, interveningChange)
            XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.inspectionNotReturned], interveningChange)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty, interveningChange)
            XCTAssertTrue(fixture.applier.restoredFrames.isEmpty, interveningChange)
        }
    }

    func testCancelledLocalTargetInspectionReturnsWindowInUncancelledTaskBeforePropagatingCancellation() async throws {
        let fixture = try makeLocalTargetInspection()
        fixture.state.onInspection = {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let restore = Task { try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id) }

        do {
            _ = try await restore.value
            XCTFail("Expected the actual task cancellation to propagate after compensation")
        } catch is CancellationError {
            // The parent XCTest task remains uncancelled while the restore task compensates.
        }

        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(fixture.state.moveDestinations, [11, 10])
        XCTAssertEqual(fixture.state.returnTaskWasCancelled, false)
        XCTAssertEqual(fixture.state.membership, [10])
        XCTAssertEqual(fixture.state.frame, fixture.state.originalFrame)
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testCancellationDuringInspectionSubmissionOrPollingReturnsWindowBeforeThrowing() async throws {
        for cancellationStage in ["submission", "polling"] {
            let fixture = try makeLocalTargetInspection()
            let gate = AsyncStream<Void>.makeStream()
            let restore = Task {
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)
            }
            let cancelAfterMovement = { [unowned state = fixture.state] in
                state.onMovePoll = nil
                state.membership = [11]
                state.frame = state.gatheredFrame
                restore.cancel()
            }
            if cancellationStage == "submission" {
                fixture.state.onForwardMove = cancelAfterMovement
            } else {
                fixture.state.confirmsForwardMove = false
                fixture.state.onMovePoll = cancelAfterMovement
            }
            gate.continuation.yield(())
            gate.continuation.finish()

            do {
                _ = try await restore.value
                XCTFail("Expected cancellation after compensation")
            } catch is CancellationError {
                // Cancellation must be propagated only after the submitted move is compensated.
            }

            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(fixture.state.moveDestinations, [11, 10], cancellationStage)
            XCTAssertEqual(fixture.state.membership, [10], cancellationStage)
            XCTAssertEqual(fixture.state.frame, fixture.state.originalFrame, cancellationStage)
            XCTAssertEqual(fixture.state.returnTaskWasCancelled, false, cancellationStage)
            XCTAssertTrue(fixture.opener.requests.isEmpty, cancellationStage)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty, cancellationStage)
        }
    }

    func testFailedInspectionBlocksItsWholeInstanceBatchWhileOtherGroupsRestore() async throws {
        for missingProof in ["membership", "frame"] {
            let otherURL = try makeFile(named: "Blocked-group-\(missingProof).txt")
            let fixture = try makeLocalTargetInspection(observedURL: otherURL, separateInstanceSibling: true)
            var snapshot = fixture.snapshot
            if missingProof == "membership" {
                fixture.state.confirmsReturnMove = false
            } else {
                fixture.state.returnRestoresFrame = false
                fixture.state.repairsCGFrame = false
                fixture.state.returnedWindowExposed = true
                let extra = makeWindowRecord(bundleIdentifier: fixture.snapshot.windows[0].bundleIdentifier, pidAtCapture: 42,
                    windowTitle: "Other batch member", openingConfiguration: WindowOpeningConfiguration(
                        automaticallyCapturedTargets: [WindowOpenTarget(kind: .file, url: otherURL)]))
                snapshot = Snapshot(id: snapshot.id, name: snapshot.name, sourceDisplayState: snapshot.sourceDisplayState,
                    windows: snapshot.windows + [extra])
                try SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL).save(snapshot)
            }

            let result = try await fixture.engine.restoreSnapshot(id: snapshot.id)

            XCTAssertEqual(result.restoredWindows, 1, missingProof)
            XCTAssertTrue(fixture.opener.requests.isEmpty, missingProof)
            XCTAssertEqual(result.requestedTargetCount, 0, missingProof)
            XCTAssertEqual(result.skippedItems.map(\.reason), Array(repeating: RestoreSkipReason.inspectionNotReturned,
                count: snapshot.windows.count - 1), missingProof)
            XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9003], missingProof)
        }
    }

    func testUnconfirmedLocalTargetInspectionMoveIsNotRetriedReturnedOrOpened() async throws {
        let fixture = try makeLocalTargetInspection()
        fixture.state.confirmsForwardMove = false

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.moveDestinations, [11])
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.desktopUnconfirmed])
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testLocalTargetInspectionWithoutFreshMetadataOpensNormallyWithoutMovingCandidate() async throws {
        let otherURL = try makeFolder(named: "Other project").appendingPathComponent("Project.txt")
        try Data().write(to: otherURL)
        let fixture = try makeLocalTargetInspection(observedURL: otherURL)
        fixture.state.metadataAvailable = false

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["open"])
        XCTAssertTrue(fixture.state.moveDestinations.isEmpty)
        XCTAssertEqual(fixture.opener.requests.first?.disposition, .applicationDefault)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testLocalTargetInspectionLeavesHiddenOwnerAloneWhenExposedSiblingAlreadyHasDocument() async throws {
        let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-hidden-owner.txt"))
        fixture.state.exposedSiblingHasDocument = true

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertTrue(fixture.state.moveDestinations.isEmpty)
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(result.targetIssues.isEmpty)
    }

    func testCodeInspectionReturnsWrongProjectBeforeOpeningSavedWorkspace() async throws {
        let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-code-project.txt"),
                                                   bundleIdentifier: "com.microsoft.VSCode")
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "open"])
        XCTAssertEqual(fixture.opener.requests.first?.disposition, .newWindow)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertTrue(result.targetIssues.isEmpty)
    }

    func testCodeInspectionKeepsBlockingWhenDocumentOrSiblingRemainsUnresolved() async throws {
        for exposesDocument in [false, true] {
            let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Unresolved-code-\(exposesDocument).txt"),
                bundleIdentifier: "com.microsoft.VSCode", exposesDocument: exposesDocument,
                hasUnresolvedSibling: exposesDocument)

            let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

            XCTAssertEqual(fixture.state.events, ["move:11", "move:10"])
            XCTAssertTrue(fixture.opener.requests.isEmpty)
            XCTAssertEqual(result.restoredWindows, 0)
            XCTAssertEqual(result.requestedTargetCount, 0)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
        }
    }

    func testCodeInspectionDoesNotRuleOutTheSameWindowForAnotherSavedResource() async throws {
        let otherURL = try makeFile(named: "Second-code-project.txt")
        let fixture = try makeLocalTargetInspection(observedURL: otherURL, bundleIdentifier: "com.microsoft.VSCode")
        let second = makeWindowRecord(bundleIdentifier: "com.microsoft.VSCode", windowTitle: "Old second-project title",
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [
                WindowOpenTarget(kind: .file, url: otherURL)
            ]))
        let snapshot = Snapshot(id: fixture.snapshot.id, name: fixture.snapshot.name,
            sourceDisplayState: fixture.snapshot.sourceDisplayState, windows: fixture.snapshot.windows + [second])
        try SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL).save(snapshot)

        let result = try await fixture.engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(fixture.opener.requests.map { $0.targets.map(\.url) }, [[fixture.target.url]])
        XCTAssertEqual(result.requestedTargetCount, 1)
    }

    func testCodeInspectionDoesNotRuleOutConflictingDuplicateAXRecords() async throws {
        let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Conflicting-code-project.txt"),
                                                   bundleIdentifier: "com.microsoft.VSCode")
        fixture.state.duplicatesInspectedWindow = true

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10"])
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
    }

    func testLocalTargetInspectionRepairsReturnedFrameWithFreshAXHandleBeforeOpening() async throws {
        let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-repair.txt"))
        fixture.state.returnRestoresFrame = false
        fixture.state.returnedWindowExposed = true
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "repair", "open"])
        XCTAssertEqual(fixture.applier.restoredFrames.count, 1)
        let repair = try XCTUnwrap(fixture.applier.restoredFrames.first)
        XCTAssertEqual(repair.window.cgWindowID, 9001)
        XCTAssertTrue(CFEqual(repair.window.axElement, fixture.state.returnedAXElement))
        XCTAssertFalse(CFEqual(repair.window.axElement, fixture.state.inspectedAXElement))
        XCTAssertEqual(repair.frame, fixture.state.originalFrame)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(fixture.applier.appliedCGWindowIDs, [9002])
        XCTAssertTrue(result.skippedItems.isEmpty)
    }

    func testLocalTargetInspectionDoesNotTrustFrameRepairWithoutCGProof() async throws {
        let fixture = try makeLocalTargetInspection(observedURL: makeFile(named: "Wrong-unverified-repair.txt"))
        fixture.state.returnRestoresFrame = false
        fixture.state.returnedWindowExposed = true
        fixture.state.repairsCGFrame = false

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(fixture.state.events, ["move:11", "move:10", "repair"])
        XCTAssertEqual(fixture.applier.restoredFrames.count, 1)
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.inspectionNotReturned])
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
    }

    func testLocalTargetInspectionReturnsDuplicateAXIdentityBeforeOrdinaryOpening() async throws {
        let fixture = try makeLocalTargetInspection()
        fixture.state.duplicatesInspectedWindow = true
        fixture.state.onOpen = { [unowned state = fixture.state] in
            XCTAssertEqual(state.membership, [10])
            XCTAssertEqual(state.frame, state.originalFrame)
        }

        let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

        XCTAssertEqual(Array(fixture.state.events.prefix(3)), ["move:11", "move:10", "open"])
        XCTAssertEqual(fixture.opener.requests.count, 1)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    func testLocalTargetInspectionPreservesNewlyObservedMinimizedOrFullscreenWindow() async throws {
        for observedState in ["minimized", "fullscreen"] {
            let fixture = try makeLocalTargetInspection()
            fixture.state.inspectedWindowMinimized = observedState == "minimized"
            fixture.state.inspectedWindowFullscreen = observedState == "fullscreen"

            let result = try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id)

            XCTAssertEqual(fixture.state.moveDestinations, [11], observedState)
            XCTAssertEqual(fixture.state.membership, [11], observedState)
            XCTAssertTrue(fixture.opener.requests.isEmpty, observedState)
            XCTAssertEqual(result.requestedTargetCount, 0, observedState)
            XCTAssertEqual(result.restoredWindows, 0, observedState)
            XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.inspectionNotReturned], observedState)
            XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty, observedState)
            XCTAssertTrue(fixture.applier.restoredFrames.isEmpty, observedState)
            XCTAssertEqual(fixture.applier.raiseCount, 0, observedState)
            XCTAssertEqual(fixture.applier.focusCount, 0, observedState)
        }
    }

    func testCancelledLocalTargetInspectionReportsFailedCompensationInsteadOfCancellation() async throws {
        let fixture = try makeLocalTargetInspection()
        fixture.state.confirmsReturnMove = false
        fixture.state.onInspection = {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let restore = Task { try await fixture.engine.restoreSnapshot(id: fixture.snapshot.id) }

        do {
            _ = try await restore.value
            XCTFail("Expected the failed return to be reported")
        } catch RestoreEngineError.inspectionNotReturned {
            // A failed compensation needs an actionable error, even after cancellation.
        }

        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(fixture.state.moveDestinations, [11, 10])
        XCTAssertEqual(fixture.state.returnTaskWasCancelled, false)
        XCTAssertEqual(fixture.state.membership, [11])
        XCTAssertTrue(fixture.opener.requests.isEmpty)
        XCTAssertTrue(fixture.applier.appliedCGWindowIDs.isEmpty)
        XCTAssertTrue(fixture.applier.restoredFrames.isEmpty)
    }

    private func makeMultipleProjectInspection(sameProcess: Bool = false) throws -> LocalTargetInspectionFixture {
        let bundle = "com.example.projectworkspace"
        let targets = try ["Alpha", "Beta", "Hidden"].map {
            WindowOpenTarget(kind: .folder, url: try makeFolder(named: "\($0)-\(UUID().uuidString)"))
        }
        let saved = targets.enumerated().map { index, target in
            makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: sameProcess ? 5 : Int32(5 + index),
                windowTitle: index == 2 ? nil : "Project \(index)",
                subrole: index == 2 ? nil : "AXStandardWindow",
                openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]),
                captureSource: index == 2 ? .coreGraphics : .accessibility)
        }
        let display = makeDisplayRecord(id: 1)
        let snapshot = Snapshot(name: "Generic project windows",
            sourceDisplayState: DisplayState(displays: [display], primaryDisplayID: 1), windows: saved)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let state = LocalTargetInspectionState()
        state.metadataTitle = nil
        let opener = RecordingTargetOpener()
        let applier = RecordingEngineWindowApplier()
        let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
            inventory: { _ in RestoreSpaceInventory(activeByDisplay: [1: 11], ordinarySpaceIDs: [10, 11]) },
            membership: { $0 == 9001 ? state.membership : [11] },
            submitMove: { windowID, spaceID in
                XCTAssertEqual(windowID, 9001)
                state.moveDestinations.append(spaceID)
                state.membership = [spaceID]
                return true
            },
            applicationWindowIDs: { pid in
                sameProcess ? [9001, 9002, 9003] : (pid == 900 ? [9001] : [CGWindowID(pid + 8101)])
            },
            windowMetadata: { pid, windowID in
                guard pid == 900, windowID == 9001 else { return nil }
                return state.metadata
            }), sleeper: {})
        let resolver = DisplayResolver(screenProvider: {
            [DisplayResolver.ScreenSnapshot(id: display.id, localizedName: display.localizedName,
                frame: display.frameRect, visibleFrame: display.visibleFrameRect, backingScaleFactor: 1,
                isPrimary: true, vendorID: nil, productID: nil, serialNumber: nil)]
        })
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: resolver,
            applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in }, spaces: spaces,
            discoveryResultProvider: {
                let exposed = (0..<2).map { index in
                    self.makeDiscoveredWindow(documentURL: targets[index].url, title: "Project \(index)",
                        frame: saved[index].frame.cgRect, cgWindowID: UInt32(9002 + index))
                }
                let hidden = self.makeDiscoveredWindow(documentURL: targets[2].url, title: "Fresh project title",
                    frame: state.frame, cgWindowID: 9001, axElement: state.inspectedAXElement)
                let visibleWindows = exposed + (state.membership == [11] ? [hidden] : [])
                let applications: [DiscoveredApplication]
                if sameProcess {
                    applications = [self.makeApplication(bundleIdentifier: bundle, pid: 900, windows: visibleWindows)]
                } else {
                    applications = visibleWindows.enumerated().map { index, window in
                        self.makeApplication(bundleIdentifier: bundle, pid: index == 2 ? 900 : Int32(901 + index),
                                             windows: [window])
                    }
                }
                let unexposed = state.membership == [11] ? [] : [
                    UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [state.metadata],
                                                documentURLs: [targets[2].url])
                ]
                return WindowDiscoveryResult(applications: applications, diagnostics: [], unexposedApplications: unexposed)
            }, runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0, launchPollSleeper: { _ in })
        return LocalTargetInspectionFixture(engine: engine, snapshot: snapshot, target: targets[2],
                                            state: state, opener: opener, applier: applier)
    }

    private func makeLocalTargetInspection(observedURL: URL? = nil,
                                          captureSource: WindowCaptureSource? = nil,
                                          hasOpeningTarget: Bool = true,
                                          bundleIdentifier: String = "com.example.editor",
                                          exposesDocument: Bool = true,
                                          hasUnresolvedSibling: Bool = false,
                                          separateInstanceSibling: Bool = false) throws -> LocalTargetInspectionFixture {
        let bundle = bundleIdentifier
        let target = WindowOpenTarget(kind: .file, url: try makeFile(named: "Project.txt"))
        let saved = makeWindowRecord(bundleIdentifier: bundle, windowTitle: "Project.txt",
            subrole: captureSource == .coreGraphics ? nil : "AXStandardWindow",
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: hasOpeningTarget ? [target] : []),
            captureSource: captureSource)
        let siblingTarget = separateInstanceSibling
            ? WindowOpenTarget(kind: .file, url: try makeFile(named: "Complete-sibling.txt")) : nil
        let siblingRecords = siblingTarget.map { target in
            [makeWindowRecord(bundleIdentifier: bundle, pidAtCapture: 43, windowTitle: "Complete sibling",
                openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))]
        } ?? []
        let display = makeDisplayRecord(id: 1)
        let snapshot = Snapshot(name: "Inspect hidden document",
            sourceDisplayState: DisplayState(displays: [display], primaryDisplayID: 1), windows: siblingRecords + [saved])
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(snapshot)
        let state = LocalTargetInspectionState()
        let opener = RecordingTargetOpener(onOpen: { _ in
            state.events.append("open")
            state.onOpen?()
            state.didOpen = true
        })
        let applier = RecordingEngineWindowApplier(onRestoreFrame: { frame, _ in
            state.events.append("repair")
            if state.repairsCGFrame { state.frame = frame }
        })
        let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
            inventory: { _ in RestoreSpaceInventory(activeByDisplay: [1: state.activeSpaceID], ordinarySpaceIDs: [10, 11]) },
            membership: { $0 == 9001 ? state.membership : [11] },
            submitMove: { windowID, spaceID in
                XCTAssertEqual(windowID, 9001)
                state.moveDestinations.append(spaceID)
                state.events.append("move:\(spaceID)")
                if spaceID == 11, state.confirmsForwardMove {
                    state.membership = [11]
                    state.frame = state.gatheredFrame
                } else if spaceID == 10 {
                    state.returnTaskWasCancelled = Task.isCancelled
                    if state.confirmsReturnMove {
                        state.membership = [10]
                        if state.returnRestoresFrame { state.frame = state.originalFrame }
                    }
                }
                if spaceID == 11 { state.onForwardMove?() }
                return true
            },
            applicationWindowIDs: { _ in [9001] + (siblingTarget == nil ? [] : [9003]) + (state.didOpen ? [9002] : []) },
            windowMetadata: { _, windowID in
                windowID == 9001 && state.metadataAvailable ? state.metadata : nil
            }), sleeper: { state.onMovePoll?() })
        let displayResolver = DisplayResolver(screenProvider: {
            [DisplayResolver.ScreenSnapshot(id: display.id, localizedName: display.localizedName,
                frame: display.frameRect, visibleFrame: display.visibleFrameRect, backingScaleFactor: 1,
                isPrimary: true, vendorID: nil, productID: nil, serialNumber: nil)]
        })
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: displayResolver,
            applicationLauncher: RecordingApplicationLauncher(results: [:]), targetOpener: opener,
            browserTabCapturer: StubRestoreBrowserTabCapturer(result: .empty),
            applicationActivator: RecordingApplicationActivator { _ in }, spaces: spaces,
            discoveryResultProvider: {
                try state.onDiscovery?()
                let siblingWindows = siblingTarget.map { target in
                    [self.makeDiscoveredWindow(documentURL: target.url, title: "Complete sibling",
                        frame: saved.frame.cgRect, cgWindowID: 9003)]
                } ?? []
                let inspectedWindow = self.makeDiscoveredWindow(documentURL: exposesDocument ? (observedURL ?? target.url) : nil,
                    title: "Project.txt", subrole: state.inspectedWindowSubrole, frame: state.frame, cgWindowID: 9001,
                    axElement: state.membership == [10] ? state.returnedAXElement : state.inspectedAXElement,
                    isMinimized: state.inspectedWindowMinimized, isFullscreen: state.inspectedWindowFullscreen)
                if state.exposedSiblingHasDocument {
                    let sibling = self.makeDiscoveredWindow(documentURL: target.url, title: "Existing sibling project",
                        frame: saved.frame.cgRect, cgWindowID: 9002)
                    return WindowDiscoveryResult(applications: [self.makeApplication(bundleIdentifier: bundle,
                        pid: 901, windows: [sibling])], diagnostics: [], unexposedApplications: [
                            UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [state.metadata])])
                }
                if state.didOpen {
                    let replacement = self.makeDiscoveredWindow(documentURL: target.url, title: "Opened project",
                        frame: saved.frame.cgRect, cgWindowID: 9002)
                    return WindowDiscoveryResult(applications: [self.makeApplication(bundleIdentifier: bundle, pid: 900,
                        windows: siblingWindows + [inspectedWindow, replacement])], diagnostics: [])
                }
                if state.membership == [11] {
                    if !state.didInspect {
                        state.didInspect = true
                        try state.onInspection?()
                    }
                    if state.inspectedWindowExposed {
                        return WindowDiscoveryResult(applications: [self.makeApplication(bundleIdentifier: bundle,
                            pid: 900, windows: siblingWindows + (state.duplicatesInspectedWindow
                                ? [inspectedWindow, self.makeDiscoveredWindow(documentURL: target.url,
                                    title: "Project.txt", frame: state.frame, cgWindowID: 9001)]
                                : [inspectedWindow]))], diagnostics: [])
                    }
                } else if state.didInspect, state.returnedWindowExposed {
                    return WindowDiscoveryResult(applications: [self.makeApplication(bundleIdentifier: bundle,
                        pid: 900, windows: siblingWindows + [inspectedWindow])], diagnostics: [])
                }
                return WindowDiscoveryResult(applications: siblingWindows.isEmpty ? [] : [
                    self.makeApplication(bundleIdentifier: bundle, pid: 900, windows: siblingWindows)],
                    diagnostics: [], unexposedApplications: [
                    UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 900, windows: [state.metadata] +
                        (hasUnresolvedSibling ? [CGWindowMetadata(windowID: 9010, processIdentifier: 900,
                            ownerName: nil, layer: 0, bounds: state.originalFrame, title: "Unresolved sibling",
                            isOnScreen: false, zOrderHint: nil)] : []))])
            }, runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0, launchPollSleeper: { _ in })
        return LocalTargetInspectionFixture(engine: engine, snapshot: snapshot, target: target,
                                            state: state, opener: opener, applier: applier)
    }

    private func makeFile(named name: String) throws -> URL {
        let url = temporaryDirectoryURL.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func makeFolder(named name: String) throws -> URL {
        let url = temporaryDirectoryURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func readTelemetryEvents(from url: URL) throws -> [TelemetryLogEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(TelemetryLogEvent.self, from: Data($0.utf8))
        }
    }

    private func makeEngine(
        store: SnapshotStore,
        launcher: RecordingApplicationLauncher,
        discovery: DiscoverySequence,
        windowApplier: RestoreWindowApplying = RecordingEngineWindowApplier(),
        targetOpener: RestoreTargetOpening = RecordingTargetOpener(),
        browserTabCapturer: BrowserTabCapturing = StubRestoreBrowserTabCapturer(
            result: .empty
        ),
        runningBundleIdentifiers: Set<String> = [],
        launchTimeout: TimeInterval = 5,
        launchClock: @escaping () -> Date = Date.init,
        launchPollSleeper: @escaping (TimeInterval) async -> Void = { _ in }
    ) -> RestoreEngine {
        let trustChecker = AccessibilityTrustChecker { true }
        return RestoreEngine(
            snapshotStore: store,
            trustChecker: trustChecker,
            windowApplier: windowApplier,
            displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: launcher,
            targetOpener: targetOpener,
            browserTabCapturer: browserTabCapturer,
            applicationActivator: RecordingApplicationActivator { _ in },
            discoveredApplicationsProvider: discovery.discover,
            runningApplicationBundleProvider: { runningBundleIdentifiers },
            launchTimeout: launchTimeout,
            launchClock: launchClock,
            launchPollSleeper: launchPollSleeper
        )
    }

    private func makeSnapshot(windows: [WindowRecord]) -> Snapshot {
        Snapshot(
            name: "Coding",
            sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil),
            windows: windows
        )
    }

    private func makeWindowRecord(
        bundleIdentifier: String,
        pidAtCapture: Int32 = 42,
        windowTitle: String? = "Window",
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
        zOrderHint: Int? = nil,
        isMinimized: Bool = false,
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration(),
        captureSource: WindowCaptureSource? = nil,
        cgWindowID: CGWindowID? = nil
    ) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            frame: CGRectCodable(frame),
            displayID: nil,
            normalizedFrame: NormalizedRect(
                xRatio: 0,
                yRatio: 0,
                widthRatio: 0.5,
                heightRatio: 0.5
            ),
            zOrderHint: zOrderHint,
            isMinimized: isMinimized,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: pidAtCapture,
                windowTitle: windowTitle,
                role: role,
                subrole: subrole,
                capturedFrame: CGRectCodable(frame),
                cgWindowID: cgWindowID,
                source: captureSource
            ),
            openingConfiguration: openingConfiguration
        )
    }

    private func makeApplication(
        bundleIdentifier: String,
        pid: pid_t = 200,
        windows: [DiscoveredWindow]
    ) -> DiscoveredApplication {
        DiscoveredApplication(
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            localizedName: nil,
            windows: windows
        )
    }

    private func makeDiscoveredWindow(
        documentURL: URL? = nil,
        documentURLs: [URL] = [],
        documentTitles: [String] = [],
        title: String?,
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        frame: CGRect,
        cgWindowID: CGWindowID? = nil,
        axElement: AXUIElement = AXUIElementCreateSystemWide(),
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        isModal: Bool? = nil
    ) -> DiscoveredWindow {
        DiscoveredWindow(
            axElement: axElement,
            documentURL: documentURL,
            documentURLs: documentURLs,
            documentTitles: documentTitles,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isMain: false,
            isVisible: true,
            cgWindowID: cgWindowID,
            ownerName: nil,
            cgLayer: 0,
            zOrderHint: nil,
            isOnScreen: true,
            isModal: isModal
        )
    }
}

private struct StubRestoreBrowserTabCapturer: BrowserTabCapturing {
    let result: BrowserTabCaptureResult

    func captureTabs(
        runningApplications _: [RunningApplicationSnapshot]
    ) -> BrowserTabCaptureResult {
        result
    }
}

private final class RecordingApplicationLauncher: RestoreApplicationLaunching {
    private let results: [String: Bool]
    private let launchPID: pid_t?
    private(set) var requestedBundleIdentifiers: [String] = []
    private(set) var requestedInstanceBundleIdentifiers: [String] = []
    private var instanceResults: [pid_t?]

    init(results: [String: Bool], instanceResults: [pid_t?] = [], launchPID: pid_t? = 200) {
        self.results = results
        self.instanceResults = instanceResults
        self.launchPID = launchPID
    }

    func launchInstance(bundleIdentifier: String) async -> pid_t? {
        requestedInstanceBundleIdentifiers.append(bundleIdentifier)
        return instanceResults.isEmpty ? nil : instanceResults.removeFirst()
    }

    func requestLaunch(bundleIdentifier: String) async -> pid_t? {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return results[bundleIdentifier] == true ? launchPID : nil
    }
}

private final class RecordingTargetOpener: RestoreTargetOpening {
    struct Request {
        let targets: [WindowOpenTarget]
        let bundleIdentifier: String
        let disposition: RestoreTargetOpenDisposition
    }

    private var results: [RestoreTargetOpenResult]
    private let onOpen: ((Request) -> Void)?
    private(set) var requests: [Request] = []

    init(results: [RestoreTargetOpenResult] = [], onOpen: ((Request) -> Void)? = nil) {
        self.results = results
        self.onOpen = onOpen
    }

    func open(
        targets: [WindowOpenTarget],
        bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition
    ) async -> RestoreTargetOpenResult {
        requests.append(
            Request(
                targets: targets,
                bundleIdentifier: bundleIdentifier,
                disposition: disposition
            )
        )
        onOpen?(requests[requests.count - 1])
        if !results.isEmpty {
            return results.removeFirst()
        }
        return disposition == .newBrowserWindow
            ? .openedNewBrowserWindow(makeCapturedBrowserWindow())
            : .opened
    }
}

private func makeCapturedBrowserWindow(
    browser: BrowserAutomationBrowser = .chrome,
    scriptingIdentifier: String? = "opened-window",
    frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
) -> CapturedBrowserWindow {
    CapturedBrowserWindow(
        browser: browser,
        scriptingIdentifier: scriptingIdentifier,
        title: "Opened Window",
        frame: frame,
        frontToBackIndex: 0,
        tabs: [
            CapturedBrowserTab(
                title: "Example",
                URL: URL(string: "https://example.com")!
            )
        ]
    )
}

private final class RecordingBrowserWindowOpener: BrowserWindowOpening {
    struct Request {
        let targets: [WindowOpenTarget]
        let browser: BrowserAutomationBrowser
    }

    private var results: [BrowserWindowOpenResult]
    private(set) var requests: [Request] = []

    init(results: [BrowserWindowOpenResult]) {
        self.results = results
    }

    func openNewWindow(
        targets: [WindowOpenTarget],
        browser: BrowserAutomationBrowser
    ) async -> BrowserWindowOpenResult {
        requests.append(Request(targets: targets, browser: browser))
        return results.removeFirst()
    }
}

private final class RecordingCommandRunner {
    private(set) var executableURLs: [URL] = []
    private(set) var arguments: [[String]] = []

    func run(executableURL: URL, arguments: [String]) async -> Bool {
        executableURLs.append(executableURL)
        self.arguments.append(arguments)
        return true
    }
}

private final class RecordingWorkspaceOpener {
    struct Request {
        let urls: [URL]
        let applicationURL: URL
    }

    private(set) var requests: [Request] = []

    func open(
        urls: [URL],
        applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async -> Bool {
        requests.append(
            Request(
                urls: urls,
                applicationURL: applicationURL
            )
        )
        return true
    }
}

private final class DiscoverySequence {
    private let discoveredApplicationsByCall: [[DiscoveredApplication]]
    private(set) var callCount = 0

    init(_ discoveredApplicationsByCall: [[DiscoveredApplication]]) {
        self.discoveredApplicationsByCall = discoveredApplicationsByCall
    }

    func discover() throws -> [DiscoveredApplication] {
        let index = min(callCount, discoveredApplicationsByCall.count - 1)
        callCount += 1
        return discoveredApplicationsByCall[index]
    }
}

private final class RecordingEngineWindowApplier: RestoreWindowApplying {
    struct FrameRestoration {
        let frame: CGRect
        let window: DiscoveredWindow
    }

    private(set) var appliedBundleIdentifiers: [String] = []
    private(set) var appliedWindowTitles: [String?] = []
    private(set) var appliedSavedWindowIDs: [UUID] = []
    private(set) var appliedCGWindowIDs: [CGWindowID?] = []
    private(set) var restoredFrames: [FrameRestoration] = []
    private(set) var raiseCount = 0
    private(set) var focusCount = 0
    private let result: RestoreWindowApplyResult
    private let onRestoreFrame: ((CGRect, DiscoveredWindow) -> Void)?
    private let onApply: (() async -> Void)?

    init(result: RestoreWindowApplyResult = .restored(), onRestoreFrame: ((CGRect, DiscoveredWindow) -> Void)? = nil,
        onApply: (() async -> Void)? = nil) {
        self.result = result
        self.onRestoreFrame = onRestoreFrame
        self.onApply = onApply
    }

    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult {
        appliedBundleIdentifiers.append(savedWindow.bundleIdentifier)
        appliedWindowTitles.append(discoveredWindow.title)
        appliedSavedWindowIDs.append(savedWindow.id)
        appliedCGWindowIDs.append(discoveredWindow.cgWindowID)
        await onApply?()
        return result
    }

    func restoreFrame(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult {
        restoredFrames.append(FrameRestoration(frame: targetFrame, window: discoveredWindow))
        onRestoreFrame?(targetFrame, discoveredWindow)
        return result
    }

    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool {
        raiseCount += 1
        return true
    }

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult {
        focusCount += 1
        return RestoreWindowFocusResult(
            didRaise: true,
            didSetMain: true,
            didSetFocused: true
        )
    }
}

private struct LocalTargetInspectionFixture {
    let engine: RestoreEngine
    let snapshot: Snapshot
    let target: WindowOpenTarget
    let state: LocalTargetInspectionState
    let opener: RecordingTargetOpener
    let applier: RecordingEngineWindowApplier
}

private final class LocalTargetInspectionState {
    let originalFrame = CGRect(x: 40, y: 60, width: 500, height: 350)
    let gatheredFrame = CGRect(x: 140, y: 160, width: 500, height: 350)
    let inspectedAXElement = AXUIElementCreateApplication(1001)
    let returnedAXElement = AXUIElementCreateApplication(1002)
    var frame = CGRect(x: 40, y: 60, width: 500, height: 350)
    var membership: Set<UInt64>? = [10]
    var activeSpaceID: UInt64 = 11
    var ownerPID: pid_t = 900
    var metadataAvailable = true
    var confirmsForwardMove = true
    var confirmsReturnMove = true
    var returnRestoresFrame = true
    var inspectedWindowExposed = true
    var duplicatesInspectedWindow = false
    var inspectedWindowMinimized = false
    var inspectedWindowFullscreen = false
    var inspectedWindowSubrole: String? = "AXStandardWindow"
    var metadataTitle: String? = "Project.txt"
    var returnedWindowExposed = false
    var repairsCGFrame = true
    var exposedSiblingHasDocument = false
    var didInspect = false
    var didOpen = false
    var moveDestinations: [UInt64] = []
    var events: [String] = []
    var returnTaskWasCancelled: Bool?
    var onForwardMove: (() -> Void)?
    var onMovePoll: (() -> Void)?
    var onDiscovery: (() throws -> Void)?
    var onInspection: (() throws -> Void)?
    var onOpen: (() -> Void)?

    var metadata: CGWindowMetadata {
        CGWindowMetadata(windowID: 9001, processIdentifier: ownerPID, ownerName: nil, layer: 0,
                         bounds: frame, title: metadataTitle, isOnScreen: membership == [11], zOrderHint: nil)
    }
}

private final class TestClock {
    private var currentDate = Date(timeIntervalSince1970: 100)

    func now() -> Date {
        currentDate
    }

    func sleep(interval: TimeInterval) async {
        currentDate = currentDate.addingTimeInterval(interval)
    }
}
