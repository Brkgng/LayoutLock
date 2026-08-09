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

    func testPlansSkipFarRoleMatchWhenTitleDoesNotMatch() {
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

        XCTAssertNil(plans.first?.candidate)
        XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
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

    func testPlansMatchOptedInSingletonRoleMatchWhenTitleAndFrameChanged() {
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

        let plans = planner.plans(
            for: [savedWindow],
            candidates: candidates,
            singletonFallbackBundleIdentifiers: [bundleIdentifier]
        )

        XCTAssertEqual(plans.first?.candidate?.id, 1)
        XCTAssertNil(plans.first?.skip)
    }

    func testPlansSkipOptedInSingletonWhenRoleOrSubroleDoesNotMatch() {
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
                candidates: [candidate],
                singletonFallbackBundleIdentifiers: [bundleIdentifier]
            )

            XCTAssertNil(plans.first?.candidate, "Unexpectedly matched candidate \(candidate.id).")
            XCTAssertEqual(plans.first?.skip?.reason, RestoreSkipReason.windowNotFound)
        }
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
            candidates: candidates,
            singletonFallbackBundleIdentifiers: [bundleIdentifier]
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
            candidates: candidates,
            singletonFallbackBundleIdentifiers: [bundleIdentifier]
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

    func testZOrderRestorerActivatesAndFocusesSavedFrontmostAfterReplay() {
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

        restorer.restore([
            makeZOrderItem(savedWindow: frontWindow, processIdentifier: 101),
            makeZOrderItem(savedWindow: backWindow, processIdentifier: 303),
            makeZOrderItem(savedWindow: middleWindow, processIdentifier: 202)
        ])

        XCTAssertEqual(events, [
            "raise:com.example.back",
            "raise:com.example.middle",
            "raise:com.example.front",
            "activate:101",
            "focus:com.example.front"
        ])
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
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration()
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
                cgWindowID: nil
            ),
            openingConfiguration: openingConfiguration
        )
    }

    private func makeCandidate(
        id: Int,
        bundleIdentifier: String,
        pid: pid_t,
        documentURLs: [URL] = [],
        title: String?,
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)
    ) -> RestoreWindowCandidate {
        RestoreWindowCandidate(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            documentURLs: documentURLs,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame
        )
    }

    private func makeZOrderItem(
        savedWindow: WindowRecord,
        processIdentifier: pid_t = 42
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
                cgWindowID: savedWindow.captureSignature.cgWindowID,
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

    func testLaunchedAppWithNoMatchingWindowSkipsAsWindowNotFound() async throws {
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
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.windowNotFound)
    }

    func testPollingContinuesPastStartupWindowUntilPlausibleSavedWindowAppears() async throws {
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
        XCTAssertEqual(discovery.callCount, 3)
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

    func testAlreadyRunningSingletonRestoresAfterTitleAndFrameChange() async throws {
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
        XCTAssertEqual(windowApplier.appliedBundleIdentifiers, [bundleIdentifier])
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
        let discovery = DiscoverySequence([[application], [application]])

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
        XCTAssertEqual(result.restoredWindows, 1)
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
        let browserWindowOpener = RecordingBrowserWindowOpener(results: [.opened])
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
                frame: savedWindows[0].frame.cgRect
            ),
            makeDiscoveredWindow(
                documentTitles: ["shell: \(targetURL.path)"],
                title: savedWindows[1].windowTitle,
                frame: savedWindows[1].frame.cgRect
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
                    frame: savedWindows[2].frame.cgRect
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
                    frame: CGRect(x: 900, y: 700, width: 300, height: 200)
                ),
                makeDiscoveredWindow(
                    documentURL: targetURL,
                    title: "Project",
                    frame: savedWindow.frame.cgRect
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
            targetOpener: targetOpener
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
        XCTAssertTrue(launcher.requestedBundleIdentifiers.isEmpty)
    }

    func testConnectedBrowserSkipsWebTargetThatIsAlreadyOpen() async throws {
        let browser = BrowserAutomationBrowser.safari
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

        let result = try await makeEngine(
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
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(targetOpener.requests.isEmpty)
        XCTAssertEqual(result.requestedTargetCount, 0)
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.targetIssues.isEmpty)
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
        let targetOpener = RecordingTargetOpener(results: [.opened])
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

        let result = try await makeEngine(
            store: store,
            launcher: RecordingApplicationLauncher(results: [:]),
            discovery: DiscoverySequence([[application], [application]]),
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
        let targetOpener = RecordingTargetOpener()
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
                    title: savedWindow.windowTitle,
                    frame: savedWindow.frame.cgRect
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

    func testBrowserWindowPollingWaitsForWindowCountIncreaseInsteadOfMatchingStalePID() async throws {
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
            targetOpener: RecordingTargetOpener(),
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

    func testGenericBrowserFallbackDoesNotWaitForWindowCountIncrease() async throws {
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
            launchTimeout: 1,
            launchClock: clock.now,
            launchPollSleeper: clock.sleep
        ).restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(targetOpener.requests.first?.disposition, .newBrowserWindow)
        XCTAssertEqual(discovery.callCount, 2)
        XCTAssertEqual(result.requestedTargetCount, 1)
        XCTAssertEqual(result.restoredWindows, 1)
    }

    func testSeparateBrowserBatchesReportMergedWindowShortage() async throws {
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
                windowTitle: "First",
                openingConfiguration: WindowOpeningConfiguration(
                    manualTargets: [firstTarget]
                )
            )
            let secondWindow = makeWindowRecord(
                bundleIdentifier: browser.bundleIdentifier,
                windowTitle: "Second",
                openingConfiguration: WindowOpeningConfiguration(
                    manualTargets: [secondTarget]
                )
            )
            let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
            let snapshot = makeSnapshot(windows: [firstWindow, secondWindow])
            try store.save(snapshot)
            let targetOpener = RecordingTargetOpener()
            let readyApplication = makeApplication(
                bundleIdentifier: browser.bundleIdentifier,
                windows: [
                    makeDiscoveredWindow(
                        documentURL: firstTarget.url,
                        title: firstWindow.windowTitle,
                        frame: firstWindow.frame.cgRect
                    ),
                    makeDiscoveredWindow(
                        documentURL: secondTarget.url,
                        title: secondWindow.windowTitle,
                        frame: secondWindow.frame.cgRect
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
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration()
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
            isMinimized: false,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: pidAtCapture,
                windowTitle: windowTitle,
                role: role,
                subrole: subrole,
                capturedFrame: CGRectCodable(frame),
                cgWindowID: nil
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
        frame: CGRect
    ) -> DiscoveredWindow {
        DiscoveredWindow(
            axElement: AXUIElementCreateSystemWide(),
            documentURL: documentURL,
            documentURLs: documentURLs,
            documentTitles: documentTitles,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isMinimized: false,
            isFullscreen: false,
            isMain: false,
            isVisible: true,
            cgWindowID: nil,
            ownerName: nil,
            cgLayer: 0,
            zOrderHint: nil,
            isOnScreen: true
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
    private(set) var requestedBundleIdentifiers: [String] = []

    init(results: [String: Bool]) {
        self.results = results
    }

    func requestLaunch(bundleIdentifier: String) -> Bool {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return results[bundleIdentifier] ?? false
    }
}

private final class RecordingTargetOpener: RestoreTargetOpening {
    struct Request {
        let targets: [WindowOpenTarget]
        let bundleIdentifier: String
        let disposition: RestoreTargetOpenDisposition
    }

    private var results: [RestoreTargetOpenResult]
    private(set) var requests: [Request] = []

    init(results: [RestoreTargetOpenResult] = []) {
        self.results = results
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
        if !results.isEmpty {
            return results.removeFirst()
        }
        return disposition == .newBrowserWindow ? .openedNewBrowserWindow : .opened
    }
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
    private(set) var appliedBundleIdentifiers: [String] = []
    private(set) var appliedWindowTitles: [String?] = []
    private(set) var raiseCount = 0
    private(set) var focusCount = 0
    private let result: RestoreWindowApplyResult

    init(result: RestoreWindowApplyResult = .restored()) {
        self.result = result
    }

    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult {
        appliedBundleIdentifiers.append(savedWindow.bundleIdentifier)
        appliedWindowTitles.append(discoveredWindow.title)
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

private final class TestClock {
    private var currentDate = Date(timeIntervalSince1970: 100)

    func now() -> Date {
        currentDate
    }

    func sleep(interval: TimeInterval) async {
        currentDate = currentDate.addingTimeInterval(interval)
    }
}
