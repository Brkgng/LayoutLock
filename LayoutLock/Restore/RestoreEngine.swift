import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

private let restoreRoleMatchOriginTolerance: CGFloat = 160
private let restoreRoleMatchSizeRatioTolerance: CGFloat = 0.25
private let restoreRoleMatchMinimumSizeTolerance: CGFloat = 80

enum RestoreEngineError: LocalizedError {
    case accessibilityPermissionDenied

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility access is required to restore layouts."
        }
    }
}

struct RestoreEngine {
    private let snapshotStore: SnapshotStore
    private let trustChecker: AccessibilityTrustChecker
    private let windowApplier: RestoreWindowApplying
    private let matchPlanner: RestoreWindowMatchPlanner
    private let displayResolver: DisplayResolver
    private let applicationLauncher: RestoreApplicationLaunching
    private let targetOpener: RestoreTargetOpening
    private let browserTabCapturer: BrowserTabCapturing
    private let applicationActivator: RestoreApplicationActivating
    private let discoveredApplicationsProvider: () throws -> [DiscoveredApplication]
    private let runningApplicationBundleProvider: () -> Set<String>
    private let launchTimeout: TimeInterval
    private let launchPollInterval: TimeInterval
    private let launchClock: () -> Date
    private let launchPollSleeper: (TimeInterval) async -> Void
    private let telemetryLogger: TelemetryLogging

    init(
        snapshotStore: SnapshotStore,
        windowDiscoveryEngine: WindowDiscoveryEngine = WindowDiscoveryEngine(),
        trustChecker: AccessibilityTrustChecker = AccessibilityTrustChecker(),
        windowApplier: RestoreWindowApplying = AXRestoreWindowApplier(),
        matchPlanner: RestoreWindowMatchPlanner = RestoreWindowMatchPlanner(),
        displayResolver: DisplayResolver = DisplayResolver(),
        applicationLauncher: RestoreApplicationLaunching = NSWorkspaceRestoreApplicationLauncher(),
        targetOpener: RestoreTargetOpening = NSWorkspaceRestoreTargetOpener(),
        browserTabCapturer: BrowserTabCapturing = BrowserTabCaptureService(),
        applicationActivator: RestoreApplicationActivating = NSWorkspaceRestoreApplicationActivator(),
        telemetryLogger: TelemetryLogging = NoOpTelemetryLogger(),
        discoveredApplicationsProvider: (() throws -> [DiscoveredApplication])? = nil,
        runningApplicationBundleProvider: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        launchTimeout: TimeInterval = 5,
        launchPollInterval: TimeInterval = 0.1,
        launchClock: @escaping () -> Date = Date.init,
        launchPollSleeper: @escaping (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) {
        self.snapshotStore = snapshotStore
        self.trustChecker = trustChecker
        self.windowApplier = windowApplier
        self.matchPlanner = matchPlanner
        self.displayResolver = displayResolver
        self.applicationLauncher = applicationLauncher
        self.targetOpener = targetOpener
        self.browserTabCapturer = browserTabCapturer
        self.applicationActivator = applicationActivator
        self.telemetryLogger = telemetryLogger
        self.discoveredApplicationsProvider = discoveredApplicationsProvider ?? {
            try windowDiscoveryEngine.discoverRunningWindows()
        }
        self.runningApplicationBundleProvider = runningApplicationBundleProvider
        self.launchTimeout = launchTimeout
        self.launchPollInterval = launchPollInterval
        self.launchClock = launchClock
        self.launchPollSleeper = launchPollSleeper
    }

    func restoreSnapshot(id: UUID) async throws -> RestoreResult {
        guard trustChecker.isTrusted() else {
            telemetryLogger.log(
                .restoreFailed(
                    snapshotID: id,
                    error: RestoreEngineError.accessibilityPermissionDenied
                )
            )
            throw RestoreEngineError.accessibilityPermissionDenied
        }

        let snapshot: Snapshot
        do {
            snapshot = try snapshotStore.loadSnapshot(id: id)
        } catch {
            telemetryLogger.log(.restoreFailed(snapshotID: id, error: error))
            throw error
        }

        let currentDisplayState = displayResolver.captureDisplayState()
        var discoveredApplications: [DiscoveredApplication]
        do {
            discoveredApplications = try discoveredApplicationsProvider()
        } catch {
            telemetryLogger.log(
                .restoreFailed(
                    snapshotID: id,
                    error: error
                )
            )
            throw error
        }

        let initiallyRunningBundleIdentifiers = runningBundleIdentifiers(from: discoveredApplications)
        var requestedTargetCount = 0
        var targetIssues: [RestoreTargetIssue] = []
        var successfullyOpenedTargetBundleIdentifiers: Set<String> = []
        let initialOpenLocalTargets = OpenLocalTargetIndex(
            from: discoveredApplications
        )
        var openLocalTargets = initialOpenLocalTargets
        var openWebTargets = OpenWebTargetIndex()
        if snapshot.hasWebOpeningTargets {
            openWebTargets = OpenWebTargetIndex(
                captureResult: browserTabCapturer.captureTabs(
                    runningApplications: discoveredApplications.map {
                        RunningApplicationSnapshot(
                            bundleIdentifier: $0.bundleIdentifier,
                            processIdentifier: $0.pid,
                            localizedName: $0.localizedName
                        )
                    }
                ),
                discoveredApplications: discoveredApplications
            )
        }
        var expectedOpenedLocalTargetCounts: [String: [URL: Int]] = [:]
        var successfullyRequestedWebWindowIDs: Set<UUID> = []
        let initialWindowCountsByBundleIdentifier = windowCountsByBundleIdentifier(
            from: discoveredApplications
        )
        var expectedNewBrowserWindowCounts: [String: Int] = [:]

        for savedWindow in snapshot.windows {
            var validTargets: [WindowOpenTarget] = []

            for target in savedWindow.openingConfiguration.effectiveTargets {
                let validationIssue = target.kind == .webURL
                    ? webTargetValidationIssue(for: target)
                    : localTargetValidationIssue(for: target)
                if let validationIssue {
                    targetIssues.append(
                        RestoreTargetIssue(
                            windowID: savedWindow.id,
                            bundleIdentifier: savedWindow.bundleIdentifier,
                            windowTitle: savedWindow.windowTitle,
                            target: target,
                            reason: validationIssue
                        )
                    )
                } else {
                    validTargets.append(target)
                }
            }

            let bundleIdentifier = savedWindow.bundleIdentifier
            var targetsToOpen: [WindowOpenTarget] = []
            for target in validTargets {
                if target.kind == .webURL {
                    if !openWebTargets.consume(
                        target,
                        bundleIdentifier: bundleIdentifier
                    ) {
                        targetsToOpen.append(target)
                    }
                } else if !openLocalTargets.consume(
                    target,
                    bundleIdentifier: bundleIdentifier
                ) {
                    targetsToOpen.append(target)
                }
            }

            guard !targetsToOpen.isEmpty else {
                continue
            }

            let openRequests = RestoreTargetOpenRequestPlanner().requests(
                targets: targetsToOpen,
                bundleIdentifier: bundleIdentifier
            )
            for request in openRequests {
                let openResult = await targetOpener.open(
                    targets: request.targets,
                    bundleIdentifier: bundleIdentifier,
                    disposition: request.disposition
                )
                if openResult.wasSubmitted {
                    requestedTargetCount += request.targets.count
                }

                switch openResult {
                case .opened, .openedNewBrowserWindow:
                    successfullyOpenedTargetBundleIdentifiers.insert(bundleIdentifier)
                    let requestedLocalTargets = request.targets.filter {
                        $0.kind != .webURL && $0.url.isFileURL
                    }
                    if !requestedLocalTargets.isEmpty {
                        var expectedCounts = expectedOpenedLocalTargetCounts[
                            bundleIdentifier,
                            default: [:]
                        ]
                        for target in requestedLocalTargets {
                            let URL = target.url.standardizedFileURL
                            let baseline = initialOpenLocalTargets.occurrenceCount(
                                of: URL,
                                bundleIdentifier: bundleIdentifier
                            )
                            expectedCounts[URL] = (expectedCounts[URL] ?? baseline) + 1
                        }
                        expectedOpenedLocalTargetCounts[bundleIdentifier] = expectedCounts
                    }
                    if request.targets.contains(where: { $0.kind == .webURL }) {
                        successfullyRequestedWebWindowIDs.insert(savedWindow.id)
                        if openResult.createdNewBrowserWindow {
                            expectedNewBrowserWindowCounts[bundleIdentifier, default: 0] += 1
                        }
                    }
                case let .failed(reason):
                    targetIssues.append(contentsOf: request.targets.map { target in
                        RestoreTargetIssue(
                            windowID: savedWindow.id,
                            bundleIdentifier: bundleIdentifier,
                            windowTitle: savedWindow.windowTitle,
                            target: target,
                            reason: reason
                        )
                    })
                }
            }
        }

        let runningBundleIdentifiersAfterTargetRequests = runningBundleIdentifiers(
            from: discoveredApplications
        ).union(successfullyOpenedTargetBundleIdentifiers)
        let missingBundleIdentifiers = orderedSavedBundleIdentifiers(in: snapshot).filter {
            !runningBundleIdentifiersAfterTargetRequests.contains($0)
        }
        let requestedLaunchBundleIdentifiers = Set(
            missingBundleIdentifiers.filter {
                applicationLauncher.requestLaunch(bundleIdentifier: $0)
            }
        )
        let readinessBundleIdentifiers = successfullyOpenedTargetBundleIdentifiers
            .union(requestedLaunchBundleIdentifiers)

        if !readinessBundleIdentifiers.isEmpty {
            do {
                discoveredApplications = try await rediscoverApplicationsUntilRestoreReadiness(
                    snapshot: snapshot,
                    requestedBundleIdentifiers: readinessBundleIdentifiers,
                    expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
                    successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
                    initialWindowCountsByBundleIdentifier: initialWindowCountsByBundleIdentifier,
                    expectedNewBrowserWindowCounts: expectedNewBrowserWindowCounts
                )
            } catch {
                telemetryLogger.log(
                    .restoreFailed(
                        snapshotID: id,
                        error: error
                    )
                )
                throw error
            }
        }

        let liveWindowsByCandidateID = Self.liveWindowsByCandidateID(from: discoveredApplications)
        let plans = matchPlanner.plans(
            for: snapshot.windows,
            candidates: liveWindowsByCandidateID.map { $0.candidate },
            runningBundleIdentifiers: runningBundleIdentifiers(from: discoveredApplications),
            singletonFallbackBundleIdentifiers: initiallyRunningBundleIdentifiers
        )

        var restoredWindows = 0
        var skippedItems = plans.compactMap(\.skip)
        var downgradedItems: [RestoreDowngrade] = []
        var displayFallbacks: [DisplayFallbackEvent] = []
        var restoredWindowZOrderItems: [RestoreWindowZOrderItem] = []

        for plan in plans {
            guard let candidate = plan.candidate,
                  let liveWindow = liveWindowsByCandidateID.first(where: { $0.candidate.id == candidate.id })?.window else {
                continue
            }

            let restoreDisplayPlan = displayResolver.restorePlan(
                for: plan.savedWindow,
                from: snapshot.sourceDisplayState,
                to: currentDisplayState
            )
            let result = windowApplier.apply(
                savedWindow: plan.savedWindow,
                targetFrame: restoreDisplayPlan.targetFrame,
                to: liveWindow
            )
            if result.didRestore {
                restoredWindows += 1
                restoredWindowZOrderItems.append(
                    RestoreWindowZOrderItem(
                        savedWindow: plan.savedWindow,
                        processIdentifier: candidate.pid,
                        liveWindow: liveWindow
                    )
                )
                if let downgrade = result.downgrade {
                    downgradedItems.append(downgrade)
                }
                if let fallback = restoreDisplayPlan.fallback {
                    displayFallbacks.append(fallback)
                }
            } else {
                skippedItems.append(
                    RestoreSkip(
                        bundleIdentifier: plan.savedWindow.bundleIdentifier,
                        windowTitle: plan.savedWindow.windowTitle,
                        reason: result.failureReason ?? RestoreSkipReason.restoreFailed
                    )
                )
            }
        }

        RestoreWindowZOrderRestorer(
            windowApplier: windowApplier,
            applicationActivator: applicationActivator
        ).restore(restoredWindowZOrderItems)

        let restoreResult = RestoreResult(
            restoredWindows: restoredWindows,
            skippedItems: skippedItems,
            downgradedItems: downgradedItems,
            displayFallbacks: displayFallbacks,
            requestedTargetCount: requestedTargetCount,
            targetIssues: targetIssues
        )
        telemetryLogger.log(.restoreCompleted(snapshot: snapshot, result: restoreResult))
        return restoreResult
    }

    private func rediscoverApplicationsUntilRestoreReadiness(
        snapshot: Snapshot,
        requestedBundleIdentifiers: Set<String>,
        expectedOpenedLocalTargetCounts: [String: [URL: Int]],
        successfullyRequestedWebWindowIDs: Set<UUID>,
        initialWindowCountsByBundleIdentifier: [String: Int],
        expectedNewBrowserWindowCounts: [String: Int]
    ) async throws -> [DiscoveredApplication] {
        let deadline = launchClock().addingTimeInterval(launchTimeout)
        var discoveredApplications = try discoveredApplicationsProvider()

        if requestedApplicationsAreReady(
            snapshot: snapshot,
            requestedBundleIdentifiers: requestedBundleIdentifiers,
            expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
            successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
            initialWindowCountsByBundleIdentifier: initialWindowCountsByBundleIdentifier,
            expectedNewBrowserWindowCounts: expectedNewBrowserWindowCounts,
            discoveredApplications: discoveredApplications
        ) {
            return discoveredApplications
        }

        while launchClock() < deadline {
            await launchPollSleeper(launchPollInterval)
            discoveredApplications = try discoveredApplicationsProvider()

            if requestedApplicationsAreReady(
                snapshot: snapshot,
                requestedBundleIdentifiers: requestedBundleIdentifiers,
                expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
                successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
                initialWindowCountsByBundleIdentifier: initialWindowCountsByBundleIdentifier,
                expectedNewBrowserWindowCounts: expectedNewBrowserWindowCounts,
                discoveredApplications: discoveredApplications
            ) {
                return discoveredApplications
            }
        }

        return discoveredApplications
    }

    private func requestedApplicationsAreReady(
        snapshot: Snapshot,
        requestedBundleIdentifiers: Set<String>,
        expectedOpenedLocalTargetCounts: [String: [URL: Int]],
        successfullyRequestedWebWindowIDs: Set<UUID>,
        initialWindowCountsByBundleIdentifier: [String: Int],
        expectedNewBrowserWindowCounts: [String: Int],
        discoveredApplications: [DiscoveredApplication]
    ) -> Bool {
        let discoveredTargets = OpenLocalTargetIndex(
            from: discoveredApplications
        )
        let localTargetBundleIdentifiers = Set(expectedOpenedLocalTargetCounts.keys)
        let localTargetRequestsAreReady = expectedOpenedLocalTargetCounts.allSatisfy {
            bundleIdentifier, expectedCounts in
            expectedCounts.allSatisfy { URL, expectedCount in
                discoveredTargets.occurrenceCount(
                    of: URL,
                    bundleIdentifier: bundleIdentifier
                ) >= expectedCount
            }
        }
        guard localTargetRequestsAreReady else {
            return false
        }

        let discoveredWindowCounts = windowCountsByBundleIdentifier(
            from: discoveredApplications
        )
        let newBrowserWindowRequestsAreReady = expectedNewBrowserWindowCounts.allSatisfy {
            bundleIdentifier, expectedCount in
            let baselineCount = initialWindowCountsByBundleIdentifier[bundleIdentifier, default: 0]
            return discoveredWindowCounts[bundleIdentifier, default: 0] >=
                baselineCount + expectedCount
        }
        guard newBrowserWindowRequestsAreReady else {
            return false
        }

        let liveWindowsByCandidateID = Self.liveWindowsByCandidateID(from: discoveredApplications)
        let runningBundleIdentifiers = runningBundleIdentifiers(from: discoveredApplications)
        let requestedWebWindows = snapshot.windows.filter {
            successfullyRequestedWebWindowIDs.contains($0.id)
        }
        if !requestedWebWindows.isEmpty {
            let plans = matchPlanner.plans(
                for: requestedWebWindows,
                candidates: liveWindowsByCandidateID.map(\.candidate),
                runningBundleIdentifiers: runningBundleIdentifiers
            )
            guard plans.allSatisfy({ $0.candidate != nil }) else {
                return false
            }
        }

        let webTargetBundleIdentifiers = Set(
            requestedWebWindows.map(\.bundleIdentifier)
        )
        let targetBundleIdentifiers = localTargetBundleIdentifiers
            .union(webTargetBundleIdentifiers)
        let launchOnlyBundleIdentifiers = requestedBundleIdentifiers
            .subtracting(targetBundleIdentifiers)
        guard !launchOnlyBundleIdentifiers.isEmpty else {
            return true
        }

        let savedWindowsForRequests = snapshot.windows.filter {
            launchOnlyBundleIdentifiers.contains($0.bundleIdentifier)
        }
        let plans = matchPlanner.plans(
            for: savedWindowsForRequests,
            candidates: liveWindowsByCandidateID.map(\.candidate),
            runningBundleIdentifiers: runningBundleIdentifiers
        )
        let bundleIdentifiersWithMatchedWindows = Set(plans.compactMap { plan in
            plan.candidate == nil ? nil : plan.savedWindow.bundleIdentifier
        })

        return launchOnlyBundleIdentifiers.isSubset(of: bundleIdentifiersWithMatchedWindows)
    }

    private func localTargetValidationIssue(
        for target: WindowOpenTarget
    ) -> RestoreTargetIssueReason? {
        guard target.url.isFileURL else {
            return .targetKindMismatch
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: target.url.path,
            isDirectory: &isDirectory
        ) else {
            return .missingTarget
        }

        let targetIsDirectory = target.kind == .folder
        return targetIsDirectory == isDirectory.boolValue ? nil : .targetKindMismatch
    }

    private func webTargetValidationIssue(
        for target: WindowOpenTarget
    ) -> RestoreTargetIssueReason? {
        WindowOpenTargetValidator().webTarget(url: target.url) == nil
            ? .unsupportedURL
            : nil
    }

    private func orderedSavedBundleIdentifiers(in snapshot: Snapshot) -> [String] {
        var seenBundleIdentifiers: Set<String> = []
        return snapshot.windows.compactMap { window in
            seenBundleIdentifiers.insert(window.bundleIdentifier).inserted
                ? window.bundleIdentifier
                : nil
        }
    }

    private func runningBundleIdentifiers(
        from discoveredApplications: [DiscoveredApplication]
    ) -> Set<String> {
        runningApplicationBundleProvider().union(discoveredApplications.map(\.bundleIdentifier))
    }

    private func windowCountsByBundleIdentifier(
        from discoveredApplications: [DiscoveredApplication]
    ) -> [String: Int] {
        Dictionary(grouping: discoveredApplications, by: \.bundleIdentifier)
            .mapValues { applications in
                applications.reduce(0) { $0 + $1.windows.count }
            }
    }

    private static func liveWindowsByCandidateID(
        from applications: [DiscoveredApplication]
    ) -> [(candidate: RestoreWindowCandidate, window: DiscoveredWindow)] {
        var nextIdentifier = 0
        var pairs: [(candidate: RestoreWindowCandidate, window: DiscoveredWindow)] = []

        for application in applications {
            for window in application.windows {
                pairs.append(
                    (
                        RestoreWindowCandidate(
                            id: nextIdentifier,
                            bundleIdentifier: application.bundleIdentifier,
                            pid: application.pid,
                            documentURLs: window.documentURLs,
                            title: window.title,
                            role: window.role,
                            subrole: window.subrole,
                            frame: window.frame
                        ),
                        window
                    )
                )
                nextIdentifier += 1
            }
        }

        return pairs
    }
}

struct RestoreWindowZOrderItem {
    let savedWindow: WindowRecord
    let processIdentifier: pid_t
    let liveWindow: DiscoveredWindow
}

struct RestoreWindowZOrderPlanner {
    func raiseOrder(for items: [RestoreWindowZOrderItem]) -> [RestoreWindowZOrderItem] {
        items.filter { item in
            item.savedWindow.zOrderHint != nil &&
            !item.savedWindow.isMinimized &&
            item.savedWindow.isVisible
        }
        .sorted { lhs, rhs in
            guard let lhsHint = lhs.savedWindow.zOrderHint,
                  let rhsHint = rhs.savedWindow.zOrderHint else {
                return false
            }

            if lhsHint != rhsHint {
                return lhsHint > rhsHint
            }

            return lhs.savedWindow.id.uuidString > rhs.savedWindow.id.uuidString
        }
    }

    func frontmostItem(for items: [RestoreWindowZOrderItem]) -> RestoreWindowZOrderItem? {
        raiseOrder(for: items).last
    }
}

struct RestoreWindowZOrderRestorer {
    let planner: RestoreWindowZOrderPlanner
    let windowApplier: RestoreWindowApplying
    let applicationActivator: RestoreApplicationActivating

    init(
        planner: RestoreWindowZOrderPlanner = RestoreWindowZOrderPlanner(),
        windowApplier: RestoreWindowApplying,
        applicationActivator: RestoreApplicationActivating
    ) {
        self.planner = planner
        self.windowApplier = windowApplier
        self.applicationActivator = applicationActivator
    }

    func restore(_ items: [RestoreWindowZOrderItem]) {
        let raiseOrder = planner.raiseOrder(for: items)
        for item in raiseOrder {
            windowApplier.raise(item.liveWindow)
        }

        guard let frontmostItem = raiseOrder.last else {
            return
        }

        applicationActivator.activate(processIdentifier: frontmostItem.processIdentifier)
        _ = windowApplier.focus(frontmostItem.liveWindow)
    }
}

protocol RestoreApplicationActivating {
    @discardableResult
    func activate(processIdentifier: pid_t) -> Bool
}

protocol RestoreApplicationLaunching {
    @discardableResult
    func requestLaunch(bundleIdentifier: String) -> Bool
}

enum RestoreTargetOpenResult {
    case opened
    case openedNewBrowserWindow
    case failed(RestoreTargetIssueReason)

    var wasSubmitted: Bool {
        switch self {
        case .opened, .openedNewBrowserWindow, .failed(.openRequestFailed):
            return true
        case .failed:
            return false
        }
    }

    var createdNewBrowserWindow: Bool {
        if case .openedNewBrowserWindow = self {
            return true
        }
        return false
    }
}

enum RestoreTargetOpenDisposition: Equatable {
    case applicationDefault
    case newWindow
    case newBrowserWindow
}

struct RestoreTargetOpenRequest {
    let targets: [WindowOpenTarget]
    let disposition: RestoreTargetOpenDisposition
}

struct RestoreTargetOpenRequestPlanner {
    private static let codeBasedEditorBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.google.antigravity-ide"
    ]

    func requests(
        targets: [WindowOpenTarget],
        bundleIdentifier: String
    ) -> [RestoreTargetOpenRequest] {
        guard !targets.isEmpty else {
            return []
        }

        let indexedLocalTargets = targets.enumerated().filter {
            $0.element.kind != .webURL
        }
        let indexedWebTargets = targets.enumerated().filter {
            $0.element.kind == .webURL
        }
        var indexedRequests: [(index: Int, request: RestoreTargetOpenRequest)] = []

        if Self.codeBasedEditorBundleIdentifiers.contains(bundleIdentifier),
           let firstLocalTarget = indexedLocalTargets.first {
            indexedRequests.append((
                firstLocalTarget.offset,
                RestoreTargetOpenRequest(
                    targets: indexedLocalTargets.map(\.element),
                    disposition: .newWindow
                )
            ))
        } else {
            indexedRequests.append(contentsOf: indexedLocalTargets.map {
                (
                    $0.offset,
                    RestoreTargetOpenRequest(
                        targets: [$0.element],
                        disposition: .applicationDefault
                    )
                )
            })
        }

        if let firstWebTarget = indexedWebTargets.first {
            let browserCreatesDistinctWindow = BrowserAutomationBrowser.allCases.contains {
                $0.bundleIdentifier == bundleIdentifier
            }
            indexedRequests.append((
                firstWebTarget.offset,
                RestoreTargetOpenRequest(
                    targets: indexedWebTargets.map(\.element),
                    disposition: browserCreatesDistinctWindow
                        ? .newBrowserWindow
                        : .applicationDefault
                )
            ))
        }

        return indexedRequests
            .sorted { $0.index < $1.index }
            .map(\.request)
    }
}

protocol RestoreTargetOpening {
    func open(
        targets: [WindowOpenTarget],
        bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition
    ) async -> RestoreTargetOpenResult
}

struct NSWorkspaceRestoreTargetOpener: RestoreTargetOpening {
    private let applicationURLProvider: (String) -> URL?
    private let commandRunner: (URL, [String]) async -> Bool
    private let browserWindowOpener: BrowserWindowOpening
    private let workspaceOpener:
        ([URL], URL, NSWorkspace.OpenConfiguration) async -> Bool

    init(
        workspace: NSWorkspace = .shared,
        applicationURLProvider: ((String) -> URL?)? = nil,
        commandRunner: @escaping (URL, [String]) async -> Bool = Self.runCommand,
        browserWindowOpener: BrowserWindowOpening? = nil,
        workspaceOpener:
            (([URL], URL, NSWorkspace.OpenConfiguration) async -> Bool)? = nil
    ) {
        self.applicationURLProvider = applicationURLProvider ?? {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        self.commandRunner = commandRunner
        self.browserWindowOpener = browserWindowOpener ??
            BrowserAutomationWindowOpener(workspace: workspace)
        self.workspaceOpener = workspaceOpener ?? {
            urls,
            applicationURL,
            configuration in
            await withCheckedContinuation { continuation in
                workspace.open(
                    urls,
                    withApplicationAt: applicationURL,
                    configuration: configuration
                ) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    func open(
        targets: [WindowOpenTarget],
        bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition
    ) async -> RestoreTargetOpenResult {
        guard let applicationURL = applicationURLProvider(bundleIdentifier) else {
            return .failed(.applicationUnavailable)
        }

        if disposition == .newBrowserWindow,
           let browser = BrowserAutomationBrowser.allCases.first(
               where: { $0.bundleIdentifier == bundleIdentifier }
           ) {
            let result = await browserWindowOpener.openNewWindow(
                targets: targets,
                browser: browser
            )
            if case .opened = result {
                return .openedNewBrowserWindow
            }
        }

        if disposition == .newWindow {
            guard let commandURL = codeBasedEditorCommandURL(
                applicationURL: applicationURL,
                bundleIdentifier: bundleIdentifier
            ) else {
                return .failed(.openRequestFailed)
            }
            let didOpen = await commandRunner(
                commandURL,
                ["--new-window"] + targets.map { $0.url.path }
            )
            return didOpen ? .opened : .failed(.openRequestFailed)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
        configuration.promptsUserIfNeeded = true

        var deliveryURLs = targets.map(\.url)
        if bundleIdentifier == BrowserAutomationBrowser.chrome.bundleIdentifier,
           targets.allSatisfy({ $0.kind == .webURL }) {
            // Chrome renders macOS URL batches in reverse tab order.
            deliveryURLs.reverse()
        }

        let didOpen = await workspaceOpener(
            deliveryURLs,
            applicationURL,
            configuration
        )
        return didOpen ? .opened : .failed(.openRequestFailed)
    }

    private func codeBasedEditorCommandURL(
        applicationURL: URL,
        bundleIdentifier: String
    ) -> URL? {
        let commandName: String
        switch bundleIdentifier {
        case "com.microsoft.VSCode":
            commandName = "code"
        case "com.microsoft.VSCodeInsiders":
            commandName = "code-insiders"
        case "com.google.antigravity-ide":
            commandName = "antigravity-ide"
        default:
            return nil
        }

        let commandURL = applicationURL
            .appendingPathComponent("Contents/Resources/app/bin")
            .appendingPathComponent(commandName)
        return FileManager.default.isExecutableFile(atPath: commandURL.path)
            ? commandURL
            : nil
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String]
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}

struct NSWorkspaceRestoreApplicationLauncher: RestoreApplicationLaunching {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func requestLaunch(bundleIdentifier: String) -> Bool {
        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
        configuration.promptsUserIfNeeded = true

        workspace.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
        return true
    }
}

struct NSWorkspaceRestoreApplicationActivator: RestoreApplicationActivating {
    func activate(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ) else {
            return false
        }

        NSApp.yieldActivation(to: application)
        return application.activate(options: [])
    }
}

private struct OpenLocalTargetIndex {
    private var windowsByBundleIdentifier: [String: [OpenLocalWindowEvidence]] = [:]

    init(from applications: [DiscoveredApplication]) {
        for application in applications {
            for window in application.windows {
                windowsByBundleIdentifier[application.bundleIdentifier, default: []]
                    .append(OpenLocalWindowEvidence(window: window))
            }
        }
    }

    mutating func consume(
        _ target: WindowOpenTarget,
        bundleIdentifier: String
    ) -> Bool {
        guard target.kind != .webURL, target.url.isFileURL else {
            return false
        }

        let URL = target.url.standardizedFileURL
        guard var windows = windowsByBundleIdentifier[bundleIdentifier] else {
            return false
        }

        for index in windows.indices where windows[index].consume(URL) {
            windowsByBundleIdentifier[bundleIdentifier] = windows
            return true
        }
        return false
    }

    func occurrenceCount(
        of url: URL,
        bundleIdentifier: String
    ) -> Int {
        let URL = url.standardizedFileURL
        return windowsByBundleIdentifier[bundleIdentifier, default: []]
            .reduce(0) { $0 + $1.occurrenceCount(of: URL) }
    }
}

private struct OpenLocalWindowEvidence {
    private var urlCounts: [URL: Int] = [:]
    private var titles: [String]

    init(window: DiscoveredWindow) {
        for URL in window.documentURLs where URL.isFileURL {
            urlCounts[URL.standardizedFileURL, default: 0] += 1
        }
        titles = window.documentTitles
    }

    mutating func consume(_ URL: URL) -> Bool {
        if let count = urlCounts[URL], count > 0 {
            urlCounts[URL] = count - 1
            _ = removeMatchingTitle(for: URL)
            return true
        }

        return removeMatchingTitle(for: URL)
    }

    func occurrenceCount(of URL: URL) -> Int {
        let URLCount = urlCounts[URL] ?? 0
        let titleCount = titles.count { $0.referencesLocalURL(URL) }
        return max(URLCount, titleCount)
    }

    private mutating func removeMatchingTitle(for URL: URL) -> Bool {
        guard let index = titles
            .firstIndex(where: { $0.referencesLocalURL(URL) }) else {
            return false
        }

        titles.remove(at: index)
        return true
    }
}

private struct OpenWebTargetIndex {
    private var countsByBundleIdentifier: [String: [URL: Int]] = [:]

    init(
        captureResult: BrowserTabCaptureResult = .empty,
        discoveredApplications: [DiscoveredApplication] = []
    ) {
        let validator = WindowOpenTargetValidator()
        let automatedBundleIdentifiers = Set(
            captureResult.windows.map { $0.browser.bundleIdentifier }
        )

        for window in captureResult.windows {
            for tab in window.tabs {
                guard let URL = validator.webTarget(url: tab.URL)?.url else {
                    continue
                }
                countsByBundleIdentifier[
                    window.browser.bundleIdentifier,
                    default: [:]
                ][URL, default: 0] += 1
            }
        }

        for application in discoveredApplications
            where !automatedBundleIdentifiers.contains(application.bundleIdentifier) {
            for window in application.windows {
                for documentURL in window.documentURLs {
                    guard let URL = validator.webTarget(url: documentURL)?.url else {
                        continue
                    }
                    countsByBundleIdentifier[
                        application.bundleIdentifier,
                        default: [:]
                    ][URL, default: 0] += 1
                }
            }
        }
    }

    mutating func consume(
        _ target: WindowOpenTarget,
        bundleIdentifier: String
    ) -> Bool {
        guard target.kind == .webURL,
              let URL = WindowOpenTargetValidator().webTarget(url: target.url)?.url,
              let count = countsByBundleIdentifier[bundleIdentifier]?[URL],
              count > 0 else {
            return false
        }

        countsByBundleIdentifier[bundleIdentifier]?[URL] = count - 1
        return true
    }
}

private extension Snapshot {
    var hasWebOpeningTargets: Bool {
        windows.contains { window in
            window.openingConfiguration.effectiveTargets.contains {
                $0.kind == .webURL
            }
        }
    }
}

private extension String {
    func referencesLocalURL(_ url: URL) -> Bool {
        let path = url.path
        let abbreviatedPath = (path as NSString).abbreviatingWithTildeInPath

        return [path, abbreviatedPath].contains { candidate in
            ranges(of: candidate).contains { range in
                range.upperBound == endIndex ||
                self[range.upperBound].isLocalPathReferenceBoundary
            }
        }
    }

    func ranges(of value: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex

        while let range = range(of: value, range: searchRange) {
            result.append(range)
            searchRange = range.upperBound..<endIndex
        }

        return result
    }
}

private extension Character {
    var isLocalPathReferenceBoundary: Bool {
        isWhitespace || [":", "|", ")", "]", "}", "—", "–"].contains(self)
    }
}

struct RestoreWindowCandidate {
    let id: Int
    let bundleIdentifier: String
    let pid: pid_t
    let documentURLs: [URL]
    let title: String?
    let role: String
    let subrole: String?
    let frame: CGRect
}

struct RestoreWindowPlan {
    let savedWindow: WindowRecord
    let candidate: RestoreWindowCandidate?
    let skip: RestoreSkip?
}

struct RestoreWindowMatchPlanner {
    func plans(
        for savedWindows: [WindowRecord],
        candidates: [RestoreWindowCandidate],
        runningBundleIdentifiers: Set<String>? = nil,
        singletonFallbackBundleIdentifiers: Set<String> = []
    ) -> [RestoreWindowPlan] {
        let runningBundleIdentifiers = runningBundleIdentifiers ?? Set(candidates.map(\.bundleIdentifier))
        var plans = Array<RestoreWindowPlan?>(repeating: nil, count: savedWindows.count)
        var matchableSavedWindows: [String: [(index: Int, window: WindowRecord)]] = [:]

        for (index, savedWindow) in savedWindows.enumerated() {
            guard runningBundleIdentifiers.contains(savedWindow.bundleIdentifier) else {
                plans[index] = RestoreWindowPlan(
                    savedWindow: savedWindow,
                    candidate: nil,
                    skip: RestoreSkip(
                        bundleIdentifier: savedWindow.bundleIdentifier,
                        windowTitle: savedWindow.windowTitle,
                        reason: RestoreSkipReason.appNotRunning
                    )
                )
                continue
            }

            matchableSavedWindows[savedWindow.bundleIdentifier, default: []].append((index, savedWindow))
        }

        for (bundleIdentifier, savedWindowsForBundle) in matchableSavedWindows {
            let candidatesForBundle = candidates.filter {
                $0.bundleIdentifier == bundleIdentifier
            }
            let assignments: [Int: RestoreWindowCandidate]
            if singletonFallbackBundleIdentifiers.contains(bundleIdentifier),
               savedWindowsForBundle.count == 1,
               candidatesForBundle.count == 1,
               let savedWindow = savedWindowsForBundle.first,
               let candidate = candidatesForBundle.first,
               candidate.role == savedWindow.window.role,
               candidate.subrole == savedWindow.window.subrole {
                assignments = [savedWindow.index: candidate]
            } else {
                assignments = bestAssignments(
                    for: savedWindowsForBundle,
                    from: candidatesForBundle
                )
            }

            for (index, savedWindow) in savedWindowsForBundle {
                if let candidate = assignments[index] {
                    plans[index] = RestoreWindowPlan(
                        savedWindow: savedWindow,
                        candidate: candidate,
                        skip: nil
                    )
                } else {
                    plans[index] = RestoreWindowPlan(
                        savedWindow: savedWindow,
                        candidate: nil,
                        skip: RestoreSkip(
                            bundleIdentifier: savedWindow.bundleIdentifier,
                            windowTitle: savedWindow.windowTitle,
                            reason: RestoreSkipReason.windowNotFound
                        )
                    )
                }
            }
        }

        return savedWindows.enumerated().map { index, savedWindow in
            plans[index] ?? RestoreWindowPlan(
                savedWindow: savedWindow,
                candidate: nil,
                skip: RestoreSkip(
                    bundleIdentifier: savedWindow.bundleIdentifier,
                    windowTitle: savedWindow.windowTitle,
                    reason: RestoreSkipReason.windowNotFound
                )
            )
        }
    }

    private func bestAssignments(
        for savedWindows: [(index: Int, window: WindowRecord)],
        from candidates: [RestoreWindowCandidate]
    ) -> [Int: RestoreWindowCandidate] {
        let scoredMatches = savedWindows.flatMap { savedWindow in
            candidates.compactMap { candidate in
                scoredMatch(
                    savedIndex: savedWindow.index,
                    savedWindow: savedWindow.window,
                    candidate: candidate
                )
            }
        }
        .sorted()

        var assignedSavedWindowIndexes = Set<Int>()
        var assignedCandidateIDs = Set<Int>()
        var assignments: [Int: RestoreWindowCandidate] = [:]

        for scoredMatch in scoredMatches {
            guard !assignedSavedWindowIndexes.contains(scoredMatch.savedIndex),
                  !assignedCandidateIDs.contains(scoredMatch.candidate.id) else {
                continue
            }

            assignedSavedWindowIndexes.insert(scoredMatch.savedIndex)
            assignedCandidateIDs.insert(scoredMatch.candidate.id)
            assignments[scoredMatch.savedIndex] = scoredMatch.candidate
        }

        return assignments
    }

    private func scoredMatch(
        savedIndex: Int,
        savedWindow: WindowRecord,
        candidate: RestoreWindowCandidate
    ) -> RestoreWindowScoredMatch? {
        let savedFrame = savedWindow.frame.cgRect
        let distance = candidate.frame.restoreDistance(to: savedFrame)
        let pidMatches = candidate.pid == savedWindow.pidAtCapture
        let validator = WindowOpenTargetValidator()
        let savedTargetURLs = Set(
            savedWindow.openingConfiguration.effectiveTargets.compactMap { target in
                switch target.kind {
                case .file, .folder:
                    return target.url.isFileURL
                        ? target.url.standardizedFileURL
                        : nil
                case .webURL:
                    return validator.webTarget(url: target.url)?.url
                }
            }
        )
        let candidateTargetURLs = Set(
            candidate.documentURLs.compactMap { url in
                url.isFileURL
                    ? url.standardizedFileURL
                    : validator.webTarget(url: url)?.url
            }
        )
        let targetMatches = !savedTargetURLs.isDisjoint(with: candidateTargetURLs)
        let savedTitle = savedWindow.windowTitle?.nonEmptyRestoreValue
        let titleMatches = savedTitle != nil &&
            candidate.title?.nonEmptyRestoreValue == savedTitle
        let roleMatches = candidate.role == savedWindow.role &&
            candidate.subrole == savedWindow.subrole
        let plausibleFrame = candidate.frame.isPlausibleRoleRestoreMatch(to: savedFrame)

        guard pidMatches || targetMatches || titleMatches || (roleMatches && plausibleFrame) else {
            return nil
        }

        var score = 0
        if pidMatches {
            score += 1_000
        }
        if targetMatches {
            score += 2_000
        }
        if titleMatches {
            score += 700
        }
        if roleMatches {
            score += 250
        }
        if plausibleFrame {
            score += 150
        }
        score += candidate.frame.restoreSimilarityScore(to: savedFrame)

        return RestoreWindowScoredMatch(
            savedIndex: savedIndex,
            candidate: candidate,
            score: score,
            distance: distance
        )
    }
}

private struct RestoreWindowScoredMatch: Comparable {
    let savedIndex: Int
    let candidate: RestoreWindowCandidate
    let score: Int
    let distance: CGFloat

    static func == (lhs: RestoreWindowScoredMatch, rhs: RestoreWindowScoredMatch) -> Bool {
        lhs.savedIndex == rhs.savedIndex &&
            lhs.candidate.id == rhs.candidate.id &&
            lhs.score == rhs.score &&
            lhs.distance == rhs.distance
    }

    static func < (lhs: RestoreWindowScoredMatch, rhs: RestoreWindowScoredMatch) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        if lhs.savedIndex != rhs.savedIndex {
            return lhs.savedIndex < rhs.savedIndex
        }

        return lhs.candidate.id < rhs.candidate.id
    }
}

protocol RestoreWindowApplying {
    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) -> RestoreWindowApplyResult

    @discardableResult
    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult
}

struct RestoreWindowApplyResult {
    let didRestore: Bool
    let downgrade: RestoreDowngrade?
    let failureReason: String?

    static func restored(downgrade: RestoreDowngrade? = nil) -> RestoreWindowApplyResult {
        RestoreWindowApplyResult(
            didRestore: true,
            downgrade: downgrade,
            failureReason: nil
        )
    }

    static func failed(reason: String) -> RestoreWindowApplyResult {
        RestoreWindowApplyResult(
            didRestore: false,
            downgrade: nil,
            failureReason: reason
        )
    }
}

struct RestoreWindowFocusResult {
    let didRaise: Bool
    let didSetMain: Bool
    let didSetFocused: Bool
}

struct AXRestoreWindowApplier: RestoreWindowApplying {
    private let attributeReader: AXAttributeReader

    init(attributeReader: AXAttributeReader = AXAttributeReader()) {
        self.attributeReader = attributeReader
    }

    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) -> RestoreWindowApplyResult {
        if discoveredWindow.isMinimized,
           !attributeReader.setBool(
            false,
            on: discoveredWindow.axElement,
            attribute: kAXMinimizedAttribute as CFString
           ) {
            return .failed(reason: RestoreSkipReason.restoreFailed)
        }

        guard attributeReader.setPoint(
            targetFrame.origin,
            on: discoveredWindow.axElement,
            attribute: kAXPositionAttribute as CFString
        ) else {
            return .failed(reason: RestoreSkipReason.restoreFailed)
        }

        guard attributeReader.setSize(
            targetFrame.size,
            on: discoveredWindow.axElement,
            attribute: kAXSizeAttribute as CFString
        ) else {
            return .failed(reason: RestoreSkipReason.restoreFailed)
        }

        let downgrade = fullscreenDowngrade(for: savedWindow)
        return .restored(downgrade: downgrade)
    }

    @discardableResult
    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool {
        attributeReader.performAction(
            kAXRaiseAction as CFString,
            on: discoveredWindow.axElement
        )
    }

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult {
        let didRaise = attributeReader.performAction(
            kAXRaiseAction as CFString,
            on: discoveredWindow.axElement
        )
        let didSetMain = attributeReader.setBool(
            true,
            on: discoveredWindow.axElement,
            attribute: kAXMainAttribute as CFString
        )
        let didSetFocused = attributeReader.setBool(
            true,
            on: discoveredWindow.axElement,
            attribute: kAXFocusedAttribute as CFString
        )

        return RestoreWindowFocusResult(
            didRaise: didRaise,
            didSetMain: didSetMain,
            didSetFocused: didSetFocused
        )
    }

    private func fullscreenDowngrade(for savedWindow: WindowRecord) -> RestoreDowngrade? {
        guard savedWindow.isFullscreen else {
            return nil
        }

        return RestoreDowngrade(
            bundleIdentifier: savedWindow.bundleIdentifier,
            windowTitle: savedWindow.windowTitle,
            reason: "fullscreen restored as standard window"
        )
    }
}

enum RestoreSkipReason {
    static let appNotRunning = "app not running"
    static let windowNotFound = "window not found"
    static let restoreFailed = "restore failed"
}

private extension CGRect {
    func restoreDistance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) +
        abs(minY - other.minY) +
        abs(width - other.width) +
        abs(height - other.height)
    }

    func restoreSimilarityScore(to savedFrame: CGRect) -> Int {
        let comparisonBasis = Swift.max(savedFrame.width + savedFrame.height, 1)
        let distanceRatio = Swift.min(restoreDistance(to: savedFrame) / comparisonBasis, 1)

        return Int((1 - distanceRatio) * 100)
    }

    func isPlausibleRoleRestoreMatch(to savedFrame: CGRect) -> Bool {
        abs(minX - savedFrame.minX) <= restoreRoleMatchOriginTolerance &&
        abs(minY - savedFrame.minY) <= restoreRoleMatchOriginTolerance &&
        abs(width - savedFrame.width) <= savedFrame.width.restoreSizeTolerance &&
        abs(height - savedFrame.height) <= savedFrame.height.restoreSizeTolerance
    }
}

private extension CGFloat {
    var restoreSizeTolerance: CGFloat {
        Swift.max(abs(self) * restoreRoleMatchSizeRatioTolerance, restoreRoleMatchMinimumSizeTolerance)
    }
}

private extension String {
    var nonEmptyRestoreValue: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
