import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

private let restoreRoleMatchOriginTolerance: CGFloat = 160
private let restoreRoleMatchSizeRatioTolerance: CGFloat = 0.25
private let restoreRoleMatchMinimumSizeTolerance: CGFloat = 80
private let restoreFrameVerificationTolerance: CGFloat = 2
private let restoreWindowApplyAttemptLimit = 4
private let restoreWindowSettleNanoseconds: UInt64 = 100_000_000

enum RestoreEngineError: LocalizedError {
    case accessibilityPermissionDenied
    case inspectionNotReturned

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility access is required to restore layouts."
        case .inspectionNotReturned:
            return "An inspected window could not be returned to its original desktop and position."
        }
    }
}

private struct RestoreReadinessResult {
    let discoveryResult: WindowDiscoveryResult
    let timedOutWindowIDs: Set<UUID>
}

private enum RestoreWindowInspectionOutcome {
    case unchanged
    case confirmed(WindowDiscoveryResult, RestoreRecoveredWindow)
    case returned(WindowDiscoveryResult, ruledOut: Bool)
    case blocked(String)
}

private struct RestoreRecoveredWindow {
    let pid: pid_t
    let windowID: CGWindowID
    let allowsRestore: Bool
    let inspection: (context: RestoreWindowInspection, frame: CGRect)?
}

private struct RestoreAppInstancePreparation {
    var processIdentifiers: [UUID: pid_t] = [:]
    var targetsByWindowID: [UUID: [WindowOpenTarget]] = [:]
    var blockedWindows: [UUID: String] = [:]
    var handledBundles: Set<String> = []
    var requestedBundles: Set<String> = []
    var requestedTargetCount = 0
    var targetIssues: [RestoreTargetIssue] = []
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
    private let discoveryResultProvider: (Set<String>?, pid_t?) throws -> WindowDiscoveryResult
    private let runningApplicationBundleProvider: () -> Set<String>
    private let launchTimeout: TimeInterval
    private let launchPollInterval: TimeInterval
    private let launchClock: () -> Date
    private let launchPollSleeper: (TimeInterval) async -> Void
    private let telemetryLogger: TelemetryLogging
    private let spaces: RestoreSpaceCoordinator

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
        applicationActivator: RestoreApplicationActivating = AXRestoreApplicationActivator(),
        telemetryLogger: TelemetryLogging = NoOpTelemetryLogger(),
        spaces: RestoreSpaceCoordinator = RestoreSpaceCoordinator(access: .unavailable),
        discoveredApplicationsProvider: (() throws -> [DiscoveredApplication])? = nil,
        discoveryResultProvider: (() throws -> WindowDiscoveryResult)? = nil,
        runningApplicationBundleProvider: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        launchTimeout: TimeInterval = 30,
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
        self.spaces = spaces
        if let discoveryResultProvider {
            self.discoveryResultProvider = { _, _ in try discoveryResultProvider() }
        } else if let discoveredApplicationsProvider {
            self.discoveryResultProvider = { _, _ in
                WindowDiscoveryResult(
                    applications: try discoveredApplicationsProvider(),
                    diagnostics: []
                )
            }
        } else {
            self.discoveryResultProvider = { bundles, pid in
                try windowDiscoveryEngine.discoverRunningWindowsWithDiagnostics(
                    bundleIdentifiers: bundles, processIdentifier: pid)
            }
        }
        self.runningApplicationBundleProvider = runningApplicationBundleProvider
        self.launchTimeout = launchTimeout
        self.launchPollInterval = launchPollInterval
        self.launchClock = launchClock
        self.launchPollSleeper = launchPollSleeper
    }

    func makeReadinessDeadline() -> Date {
        launchClock().addingTimeInterval(launchTimeout)
    }

    func restoreSnapshot(
        id: UUID,
        readinessDeadline: Date? = nil,
        progress: @MainActor (RestoreProgress) -> Void = { _ in }
    ) async throws -> RestoreResult {
        let deadline = readinessDeadline ?? makeReadinessDeadline()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var stageStartedAt = startedAt
        var stage: String? = "discovery"
        var timingsMilliseconds: [String: Double] = [:]
        func finishStage(next: String? = nil) {
            let now = ProcessInfo.processInfo.systemUptime
            if let stage {
                timingsMilliseconds[stage, default: 0] += (now - stageStartedAt) * 1_000
            }
            stage = next
            stageStartedAt = now
        }
        telemetryLogger.log(TelemetryLogEvent(name: "restore.started", snapshotID: id))
        defer {
            finishStage()
            timingsMilliseconds["total"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            telemetryLogger.log(TelemetryLogEvent(name: "restore.timing", snapshotID: id,
                timingsMilliseconds: timingsMilliseconds))
        }

        guard trustChecker.isTrusted() else {
            telemetryLogger.log(
                .restoreFailed(
                    snapshotID: id,
                    error: RestoreEngineError.accessibilityPermissionDenied
                )
            )
            throw RestoreEngineError.accessibilityPermissionDenied
        }

        if !Task.isCancelled { await progress(.discovering) }
        let snapshot: Snapshot
        do {
            snapshot = try snapshotStore.loadSnapshot(id: id)
        } catch {
            telemetryLogger.log(.restoreFailed(snapshotID: id, error: error))
            throw error
        }

        let savedBundleIdentifiers = Set(snapshot.windows.map(\.bundleIdentifier))
        let currentDisplayState = displayResolver.captureDisplayState()
        let spaceInventory = currentDisplayState.displays.isEmpty ? nil :
            spaces.access.inventory(currentDisplayState.displays.map(\.id))
        var discoveryResult: WindowDiscoveryResult
        do {
            discoveryResult = try discoveryResultProvider(savedBundleIdentifiers, nil)
        } catch {
            telemetryLogger.log(
                .restoreFailed(
                    snapshotID: id,
                    error: error
                )
            )
            throw error
        }
        let unexposedApplications = discoveryResult.unexposedApplications
        let initialCandidates = Self.liveWindowsByCandidateID(from: discoveryResult.applications).map(\.candidate)
        let initialMatches = matchPlanner.plans(for: snapshot.windows, candidates: initialCandidates)
        let exposedSavedIDs = Set(initialMatches.compactMap { plan -> UUID? in
            guard let candidate = plan.candidate else { return nil }
            let saved = plan.savedWindow
            let localTargets = saved.openingConfiguration.effectiveTargets.filter { $0.kind != .webURL }
            if !localTargets.isEmpty {
                return localTargets.allSatisfy(candidate.referencesLocalTarget) ? saved.id : nil
            }
            guard let title = saved.windowTitle?.nonEmptyValue, candidate.title?.nonEmptyValue == title,
                snapshot.windows.count(where: { $0.bundleIdentifier == saved.bundleIdentifier && $0.windowTitle?.nonEmptyValue == title }) == 1,
                initialCandidates.count(where: { $0.bundleIdentifier == saved.bundleIdentifier && $0.title?.nonEmptyValue == title }) == 1
            else { return nil }
            return saved.id
        })
        var recoveredWindowsBySavedID: [UUID: RestoreRecoveredWindow] = [:]
        var reservedRecoveryIDs: Set<CGWindowID> = []
        var ruledOutWindows: [UUID: (pid: pid_t, windowID: CGWindowID)] = [:]
        var inspectionBlockedWindows: [UUID: String] = [:]
        var didRediscoverRecoveredWindow = false
        finishStage(next: "spaceRecovery")
        if !Task.isCancelled { await progress(.recoveringWindows) }
        for savedWindow in snapshot.windows where !exposedSavedIDs.contains(savedWindow.id) {
            guard let spaceInventory, let recovery = RestoreCGWindowRecovery(
                ordinarySpaceIDs: spaceInventory.ordinarySpaceIDs,
                membership: spaces.access.membership
            ).candidate(
                for: savedWindow,
                savedWindows: snapshot.windows,
                applications: unexposedApplications,
                excludingWindowIDs: reservedRecoveryIDs
            ) else { continue }
            if savedWindow.openingConfiguration.effectiveTargets.isEmpty,
                initialMatches.contains(where: { $0.savedWindow.id == savedWindow.id && $0.candidate != nil }) {
                // An unrelated hidden singleton must not displace an existing position-only match.
                guard let title = savedWindow.windowTitle?.nonEmptyValue,
                    recovery.window.title?.nonEmptyValue == title else { continue }
            }
            let displayPlan = displayResolver.restorePlan(for: savedWindow, from: snapshot.sourceDisplayState, to: currentDisplayState)
            if RestoreCGWindowRecovery.requiresLocalTargetInspection(for: savedWindow) ||
                savedWindow.captureSignature.source == .coreGraphics ||
                snapshot.windows.count(where: { $0.bundleIdentifier == savedWindow.bundleIdentifier }) > 1 {
                // A title is only an inspection hint. Prove every resource before retaining the move.
                guard savedWindow.openingConfiguration.effectiveTargets.filter({ $0.kind != .webURL })
                    .allSatisfy({ localTargetValidationIssue(for: $0) == nil }) else { continue }
                switch try await inspectRecoveredWindow(savedWindow: savedWindow, pid: recovery.pid,
                    candidate: recovery.window, displayID: displayPlan.resolvedDisplayID, inventory: spaceInventory) {
                case .unchanged: break
                case let .confirmed(result, recovered):
                    discoveryResult = result
                    didRediscoverRecoveredWindow = true
                    recoveredWindowsBySavedID[savedWindow.id] = recovered
                    reservedRecoveryIDs.insert(recovery.window.windowID)
                case let .returned(result, ruledOut):
                    discoveryResult = result
                    didRediscoverRecoveredWindow = true
                    if ruledOut { ruledOutWindows[savedWindow.id] = (recovery.pid, recovery.window.windowID) }
                case let .blocked(reason): inspectionBlockedWindows[savedWindow.id] = reason
                }
                continue
            }
            let outcome = await spaces.prepare(
                windowID: recovery.window.windowID,
                displayID: displayPlan.resolvedDisplayID,
                inventory: spaceInventory,
                ordinaryWindow: true
            )
            recoveredWindowsBySavedID[savedWindow.id] = RestoreRecoveredWindow(pid: recovery.pid,
                windowID: recovery.window.windowID, allowsRestore: outcome == .moved || outcome == .alreadyVisible, inspection: nil)
            reservedRecoveryIDs.insert(recovery.window.windowID)
            AppLogger.restore.info("Space recovery bundle=\(savedWindow.bundleIdentifier, privacy: .public) windowID=\(recovery.window.windowID) outcome=\(outcome.rawValue, privacy: .public).")
            if outcome == .moved || outcome == .alreadyVisible {
                // Only normal AX discovery can authorize geometry, never the CG-only candidate.
                discoveryResult = try await rediscoverWindow(pid: recovery.pid, windowID: recovery.window.windowID).result
                didRediscoverRecoveredWindow = true
            }
        }
        if didRediscoverRecoveredWindow {
            // PID-scoped recovery must not replace the full layout's discovery context.
            do {
                discoveryResult = try discoveryResultProvider(savedBundleIdentifiers, nil)
            } catch {
                let blocked = await returnUnusedInspections(recoveredWindowsBySavedID,
                    plannedWindowIDs: [:], snapshot: snapshot, inventory: spaceInventory)
                let restoreError: Error = blocked.isEmpty ? error : RestoreEngineError.inspectionNotReturned
                telemetryLogger.log(.restoreFailed(snapshotID: id, error: restoreError))
                throw restoreError
            }
        }
        finishStage(next: "opening")
        if !Task.isCancelled { await progress(.opening) }
        let discoveredApplications = discoveryResult.applications
        var timedOutWindowIDs: Set<UUID> = []

        let initiallyRunningBundleIdentifiers = runningBundleIdentifiers(from: discoveredApplications)
        var appInstances = await prepareAppInstances(snapshot: snapshot, discoveryResult: discoveryResult,
            inspectionBlockedWindows: inspectionBlockedWindows)
        var requestedTargetCount = appInstances.requestedTargetCount
        var targetIssues = appInstances.targetIssues
        var successfullyOpenedTargetBundleIdentifiers: Set<String> = []
        let initialOpenLocalTargets = OpenLocalTargetIndex(
            from: discoveredApplications
        )
        var openLocalTargets = initialOpenLocalTargets
        var openWebTargets = OpenWebTargetIndex()
        var automatedBrowserBundles: Set<String> = []
        var reservedBrowserWindows: [String: Set<String>] = [:]
        if snapshot.hasWebOpeningTargets {
            let browserCapture = browserTabCapturer.captureTabs(
                runningApplications: discoveredApplications.map {
                    RunningApplicationSnapshot(bundleIdentifier: $0.bundleIdentifier,
                        applicationBundleURL: $0.applicationBundleURL,
                        processIdentifier: $0.pid, localizedName: $0.localizedName)
                })
            automatedBrowserBundles = Set(browserCapture.windows.map { $0.browser.bundleIdentifier })
            openWebTargets = OpenWebTargetIndex(
                captureResult: browserCapture,
                discoveredApplications: discoveredApplications
            )
        }
        var expectedOpenedLocalTargetCounts: [String: [URL: Int]] = [:]
        var successfullyRequestedTargetWindowIDs: Set<UUID> = []
        var successfullyRequestedWebWindowIDs: Set<UUID> = []
        var provenanceRequiredBrowserWindowIDs: Set<UUID> = []
        var openedBrowserWindowsBySavedWindowID: [UUID: CapturedBrowserWindow] = [:]
        var genericColdOpenedBrowserWindowIDs: Set<UUID> = []
        var unconfirmedLocalWindowIDs: Set<UUID> = []
        let savedWindowCountsByBundleIdentifier = Dictionary(
            grouping: snapshot.windows,
            by: \.bundleIdentifier
        ).mapValues(\.count)

        for (savedIndex, savedWindow) in snapshot.windows.enumerated() where !appInstances.handledBundles.contains(savedWindow.bundleIdentifier) && inspectionBlockedWindows[savedWindow.id] == nil {
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
                    if automatedBrowserBundles.contains(bundleIdentifier) || !openWebTargets.consume(
                        target,
                        bundleIdentifier: bundleIdentifier
                    ) {
                        targetsToOpen.append(target)
                    }
                } else if !openLocalTargets.consume(
                    target,
                    bundleIdentifier: bundleIdentifier
                ) {
                    if discoveryResult.unexposedApplications.contains(where: {
                        $0.bundleIdentifier == bundleIdentifier && $0.referencesLocalTarget(target)
                    }) || discoveredApplications.contains(where: {
                        $0.bundleIdentifier == bundleIdentifier && $0.hasUnreadyLocalTarget(target)
                    }) {
                        unconfirmedLocalWindowIDs.insert(savedWindow.id)
                        continue
                    }
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
                let ruledOutWindow = ruledOutWindows[savedWindow.id]
                // Ordinary document delivery lets the app reuse its own windows. Forced
                // window creation needs evidence that an AX-hidden owner is not still open.
                if request.disposition == .newWindow,
                   discoveryResult.unexposedApplications.contains(where: {
                       $0.bundleIdentifier == bundleIdentifier &&
                           $0.hasUnexposedOrdinaryWindow(membership: spaces.access.membership,
                               excludingWindowID: ruledOutWindow?.pid == $0.pid ? ruledOutWindow?.windowID : nil)
                   }) {
                    unconfirmedLocalWindowIDs.insert(savedWindow.id)
                    continue
                }
                let openResult: RestoreTargetOpenResult
                if request.disposition == .newBrowserWindow {
                    let remainingWindowTargets = snapshot.windows.dropFirst(savedIndex + 1).filter {
                        $0.bundleIdentifier == bundleIdentifier && inspectionBlockedWindows[$0.id] == nil
                    }.map { window in
                        window.openingConfiguration.effectiveTargets.filter {
                            $0.kind == .webURL && webTargetValidationIssue(for: $0) == nil
                        }
                    }.filter { !$0.isEmpty }
                    openResult = await targetOpener.openBrowserWindow(targets: request.targets,
                        bundleIdentifier: bundleIdentifier,
                        excludingWindowIdentifiers: reservedBrowserWindows[bundleIdentifier, default: []],
                        preferredApplicationURL: savedWindow.applicationBundleURL,
                        remainingWindowTargets: remainingWindowTargets)
                } else {
                    openResult = await targetOpener.open(targets: request.targets,
                        bundleIdentifier: bundleIdentifier, disposition: request.disposition,
                        preferredApplicationURL: savedWindow.applicationBundleURL)
                }
                if openResult.wasSubmitted {
                    if case let .openedNewBrowserWindow(_, _, openedTargetCount) = openResult {
                        requestedTargetCount += openedTargetCount ?? request.targets.count
                    } else {
                        requestedTargetCount += request.targets.count
                    }
                }

                switch openResult {
                case .opened, .openedNewBrowserWindow, .openedApplicationInstance:
                    if case let .openedApplicationInstance(pid) = openResult {
                        appInstances.processIdentifiers[savedWindow.id] = pid
                    }
                    successfullyOpenedTargetBundleIdentifiers.insert(bundleIdentifier)
                    let isColdStart = !initiallyRunningBundleIdentifiers.contains(bundleIdentifier)
                    let requestedLocalTargets = request.targets.filter {
                        $0.kind != .webURL && $0.url.isFileURL
                    }
                    if !requestedLocalTargets.isEmpty {
                        successfullyRequestedTargetWindowIDs.insert(savedWindow.id)
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
                    }
                    if request.disposition == .newBrowserWindow {
                        provenanceRequiredBrowserWindowIDs.insert(savedWindow.id)
                        let openedWindow: CapturedBrowserWindow?
                        var submittedTargetCount = request.targets.count
                        if case let .openedNewBrowserWindow(evidence, startupWindows, openedTargetCount) = openResult {
                            automatedBrowserBundles.insert(bundleIdentifier)
                            if let identifier = evidence.scriptingIdentifier {
                                reservedBrowserWindows[bundleIdentifier, default: []].insert(identifier)
                            }
                            openedWindow = evidence
                            submittedTargetCount = openedTargetCount ?? request.targets.count
                            openedBrowserWindowsBySavedWindowID[savedWindow.id] = evidence
                            if !startupWindows.isEmpty {
                                openWebTargets.replaceStartupWindows(
                                    startupWindows,
                                    consuming: request.targets,
                                    bundleIdentifier: bundleIdentifier
                                )
                            }
                        } else {
                            openedWindow = nil
                            if isColdStart,
                               savedWindowCountsByBundleIdentifier[bundleIdentifier] == 1 {
                                genericColdOpenedBrowserWindowIDs.insert(savedWindow.id)
                            }
                        }
                        let strategy = openedWindow == nil ? "generic" : "automated"
                        AppLogger.browserAutomation.info(
                            "Browser restore opened bundle=\(bundleIdentifier, privacy: .public) strategy=\(strategy, privacy: .public) coldStart=\(isColdStart) scriptingIdentifierAvailable=\(openedWindow?.scriptingIdentifier != nil) submittedTargetCount=\(submittedTargetCount)."
                        )
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
        ).union(successfullyOpenedTargetBundleIdentifiers).union(appInstances.handledBundles)
        let missingBundleIdentifiers = orderedSavedBundleIdentifiers(in: snapshot).filter { bundle in
            !runningBundleIdentifiersAfterTargetRequests.contains(bundle) &&
                snapshot.windows.contains { $0.bundleIdentifier == bundle && inspectionBlockedWindows[$0.id] == nil }
        }
        var requestedLaunchBundleIdentifiers: Set<String> = []
        for bundle in missingBundleIdentifiers {
            let windows = snapshot.windows.filter { $0.bundleIdentifier == bundle }
            guard let pid = await applicationLauncher.requestLaunch(bundleIdentifier: bundle,
                preferredApplicationURL: windows.compactMap(\.applicationBundleURL).first), pid > 0 else { continue }
            requestedLaunchBundleIdentifiers.insert(bundle)
            if windows.count == 1, let window = windows.first,
                window.captureSignature.source == .coreGraphics, window.openingConfiguration.effectiveTargets.isEmpty {
                appInstances.processIdentifiers[window.id] = pid
            }
        }
        let readinessBundleIdentifiers = successfullyOpenedTargetBundleIdentifiers
            .union(requestedLaunchBundleIdentifiers)
            .union(appInstances.requestedBundles)
        let preferredBrowserScriptingIdentifiers = openedBrowserWindowsBySavedWindowID
            .compactMapValues(\.scriptingIdentifier)

        // Keep one app's matching and instance assignment together across the two batches.
        // Keep return receipts while matching replacement processes under their new identities.
        var pendingInspections = recoveredWindowsBySavedID
        for (windowID, pid) in appInstances.processIdentifiers {
            if let recovered = recoveredWindowsBySavedID[windowID], recovered.allowsRestore, recovered.pid != pid {
                recoveredWindowsBySavedID[windowID] = nil
            }
        }
        var restoredWindowZOrderItems: [RestoreWindowZOrderItem] = []
        func restoreWindows(_ windows: [WindowRecord], from discoveryResult: WindowDiscoveryResult,
            timedOutWindowIDs: Set<UUID>, onlyReadyApps: Bool) async throws -> RestoreResult {
            finishStage(next: "matching")
            let discoveredApplications = discoveryResult.applications
            let liveWindowsByCandidateID = Self.liveWindowsByCandidateID(from: discoveredApplications)
            let recoveredCandidateIdentifiers = recoveredWindowsBySavedID.filter {
                !successfullyRequestedWebWindowIDs.contains($0.key)
            }.compactMapValues { recovered -> Int? in
                let candidates = liveWindowsByCandidateID.filter {
                    $0.candidate.pid == recovered.pid && $0.window.cgWindowID == recovered.windowID
                }
                return candidates.count == 1 ? candidates.first?.candidate.id : nil
            }
            let matchedPlans = matchPlanner.plans(
                for: windows.filter { appInstances.blockedWindows[$0.id] == nil && inspectionBlockedWindows[$0.id] == nil },
                candidates: liveWindowsByCandidateID.map { $0.candidate },
                runningBundleIdentifiers: runningBundleIdentifiers(from: discoveredApplications),
                genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
                preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
                openedBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
                preferredProcessIdentifiers: recoveredWindowsBySavedID.mapValues(\.pid)
                    .merging(appInstances.processIdentifiers, uniquingKeysWith: { _, instance in instance }),
                preferredCandidateIdentifiers: recoveredCandidateIdentifiers
            )
            let matchedPlansByID = Dictionary(uniqueKeysWithValues: matchedPlans.map { ($0.savedWindow.id, $0) })
            var plans = windows.compactMap { savedWindow -> RestoreWindowPlan? in
                if let reason = inspectionBlockedWindows[savedWindow.id] ?? appInstances.blockedWindows[savedWindow.id] {
                    return RestoreWindowPlan(savedWindow: savedWindow, candidate: nil, matchStrategy: nil,
                        skip: RestoreSkip(bundleIdentifier: savedWindow.bundleIdentifier, windowTitle: savedWindow.windowTitle, reason: reason))
                }
                return matchedPlansByID[savedWindow.id]
            }.map { plan -> RestoreWindowPlan in
                // Explain failed resolution after the normal open/launch flow has finished.
                if !onlyReadyApps, plan.candidate == nil,
                   [RestoreSkipReason.appNotRunning, RestoreSkipReason.appInstanceUnconfirmed].contains(plan.skip?.reason ?? ""),
                   !readinessBundleIdentifiers.contains(plan.savedWindow.bundleIdentifier),
                   !runningBundleIdentifiers(from: discoveredApplications).contains(plan.savedWindow.bundleIdentifier),
                   !discoveryResult.unexposedApplications.contains(where: { $0.bundleIdentifier == plan.savedWindow.bundleIdentifier }),
                   plan.savedWindow.applicationBundleURL?.validatedApplicationBundleURL(
                       withBundleIdentifier: plan.savedWindow.bundleIdentifier) == nil,
                   !applicationLauncher.isAvailable(bundleIdentifier: plan.savedWindow.bundleIdentifier) {
                    return RestoreWindowPlan(savedWindow: plan.savedWindow, candidate: nil, matchStrategy: nil,
                        skip: RestoreSkip(bundleIdentifier: plan.savedWindow.bundleIdentifier, windowTitle: plan.savedWindow.windowTitle,
                            reason: RestoreSkipReason.appNotFound))
                }
                let loadingCandidate = plan.candidate.flatMap { candidate in
                    discoveredApplications.first { $0.pid == candidate.pid }
                }.map { owner in
                    plan.savedWindow.role == "AXWindow" && plan.savedWindow.subrole == "AXStandardWindow" &&
                        plan.savedWindow.openingConfiguration.effectiveTargets.contains(where: owner.hasUnreadyLocalTarget)
                } ?? false
                if (plan.candidate == nil && unconfirmedLocalWindowIDs.contains(plan.savedWindow.id)) || loadingCandidate {
                    return RestoreWindowPlan(savedWindow: plan.savedWindow, candidate: nil, matchStrategy: nil,
                        skip: RestoreSkip(bundleIdentifier: plan.savedWindow.bundleIdentifier,
                            windowTitle: plan.savedWindow.windowTitle, reason: RestoreSkipReason.desktopUnconfirmed))
                }
                if plan.candidate == nil, let pid = appInstances.processIdentifiers[plan.savedWindow.id],
                   !discoveredApplications.contains(where: { $0.pid == pid }) {
                    return RestoreWindowPlan(savedWindow: plan.savedWindow, candidate: nil, matchStrategy: nil,
                        skip: RestoreSkip(bundleIdentifier: plan.savedWindow.bundleIdentifier, windowTitle: plan.savedWindow.windowTitle,
                                          reason: RestoreSkipReason.appInstanceUnconfirmed))
                }
                guard let expected = recoveredWindowsBySavedID[plan.savedWindow.id] else { return plan }
                let matchesRecovery = plan.candidate.map { candidate in
                    candidate.pid == expected.pid &&
                        liveWindowsByCandidateID.first(where: { $0.candidate.id == candidate.id })?.window.cgWindowID == expected.windowID
                } ?? false
                if matchesRecovery && expected.allowsRestore { return plan }
                // Opening a missing target can create a new window; preserve normal target matching.
                if !matchesRecovery && successfullyRequestedWebWindowIDs.contains(plan.savedWindow.id) {
                    return plan
                }
                // Never substitute a sibling or resubmit an unconfirmed asynchronous recovery move.
                return RestoreWindowPlan(savedWindow: plan.savedWindow, candidate: nil, matchStrategy: nil,
                    skip: RestoreSkip(bundleIdentifier: plan.savedWindow.bundleIdentifier, windowTitle: plan.savedWindow.windowTitle, reason: RestoreSkipReason.desktopUnconfirmed))
            }

            if onlyReadyApps {
                let readyBundles = Set(Dictionary(grouping: plans, by: { $0.savedWindow.bundleIdentifier }).compactMap { bundle, plans in
                    !readinessBundleIdentifiers.contains(bundle) && plans.allSatisfy({ $0.candidate != nil }) ? bundle : nil
                })
                plans.removeAll { !readyBundles.contains($0.savedWindow.bundleIdentifier) }
                if plans.isEmpty {
                    return RestoreResult(restoredWindows: 0, skippedItems: [], downgradedItems: [], displayFallbacks: [])
                }
            }
            let selectedIDs = Set(plans.map { $0.savedWindow.id })
            let selectedBundles = Set(plans.map { $0.savedWindow.bundleIdentifier })
            let selectedMatchedPlans = matchedPlans.filter { selectedIDs.contains($0.savedWindow.id) }
            let plannedWindowIDs = selectedMatchedPlans.reduce(into: [UUID: CGWindowID]()) { result, plan in
                guard let candidate = plan.candidate,
                    let windowID = liveWindowsByCandidateID.first(where: { $0.candidate.id == candidate.id })?.window.cgWindowID
                else { return }
                result[plan.savedWindow.id] = windowID
            }
            let compensationBlocks = await returnUnusedInspections(pendingInspections.filter { selectedIDs.contains($0.key) },
                plannedWindowIDs: plannedWindowIDs, snapshot: snapshot, inventory: spaceInventory)
            inspectionBlockedWindows.merge(compensationBlocks, uniquingKeysWith: { existing, _ in existing })
            for id in selectedIDs { pendingInspections[id] = nil }
            if Task.isCancelled, !compensationBlocks.isEmpty { throw RestoreEngineError.inspectionNotReturned }
            try Task.checkCancellation()
            if !compensationBlocks.isEmpty {
                plans = plans.map { plan in
                    guard let reason = inspectionBlockedWindows[plan.savedWindow.id] else { return plan }
                    return RestoreWindowPlan(savedWindow: plan.savedWindow, candidate: nil, matchStrategy: nil,
                        skip: RestoreSkip(bundleIdentifier: plan.savedWindow.bundleIdentifier,
                            windowTitle: plan.savedWindow.windowTitle, reason: reason))
                }
            }
            // Document evidence is independent of whether subsequent Space placement succeeds.
            for plan in selectedMatchedPlans {
                for target in plan.savedWindow.openingConfiguration.effectiveTargets where target.kind != .webURL {
                    guard localTargetValidationIssue(for: target) == nil,
                          plan.candidate?.referencesLocalTarget(target) != true,
                          !targetIssues.contains(where: { $0.windowID == plan.savedWindow.id && $0.target.id == target.id }) else { continue }
                    targetIssues.append(RestoreTargetIssue(windowID: plan.savedWindow.id,
                        bundleIdentifier: plan.savedWindow.bundleIdentifier, windowTitle: plan.savedWindow.windowTitle,
                        target: target, reason: .openingNotConfirmed))
                }
            }
            logBrowserWindowResolution(
                plans: plans,
                candidates: liveWindowsByCandidateID.map(\.candidate),
                openedBrowserWindowsBySavedWindowID: openedBrowserWindowsBySavedWindowID,
                openedBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
                initiallyRunningBundleIdentifiers: initiallyRunningBundleIdentifiers
            )

            var restoredWindows = 0
            var skippedItems = plans.compactMap { plan -> RestoreSkip? in
                guard let skip = plan.skip else { return nil }
                return RestoreSkip(id: skip.id, windowID: plan.savedWindow.id,
                    bundleIdentifier: skip.bundleIdentifier, windowTitle: skip.windowTitle, reason: skip.reason)
            }
            var downgradedItems: [RestoreDowngrade] = []
            var displayFallbacks: [DisplayFallbackEvent] = []
            var windowDiagnostics: [RestoreWindowDiagnostic] = []

            finishStage(next: "positioning")
            if !Task.isCancelled, !plans.isEmpty { await progress(.positioning) }
            for plan in plans {
                let candidateCount = liveWindowsByCandidateID.count {
                    $0.candidate.bundleIdentifier == plan.savedWindow.bundleIdentifier
                }
                let filteredCandidateCount = discoveryResult.diagnostics.count {
                    $0.bundleIdentifier == plan.savedWindow.bundleIdentifier && $0.kind == .windowRejected
                }
                let readinessTimedOut = timedOutWindowIDs.contains(plan.savedWindow.id)
                guard let candidate = plan.candidate,
                      var liveWindow = liveWindowsByCandidateID.first(where: { $0.candidate.id == candidate.id })?.window else {
                    AppLogger.restore.info(
                        "Window restore bundle=\(plan.savedWindow.bundleIdentifier, privacy: .public) matchStrategy=none candidateCount=\(candidateCount) filteredCandidateCount=\(filteredCandidateCount) readinessTimedOut=\(readinessTimedOut) geometryAttempted=false geometryAttemptCount=0 displayOutcome=unavailable result=skipped reason=\(plan.skip?.reason ?? RestoreSkipReason.windowNotFound, privacy: .public)."
                    )
                    windowDiagnostics.append(
                        RestoreWindowDiagnostic(
                            windowID: plan.savedWindow.id,
                            bundleIdentifier: plan.savedWindow.bundleIdentifier,
                            matchStrategy: nil,
                            candidateCount: candidateCount,
                            filteredCandidateCount: filteredCandidateCount,
                            readinessTimedOut: readinessTimedOut,
                            geometryAttempted: false,
                            geometryAttemptCount: 0,
                            expectedFrame: nil,
                            finalObservedFrame: nil,
                            displayOutcome: nil,
                            result: "skipped",
                            reason: plan.skip?.reason ?? RestoreSkipReason.windowNotFound
                        )
                    )
                    continue
                }

                let restoreDisplayPlan = displayResolver.restorePlan(
                    for: plan.savedWindow,
                    from: snapshot.sourceDisplayState,
                    to: currentDisplayState
                )
                let spaceOutcome = await spaces.prepare(
                    windowID: liveWindow.cgWindowID,
                    displayID: restoreDisplayPlan.resolvedDisplayID,
                    inventory: spaceInventory,
                    ordinaryWindow: !liveWindow.isFullscreen &&
                        ((liveWindow.role == "AXWindow" && liveWindow.subrole == "AXStandardWindow") ||
                         candidate.matchesMinimizedAppWindow(plan.savedWindow))
                )
                var canApplyGeometry = spaceOutcome.permitsGeometry
                if spaceOutcome == .moved, let windowID = liveWindow.cgWindowID {
                    let rediscovery = try await rediscoverWindow(pid: candidate.pid, windowID: windowID)
                    if let window = rediscovery.window { liveWindow = window } else { canApplyGeometry = false }
                }
                AppLogger.restore.info("Space restore bundle=\(plan.savedWindow.bundleIdentifier, privacy: .public) windowID=\(liveWindow.cgWindowID ?? 0) outcome=\(spaceOutcome.rawValue, privacy: .public).")
                let result: RestoreWindowApplyResult
                if canApplyGeometry {
                    result = try await windowApplier.apply(
                        savedWindow: plan.savedWindow,
                        targetFrame: restoreDisplayPlan.targetFrame,
                        to: liveWindow
                    )
                } else {
                    result = .failed(reason: RestoreSkipReason.desktopUnconfirmed)
                }
                let expectedFrame = String(describing: restoreDisplayPlan.targetFrame)
                let finalFrame = result.finalObservedFrame.map(String.init(describing:)) ?? "unavailable"
                AppLogger.restore.info(
                    "Window restore bundle=\(plan.savedWindow.bundleIdentifier, privacy: .public) matchStrategy=\(plan.matchStrategy?.rawValue ?? "unknown", privacy: .public) candidateCount=\(candidateCount) filteredCandidateCount=\(filteredCandidateCount) readinessTimedOut=\(readinessTimedOut) geometryAttempted=\(canApplyGeometry) geometryAttemptCount=\(result.attemptCount) expectedFrame=\(expectedFrame, privacy: .public) finalFrame=\(finalFrame, privacy: .public) displayOutcome=\(restoreDisplayPlan.outcome.rawValue, privacy: .public) result=\(result.didRestore ? "restored" : "skipped", privacy: .public)."
                )
                windowDiagnostics.append(
                    RestoreWindowDiagnostic(
                        windowID: plan.savedWindow.id,
                        bundleIdentifier: plan.savedWindow.bundleIdentifier,
                        matchStrategy: plan.matchStrategy,
                        candidateCount: candidateCount,
                        filteredCandidateCount: filteredCandidateCount,
                        readinessTimedOut: readinessTimedOut,
                        geometryAttempted: canApplyGeometry,
                        geometryAttemptCount: result.attemptCount,
                        expectedFrame: restoreDisplayPlan.targetFrame,
                        finalObservedFrame: result.finalObservedFrame,
                        displayOutcome: restoreDisplayPlan.outcome,
                        result: result.didRestore ? "restored" : "skipped",
                        reason: result.failureReason ?? (spaceOutcome == .identityUnconfirmed ? RestoreDowngradeReason.windowIdentityUnconfirmed : nil)
                    )
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
                    if spaceOutcome == .identityUnconfirmed {
                        downgradedItems.append(RestoreDowngrade(
                            bundleIdentifier: plan.savedWindow.bundleIdentifier,
                            windowTitle: plan.savedWindow.windowTitle,
                            reason: RestoreDowngradeReason.windowIdentityUnconfirmed
                        ))
                    }
                    if let fallback = restoreDisplayPlan.fallback {
                        displayFallbacks.append(fallback)
                    }
                } else {
                    skippedItems.append(
                        RestoreSkip(
                            windowID: plan.savedWindow.id,
                            bundleIdentifier: plan.savedWindow.bundleIdentifier,
                            windowTitle: plan.savedWindow.windowTitle,
                            reason: result.failureReason ?? RestoreSkipReason.restoreFailed
                        )
                    )
                }
            }

            return RestoreResult(restoredWindows: restoredWindows, skippedItems: skippedItems,
                downgradedItems: downgradedItems, displayFallbacks: displayFallbacks,
                windowDiagnostics: windowDiagnostics,
                discoveryDiagnostics: discoveryResult.diagnostics.filter { selectedBundles.contains($0.bundleIdentifier ?? "") })
        }

        var batches: [RestoreResult] = []
        do {
            let ready = try await restoreWindows(snapshot.windows, from: discoveryResult,
                timedOutWindowIDs: [], onlyReadyApps: true)
            batches.append(ready)
            let processedIDs = Set(ready.windowDiagnostics.map(\.windowID))
            let remainingWindows = snapshot.windows.filter { !processedIDs.contains($0.id) }

            finishStage(next: "readiness")
            if !readinessBundleIdentifiers.isEmpty {
                if !Task.isCancelled { await progress(.waiting) }
                let readiness = try await rediscoverApplicationsUntilRestoreReadiness(
                    windows: remainingWindows, deadline: deadline,
                    requestedBundleIdentifiers: readinessBundleIdentifiers,
                    expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
                    successfullyRequestedTargetWindowIDs: successfullyRequestedTargetWindowIDs,
                    successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
                    provenanceRequiredBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
                    openedBrowserWindowsBySavedWindowID: openedBrowserWindowsBySavedWindowID,
                    preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
                    genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
                    appInstances: appInstances)
                discoveryResult = readiness.discoveryResult
                timedOutWindowIDs = readiness.timedOutWindowIDs
            }
            if !remainingWindows.isEmpty || snapshot.windows.isEmpty {
                batches.append(try await restoreWindows(remainingWindows, from: discoveryResult,
                    timedOutWindowIDs: timedOutWindowIDs, onlyReadyApps: false))
            }
        } catch {
            let blocked = await returnUnusedInspections(pendingInspections,
                plannedWindowIDs: [:], snapshot: snapshot, inventory: spaceInventory)
            let restoreError: Error = blocked.isEmpty ? error : RestoreEngineError.inspectionNotReturned
            telemetryLogger.log(.restoreFailed(snapshotID: id, error: restoreError))
            throw restoreError
        }

        finishStage(next: "stacking")
        if !Task.isCancelled { await progress(.stacking) }
        await RestoreWindowZOrderRestorer(
            windowApplier: windowApplier,
            applicationActivator: applicationActivator,
            canStack: { item in
                let displayPlan = displayResolver.restorePlan(for: item.savedWindow, from: snapshot.sourceDisplayState, to: currentDisplayState)
                return spaces.canStack(window: item.liveWindow, displayID: displayPlan.resolvedDisplayID, inventory: spaceInventory)
            },
            canActivate: { item in
                spaces.canActivate(windowID: item.liveWindow.cgWindowID, processIdentifier: item.processIdentifier, inventory: spaceInventory)
            }
        ).restore(restoredWindowZOrderItems)
        finishStage()

        let restoreResult = RestoreResult(
            restoredWindows: batches.reduce(0) { $0 + $1.restoredWindows },
            skippedItems: batches.flatMap(\.skippedItems),
            downgradedItems: batches.flatMap(\.downgradedItems),
            displayFallbacks: batches.flatMap(\.displayFallbacks),
            requestedTargetCount: requestedTargetCount,
            targetIssues: targetIssues,
            windowDiagnostics: batches.flatMap(\.windowDiagnostics),
            discoveryDiagnostics: batches.flatMap(\.discoveryDiagnostics) + discoveryResult.diagnostics.filter { $0.bundleIdentifier == nil }
        )
        telemetryLogger.log(.restoreCompleted(snapshot: snapshot, result: restoreResult))
        return restoreResult
    }

    private func returnUnusedInspections(
        _ recoveries: [UUID: RestoreRecoveredWindow],
        plannedWindowIDs: [UUID: CGWindowID],
        snapshot: Snapshot,
        inventory: RestoreSpaceInventory?
    ) async -> [UUID: String] {
        var pending = recoveries.filter { $0.value.inspection != nil }
        var blocked: [UUID: String] = [:]
        // Each unused inspection is attempted once. A failed return can make another plan ineligible.
        while let entry = pending.first(where: { entry in
            !plannedWindowIDs.contains { blocked[$0.key] == nil && $0.value == entry.value.windowID }
        }) {
            pending.removeValue(forKey: entry.key)
            guard let receipt = entry.value.inspection,
                let saved = snapshot.windows.first(where: { $0.id == entry.key }) else { continue }
            let returned = await Task {
                if let ids = spaces.access.applicationWindowIDs(entry.value.pid), !ids.contains(entry.value.windowID) {
                    return true
                }
                guard let inventory else { return false }
                return await returnInspectedWindow(receipt.context, expectedFrame: receipt.frame,
                    savedWindow: saved, inventory: inventory)
            }.value
            AppLogger.restore.info("Unused inspection bundle=\(saved.bundleIdentifier, privacy: .public) windowID=\(entry.value.windowID) returned=\(returned).")
            if !returned {
                for window in snapshot.windows where window.bundleIdentifier == saved.bundleIdentifier &&
                    window.pidAtCapture == saved.pidAtCapture {
                    blocked[window.id] = RestoreSkipReason.inspectionNotReturned
                }
            }
        }
        return blocked
    }

    private func prepareAppInstances(snapshot: Snapshot, discoveryResult: WindowDiscoveryResult,
        inspectionBlockedWindows: [UUID: String]) async -> RestoreAppInstancePreparation {
        var result = RestoreAppInstancePreparation()
        let windowsByBundle = Dictionary(grouping: snapshot.windows, by: \.bundleIdentifier)
        for bundle in orderedSavedBundleIdentifiers(in: snapshot) {
            let windows = windowsByBundle[bundle, default: []]
            let applications = discoveryResult.applications.filter { $0.bundleIdentifier == bundle }.sorted { $0.pid < $1.pid }
            // Confirm an already-running owner for the position-only CG singleton fallback.
            // Unknown AX identity suppresses hidden-window diagnostics and cannot prove a singleton.
            if windows.count == 1, let window = windows.first,
                window.captureSignature.source == .coreGraphics, window.subrole == nil,
                window.openingConfiguration.effectiveTargets.isEmpty,
                inspectionBlockedWindows[window.id] == nil,
                applications.count == 1, let application = applications.first, application.pid > 0,
                application.windows.count == 1,
                let liveWindowID = application.windows.first?.cgWindowID, liveWindowID != 0,
                !discoveryResult.unexposedApplications.contains(where: {
                    $0.bundleIdentifier == bundle && ($0.pid != application.pid ||
                        $0.hasUnexposedOrdinaryWindow(membership: spaces.access.membership))
                }) {
                result.processIdentifiers[window.id] = application.pid
            }
            let capturePIDs = windows.map(\.pidAtCapture).reduce(into: [pid_t]()) { pids, pid in
                if !pids.contains(pid) { pids.append(pid) }
            }
            // Browser window/profile restoration keeps its existing dedicated strategy.
            let isProjectApplication = UnrealProjectResolver.isUnreal(bundleIdentifier: bundle)
            let hasProjectSiblings = isProjectApplication && windows.count > 1 &&
                Set(windows.flatMap { $0.openingConfiguration.effectiveTargets.map { $0.url.standardizedFileURL } }).count == 1
            guard (capturePIDs.count > 1 || hasProjectSiblings), capturePIDs.allSatisfy({ $0 > 0 }),
                  !BrowserAutomationBrowser.allCases.contains(where: { $0.bundleIdentifier == bundle }),
                  !windows.contains(where: { $0.openingConfiguration.effectiveTargets.contains(where: { $0.kind == .webURL }) }) else { continue }
            result.handledBundles.insert(bundle)
            let groups = capturePIDs.map { pid in windows.filter { $0.pidAtCapture == pid } }
            let preferredPIDs = matchPlanner.plans(for: windows,
                candidates: Self.liveWindowsByCandidateID(from: applications).map(\.candidate),
                runningBundleIdentifiers: [bundle], requiresRuntimeRole: true)
                .reduce(into: [UUID: pid_t]()) { $0[$1.savedWindow.id] = $1.candidate?.pid }
            let initialPIDs = Set(applications.map(\.pid)).union(
                discoveryResult.unexposedApplications.filter { $0.bundleIdentifier == bundle }.map(\.pid))
            let reusablePIDs = groups.map { group -> [pid_t] in
                guard !group.contains(where: { inspectionBlockedWindows[$0.id] != nil }) else { return [] }
                let groupTargets = group.flatMap { $0.openingConfiguration.effectiveTargets }
                let project = groupTargets.first?.url.standardizedFileURL
                let sharesProject = isProjectApplication && project?.pathExtension.lowercased() == "uproject" &&
                    groupTargets.allSatisfy { $0.kind == .file && $0.url.isFileURL && $0.url.standardizedFileURL == project }
                let reusable = applications.filter { application in
                    var targets = OpenLocalTargetIndex(from: [application])
                    let hasTargets = sharesProject ? groupTargets.allSatisfy {
                        targets.occurrenceCount(of: $0.url, bundleIdentifier: bundle) > 0
                    } : group.allSatisfy { window in
                        window.openingConfiguration.effectiveTargets.allSatisfy {
                            targets.consume($0, bundleIdentifier: bundle)
                        }
                    }
                    guard hasTargets else { return false }
                    let candidates = Self.liveWindowsByCandidateID(from: [application]).map(\.candidate)
                    // Supply owner evidence only for the position-only CG singleton fallback.
                    var processBindings: [UUID: pid_t] = [:]
                    if group.count == 1, let window = group.first,
                        window.captureSignature.source == .coreGraphics,
                        window.openingConfiguration.effectiveTargets.isEmpty {
                        processBindings[window.id] = application.pid
                    }
                    let plans = matchPlanner.plans(for: group, candidates: candidates,
                        runningBundleIdentifiers: [bundle],
                        preferredProcessIdentifiers: processBindings, requiresRuntimeRole: true)
                    // A closed tool window must not cause an already-open project to launch again.
                    return sharesProject ? plans.contains {
                        $0.candidate?.role == "AXWindow" && $0.candidate?.subrole == "AXStandardWindow"
                    } : plans.allSatisfy { $0.candidate != nil }
                }.map(\.pid)
                var preferredPID = group[0].pidAtCapture
                if let pid = preferredPIDs[group[0].id], group.allSatisfy({ preferredPIDs[$0.id] == pid }) {
                    preferredPID = pid
                }
                guard reusable.contains(preferredPID) else { return reusable }
                return [preferredPID] + reusable.filter { $0 != preferredPID }
            }
            // Reserve a complete assignment before launching; broad matches must not steal a sibling's only match.
            var groupByPID: [pid_t: Int] = [:]
            func reserve(_ group: Int, visited: inout Set<pid_t>) -> Bool {
                let choices = reusablePIDs[group].filter { groupByPID[$0] == nil } +
                    reusablePIDs[group].filter { groupByPID[$0] != nil }
                for pid in choices where visited.insert(pid).inserted {
                    if let previous = groupByPID[pid], !reserve(previous, visited: &visited) { continue }
                    groupByPID[pid] = group
                    return true
                }
                return false
            }
            let reuseOrder = groups.indices.sorted { reusablePIDs[$0].count < reusablePIDs[$1].count }
            for group in reuseOrder {
                var visited: Set<pid_t> = []
                _ = reserve(group, visited: &visited)
            }
            let pidByGroup = Dictionary(uniqueKeysWithValues: groupByPID.map { ($0.value, $0.key) })
            var usedPIDs = Set(groupByPID.keys)
            for (groupIndex, group) in groups.enumerated() {
                if let reason = group.compactMap({ inspectionBlockedWindows[$0.id] }).first {
                    for window in group { result.blockedWindows[window.id] = reason }
                    continue
                }
                var validTargets: [(window: WindowRecord, target: WindowOpenTarget)] = []
                for window in group {
                    for target in window.openingConfiguration.effectiveTargets {
                        if let reason = localTargetValidationIssue(for: target) {
                            result.targetIssues.append(RestoreTargetIssue(windowID: window.id, bundleIdentifier: bundle,
                                windowTitle: window.windowTitle, target: target, reason: reason))
                        } else {
                            validTargets.append((window, target))
                            result.targetsByWindowID[window.id, default: []].append(target)
                        }
                    }
                }
                if let pid = pidByGroup[groupIndex] {
                    for window in group { result.processIdentifiers[window.id] = pid }
                    continue
                }
                // AX-invisible windows are unresolved, not evidence that an instance is closed.
                if discoveryResult.unexposedApplications.contains(where: { owner in
                    owner.bundleIdentifier == bundle && !usedPIDs.contains(owner.pid) &&
                        (owner.hasUnexposedOrdinaryWindow(membership: spaces.access.membership) ||
                            group.contains { $0.openingConfiguration.effectiveTargets.contains(where: owner.referencesLocalTarget) })
                }) || applications.contains(where: { owner in
                    !usedPIDs.contains(owner.pid) &&
                        group.contains { $0.openingConfiguration.effectiveTargets.contains(where: owner.hasUnreadyLocalTarget) }
                }) {
                    for window in group { result.blockedWindows[window.id] = RestoreSkipReason.desktopUnconfirmed }
                    continue
                }
                let hasTargets = group.contains { !$0.openingConfiguration.effectiveTargets.isEmpty }
                var launchedPID: pid_t?
                if !validTargets.isEmpty {
                    // One batch launches one captured process, including all its document windows.
                    let opened = await targetOpener.open(targets: validTargets.map(\.target),
                        bundleIdentifier: bundle, disposition: .newApplicationInstance,
                        preferredApplicationURL: group.compactMap(\.applicationBundleURL).first)
                    if opened.wasSubmitted { result.requestedTargetCount += validTargets.count }
                    if case let .openedApplicationInstance(pid) = opened { launchedPID = pid }
                    if case let .failed(reason) = opened {
                        for item in validTargets {
                            result.targetIssues.append(RestoreTargetIssue(windowID: item.window.id, bundleIdentifier: bundle,
                                windowTitle: item.window.windowTitle, target: item.target, reason: reason))
                        }
                    }
                } else if !hasTargets {
                    launchedPID = await applicationLauncher.launchInstance(bundleIdentifier: bundle,
                        preferredApplicationURL: group.compactMap(\.applicationBundleURL).first)
                }
                guard let pid = launchedPID, pid > 0, !initialPIDs.contains(pid), usedPIDs.insert(pid).inserted else {
                    for window in group { result.blockedWindows[window.id] = RestoreSkipReason.appInstanceUnconfirmed }
                    continue
                }
                result.requestedBundles.insert(bundle)
                for window in group { result.processIdentifiers[window.id] = pid }
            }
        }
        return result
    }

    private func inspectRecoveredWindow(
        savedWindow: WindowRecord,
        pid: pid_t,
        candidate: CGWindowMetadata,
        displayID: UInt32?,
        inventory: RestoreSpaceInventory
    ) async throws -> RestoreWindowInspectionOutcome {
        guard let inspection = spaces.inspection(for: candidate, pid: pid, displayID: displayID, inventory: inventory)
        else { return .unchanged }
        try Task.checkCancellation()
        // Once inspection begins, finish observing the submitted move before honoring cancellation.
        let outcome = await Task {
            await spaces.prepare(windowID: inspection.windowID, displayID: displayID,
                inventory: inventory, ordinaryWindow: true, expectedSourceSpace: inspection.sourceSpaceID)
        }.value
        guard outcome == .moved else {
            try Task.checkCancellation()
            return outcome == .unconfirmed ? .blocked(RestoreSkipReason.desktopUnconfirmed) : .unchanged
        }
        // Complete this bounded observation even if the restore is cancelled, so compensation has a settled baseline.
        let settled = await Task {
            await spaces.settledWindow(windowID: inspection.windowID, pid: pid,
                inSpace: inspection.destinationSpaceID, inventory: inventory)
        }.value
        guard let settled else {
            if Task.isCancelled { throw RestoreEngineError.inspectionNotReturned }
            return .blocked(RestoreSkipReason.inspectionNotReturned)
        }

        var inspectionError: Error?
        var observedIntervention = false
        var ruledOut = false
        do {
            try Task.checkCancellation()
            let rediscovery = try await rediscoverWindow(pid: pid, windowID: inspection.windowID)
            observedIntervention = rediscovery.window.map { $0.isMinimized || $0.isFullscreen } ?? false
            try Task.checkCancellation()
            let live = Self.liveWindowsByCandidateID(from: rediscovery.result.applications)
                .first { $0.candidate.pid == pid && $0.window.cgWindowID == inspection.windowID }
            if rediscovery.window != nil, let live {
                let targets = savedWindow.openingConfiguration.effectiveTargets.filter { $0.kind != .webURL }
                let differentResource = !targets.isEmpty && live.candidate.documentURLs.contains(where: \.isFileURL) &&
                    !targets.contains(where: live.candidate.referencesLocalTarget)
                ruledOut = differentResource || live.window.role != kAXWindowRole as String ||
                    live.window.subrole.map { $0 != kAXStandardWindowSubrole as String } == true
            }
            if !observedIntervention, rediscovery.window != nil, let live,
                live.window.role == kAXWindowRole as String,
                live.window.subrole == kAXStandardWindowSubrole as String,
                savedWindow.openingConfiguration.effectiveTargets.filter({ $0.kind != .webURL })
                    .allSatisfy(live.candidate.referencesLocalTarget),
                spaces.destinationsAreUnchanged(inventory),
                spaces.access.membership(inspection.windowID) == [inspection.destinationSpaceID],
                let current = spaces.access.windowMetadata(pid, inspection.windowID),
                current.processIdentifier == pid, current.windowID == inspection.windowID,
                RestoreWindowInspection.framesMatch(settled.bounds, current.bounds) {
                return .confirmed(rediscovery.result, RestoreRecoveredWindow(pid: pid, windowID: inspection.windowID,
                    allowsRestore: true, inspection: (inspection, settled.bounds)))
            }
        } catch {
            inspectionError = error
        }
        if observedIntervention {
            if inspectionError != nil { throw RestoreEngineError.inspectionNotReturned }
            return .blocked(RestoreSkipReason.inspectionNotReturned)
        }

        // Cancellation must not cancel the awaited return. Never reopen or place another window before it is proven.
        let returned = await Task {
            await returnInspectedWindow(inspection, expectedFrame: settled.bounds,
                savedWindow: savedWindow, inventory: inventory)
        }.value
        AppLogger.restore.info("Window inspection bundle=\(savedWindow.bundleIdentifier, privacy: .public) windowID=\(inspection.windowID) returned=\(returned).")
        if !returned, inspectionError != nil || Task.isCancelled { throw RestoreEngineError.inspectionNotReturned }
        if let inspectionError { throw inspectionError }
        try Task.checkCancellation()
        guard returned else { return .blocked(RestoreSkipReason.inspectionNotReturned) }
        // Discard the wrong-file hint and rebuild discovery before ordinary file opening.
        return .returned(try discoveryResultProvider(nil, pid), ruledOut: ruledOut)
    }

    private func returnInspectedWindow(
        _ inspection: RestoreWindowInspection,
        expectedFrame: CGRect,
        savedWindow: WindowRecord,
        inventory: RestoreSpaceInventory
    ) async -> Bool {
        guard await spaces.returnWindow(inspection, expectedFrame: expectedFrame, inventory: inventory),
            let returned = await spaces.settledWindow(windowID: inspection.windowID, pid: inspection.pid,
                inSpace: inspection.sourceSpaceID, inventory: inventory)
        else { return false }
        if inspection.matchesOriginalFrame(returned.bounds) { return true }
        let window: DiscoveredWindow
        do {
            guard let rediscovered = try await rediscoverWindow(pid: inspection.pid, windowID: inspection.windowID).window
            else { return false }
            window = rediscovered
        } catch { return false }
        guard window.cgWindowID == inspection.windowID, !window.isMinimized, !window.isFullscreen,
            spaces.destinationsAreUnchanged(inventory),
            spaces.access.membership(inspection.windowID) == [inspection.sourceSpaceID],
            let current = spaces.access.windowMetadata(inspection.pid, inspection.windowID),
            current.processIdentifier == inspection.pid, current.windowID == inspection.windowID,
            RestoreWindowInspection.framesMatch(returned.bounds, current.bounds)
        else { return false }
        // Only a freshly rediscovered handle may repair geometry. Do not unminimize or focus it.
        do {
            _ = try await windowApplier.restoreFrame(savedWindow: savedWindow,
                targetFrame: inspection.originalFrame, to: window)
        } catch { return false }
        guard let final = await spaces.settledWindow(windowID: inspection.windowID, pid: inspection.pid,
            inSpace: inspection.sourceSpaceID, inventory: inventory)
        else { return false }
        return inspection.matchesOriginalFrame(final.bounds)
    }

    private func rediscoverWindow(pid: pid_t, windowID: CGWindowID) async throws -> (result: WindowDiscoveryResult, window: DiscoveredWindow?) {
        var result = try discoveryResultProvider(nil, pid)
        for attempt in 0..<20 {
            let windows = result.applications.filter { $0.pid == pid }.flatMap(\.windows).filter { $0.cgWindowID == windowID }
            if windows.count == 1 { return (result, windows[0]) }
            guard !Task.isCancelled, attempt < 19 else { break }
            await launchPollSleeper(0.05)
            result = try discoveryResultProvider(nil, pid)
        }
        return (result, nil)
    }

    private func rediscoverApplicationsUntilRestoreReadiness(
        windows: [WindowRecord],
        deadline: Date,
        requestedBundleIdentifiers: Set<String>,
        expectedOpenedLocalTargetCounts: [String: [URL: Int]],
        successfullyRequestedTargetWindowIDs: Set<UUID>,
        successfullyRequestedWebWindowIDs: Set<UUID>,
        provenanceRequiredBrowserWindowIDs: Set<UUID>,
        openedBrowserWindowsBySavedWindowID: [UUID: CapturedBrowserWindow],
        preferredBrowserScriptingIdentifiers: [UUID: String],
        genericColdOpenedBrowserWindowIDs: Set<UUID>,
        appInstances: RestoreAppInstancePreparation
    ) async throws -> RestoreReadinessResult {
        let savedBundleIdentifiers = Set(windows.map(\.bundleIdentifier))
        let identityReadinessBundles = Set(expectedOpenedLocalTargetCounts.keys).union(appInstances.requestedBundles)
        var discoveryResult = enrichedRestoreDiscoveryResult(
            try discoveryResultProvider(savedBundleIdentifiers, nil),
            openedBrowserWindowsBySavedWindowID: openedBrowserWindowsBySavedWindowID
        )
        // Newly opened AX documents can precede their owner-validated WindowServer IDs.
        var identityPollsRemaining = 5
        while true {
            try Task.checkCancellation()
            let applications = discoveryResult.applications
            let contentReady = requestedApplicationsAreReady(
                windows: windows,
                requestedBundleIdentifiers: requestedBundleIdentifiers,
                expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
                successfullyRequestedTargetWindowIDs: successfullyRequestedTargetWindowIDs,
                successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
                provenanceRequiredBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
                preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
                genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
                discoveredApplications: applications,
                appInstances: appInstances
            )
            if contentReady {
                let identityPending = applications.contains { application in
                    identityReadinessBundles.contains(application.bundleIdentifier) && application.windows.contains {
                        $0.role == kAXWindowRole as String && $0.subrole == kAXStandardWindowSubrole as String &&
                            !$0.isFullscreen && $0.cgWindowID == nil
                    }
                }
                guard identityPending, identityPollsRemaining > 0, launchClock() < deadline else {
                    return RestoreReadinessResult(discoveryResult: discoveryResult, timedOutWindowIDs: [])
                }
                identityPollsRemaining -= 1
            } else if launchClock() >= deadline {
                return RestoreReadinessResult(discoveryResult: discoveryResult,
                    timedOutWindowIDs: unreadyRequestedWindowIDs(
                        windows: windows,
                        requestedBundleIdentifiers: requestedBundleIdentifiers,
                        expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
                        successfullyRequestedTargetWindowIDs: successfullyRequestedTargetWindowIDs,
                        successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
                        provenanceRequiredBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
                        preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
                        genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
                        discoveredApplications: applications,
                        appInstances: appInstances))
            }
            let remainingTime = max(0, deadline.timeIntervalSince(launchClock()))
            await launchPollSleeper(min(contentReady ? 0.05 : launchPollInterval, remainingTime))
            try Task.checkCancellation()
            discoveryResult = enrichedRestoreDiscoveryResult(
                try discoveryResultProvider(savedBundleIdentifiers, nil),
                openedBrowserWindowsBySavedWindowID: openedBrowserWindowsBySavedWindowID
            )
        }
    }

    private func requestedApplicationsAreReady(
        windows: [WindowRecord],
        requestedBundleIdentifiers: Set<String>,
        expectedOpenedLocalTargetCounts: [String: [URL: Int]],
        successfullyRequestedTargetWindowIDs: Set<UUID>,
        successfullyRequestedWebWindowIDs: Set<UUID>,
        provenanceRequiredBrowserWindowIDs: Set<UUID>,
        preferredBrowserScriptingIdentifiers: [UUID: String],
        genericColdOpenedBrowserWindowIDs: Set<UUID>,
        discoveredApplications: [DiscoveredApplication],
        appInstances: RestoreAppInstancePreparation
    ) -> Bool {
        unreadyRequestedWindowIDs(
            windows: windows,
            requestedBundleIdentifiers: requestedBundleIdentifiers,
            expectedOpenedLocalTargetCounts: expectedOpenedLocalTargetCounts,
            successfullyRequestedTargetWindowIDs: successfullyRequestedTargetWindowIDs,
            successfullyRequestedWebWindowIDs: successfullyRequestedWebWindowIDs,
            provenanceRequiredBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
            preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
            genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
            discoveredApplications: discoveredApplications,
            appInstances: appInstances
        ).isEmpty
    }

    private func unreadyRequestedWindowIDs(
        windows: [WindowRecord],
        requestedBundleIdentifiers: Set<String>,
        expectedOpenedLocalTargetCounts: [String: [URL: Int]],
        successfullyRequestedTargetWindowIDs: Set<UUID>,
        successfullyRequestedWebWindowIDs: Set<UUID>,
        provenanceRequiredBrowserWindowIDs: Set<UUID>,
        preferredBrowserScriptingIdentifiers: [UUID: String],
        genericColdOpenedBrowserWindowIDs: Set<UUID>,
        discoveredApplications: [DiscoveredApplication],
        appInstances: RestoreAppInstancePreparation
    ) -> Set<UUID> {
        let discoveredTargets = OpenLocalTargetIndex(
            from: discoveredApplications
        )
        let localTargetRequestsAreReady = expectedOpenedLocalTargetCounts.allSatisfy {
            bundleIdentifier, expectedCounts in
            expectedCounts.allSatisfy { URL, expectedCount in
                discoveredTargets.occurrenceCount(
                    of: URL,
                    bundleIdentifier: bundleIdentifier
                ) >= expectedCount
            }
        }
        var unreadyWindowIDs: Set<UUID> = []
        if !localTargetRequestsAreReady {
            unreadyWindowIDs.formUnion(successfullyRequestedTargetWindowIDs)
        }
        var instanceTargets = Dictionary(uniqueKeysWithValues: Set(appInstances.processIdentifiers.values).map { pid in
            (pid, OpenLocalTargetIndex(from: discoveredApplications.filter { $0.pid == pid }))
        })
        for window in windows {
            guard let pid = appInstances.processIdentifiers[window.id],
                  let targets = appInstances.targetsByWindowID[window.id],
                  var index = instanceTargets[pid] else { continue }
            for target in targets where !index.consume(target, bundleIdentifier: window.bundleIdentifier) {
                unreadyWindowIDs.insert(window.id)
            }
            instanceTargets[pid] = index
        }

        let liveWindowsByCandidateID = Self.liveWindowsByCandidateID(from: discoveredApplications)
        let runningBundleIdentifiers = runningBundleIdentifiers(from: discoveredApplications)
        let savedWindowsForRequests = windows.filter { savedWindow in
            appInstances.blockedWindows[savedWindow.id] == nil && (
                successfullyRequestedTargetWindowIDs.contains(savedWindow.id) ||
                successfullyRequestedWebWindowIDs.contains(savedWindow.id) ||
                requestedBundleIdentifiers.contains(savedWindow.bundleIdentifier))
        }
        let plans = matchPlanner.plans(
            for: savedWindowsForRequests,
            candidates: liveWindowsByCandidateID.map(\.candidate),
            runningBundleIdentifiers: runningBundleIdentifiers,
            genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
            preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers,
            openedBrowserWindowIDs: provenanceRequiredBrowserWindowIDs,
            preferredProcessIdentifiers: appInstances.processIdentifiers
        )
        unreadyWindowIDs.formUnion(plans.compactMap { plan in
            plan.candidate == nil ? plan.savedWindow.id : nil
        })
        return unreadyWindowIDs
    }

    private func enrichedRestoreDiscoveryResult(
        _ discoveryResult: WindowDiscoveryResult,
        openedBrowserWindowsBySavedWindowID: [UUID: CapturedBrowserWindow]
    ) -> WindowDiscoveryResult {
        guard !openedBrowserWindowsBySavedWindowID.isEmpty else {
            return discoveryResult
        }

        let openedWindows = openedBrowserWindowsBySavedWindowID
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map(\.value)
        return BrowserWindowTargetEnricher(allowsOrderFallback: false).enrich(
            discoveryResult,
            with: BrowserTabCaptureResult(windows: openedWindows, issues: [])
        ).discoveryResult
    }

    private func logBrowserWindowResolution(
        plans: [RestoreWindowPlan],
        candidates: [RestoreWindowCandidate],
        openedBrowserWindowsBySavedWindowID: [UUID: CapturedBrowserWindow],
        openedBrowserWindowIDs: Set<UUID>,
        initiallyRunningBundleIdentifiers: Set<String>
    ) {
        for plan in plans where openedBrowserWindowIDs.contains(plan.savedWindow.id) {
            let bundleIdentifier = plan.savedWindow.bundleIdentifier
            let strategy = openedBrowserWindowsBySavedWindowID[plan.savedWindow.id] == nil
                ? "generic"
                : "automated"
            let candidateCount = candidates.count { $0.bundleIdentifier == bundleIdentifier }
            let scriptingIdentifier = openedBrowserWindowsBySavedWindowID[
                plan.savedWindow.id
            ]?.scriptingIdentifier
            let identifierCandidateCount = candidates.count {
                $0.bundleIdentifier == bundleIdentifier &&
                    $0.browserScriptingIdentifier == scriptingIdentifier &&
                    scriptingIdentifier != nil
            }
            let identifierOutcome: String
            if scriptingIdentifier == nil {
                identifierOutcome = "unavailable"
            } else if identifierCandidateCount == 1 {
                identifierOutcome = "unique"
            } else if identifierCandidateCount > 1 {
                identifierOutcome = "ambiguous"
            } else {
                identifierOutcome = "missing"
            }
            let outcome = plan.candidate == nil ? "unresolved" : "resolved"
            AppLogger.browserAutomation.info(
                "Browser restore resolution bundle=\(bundleIdentifier, privacy: .public) strategy=\(strategy, privacy: .public) coldStart=\(!initiallyRunningBundleIdentifiers.contains(bundleIdentifier)) scriptingIdentifierAvailable=\(scriptingIdentifier != nil) candidateCount=\(candidateCount) identifierOutcome=\(identifierOutcome, privacy: .public) outcome=\(outcome, privacy: .public)."
            )
        }
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

    private static func liveWindowsByCandidateID(
        from applications: [DiscoveredApplication]
    ) -> [(candidate: RestoreWindowCandidate, window: DiscoveredWindow)] {
        var nextIdentifier = 0
        var pairs: [(candidate: RestoreWindowCandidate, window: DiscoveredWindow)] = []

        for application in applications {
            for window in application.windows {
                guard !UnrealProjectResolver.isUntitledHelperWindow(window, bundleIdentifier: application.bundleIdentifier) else {
                    continue
                }
                pairs.append(
                    (
                        RestoreWindowCandidate(
                            id: nextIdentifier,
                            bundleIdentifier: application.bundleIdentifier,
                            pid: application.pid,
                            browserScriptingIdentifier: window.browserScriptingIdentifier,
                            documentURLs: window.documentURLs,
                            documentTitles: window.documentTitles,
                            title: window.title,
                            role: window.role,
                            subrole: window.subrole,
                            frame: window.frame,
                            cgWindowID: window.cgWindowID,
                            isMinimized: window.isMinimized,
                            isModal: window.isModal
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
    let metadataReader: CGWindowMetadataReader
    let settleSleeper: () async -> Void
    let canStack: (RestoreWindowZOrderItem) -> Bool
    let canActivate: (RestoreWindowZOrderItem) -> Bool

    init(
        planner: RestoreWindowZOrderPlanner = RestoreWindowZOrderPlanner(),
        windowApplier: RestoreWindowApplying,
        applicationActivator: RestoreApplicationActivating,
        metadataReader: CGWindowMetadataReader = CGWindowMetadataReader(),
        settleSleeper: @escaping () async -> Void = {
            try? await Task.sleep(nanoseconds: 50_000_000)
        },
        canStack: @escaping (RestoreWindowZOrderItem) -> Bool = { $0.liveWindow.isOnScreen == true },
        canActivate: @escaping (RestoreWindowZOrderItem) -> Bool = { _ in true }
    ) {
        self.planner = planner
        self.windowApplier = windowApplier
        self.applicationActivator = applicationActivator
        self.metadataReader = metadataReader
        self.settleSleeper = settleSleeper
        self.canStack = canStack
        self.canActivate = canActivate
    }

    func restore(_ items: [RestoreWindowZOrderItem]) async {
        let raiseOrder = planner.raiseOrder(for: items)
        for item in raiseOrder {
            guard canStack(item) else { continue }
            // Activation can select a sibling window. Only focus/activate after checking the
            // whole application's fresh Space membership, and check again after AX focus.
            var activationAllowed = canActivate(item)
            var focusResult = RestoreWindowFocusResult(didRaise: false, didSetMain: false, didSetFocused: false)
            var didActivate = false
            if activationAllowed {
                focusResult = windowApplier.focus(item.liveWindow)
                activationAllowed = canStack(item) && canActivate(item)
                if activationAllowed {
                    didActivate = await applicationActivator.activate(processIdentifier: item.processIdentifier)
                }
            }
            guard canStack(item) else { continue }
            let didRaise = windowApplier.raise(item.liveWindow)
            let didSettle = await waitUntilRaised(item, among: raiseOrder)
            let observedOrder = observedOrder(for: raiseOrder)
            AppLogger.restore.info(
                "Window stacking restore bundle=\(item.savedWindow.bundleIdentifier, privacy: .public) windowID=\(item.liveWindow.cgWindowID ?? 0) savedOrder=\(item.savedWindow.zOrderHint ?? -1) activationAllowed=\(activationAllowed) activated=\(didActivate) raised=\(didRaise) settled=\(didSettle) main=\(focusResult.didSetMain) focused=\(focusResult.didSetFocused) observedFrontToBack=\(observedOrder, privacy: .public)."
            )
        }
    }

    private func waitUntilRaised(
        _ item: RestoreWindowZOrderItem,
        among items: [RestoreWindowZOrderItem]
    ) async -> Bool {
        // This verifies order among saved items only, not visibility above unrelated apps.
        guard let windowID = item.liveWindow.cgWindowID else { return false }
        var stableObservations = 0
        for attempt in 0..<20 {
            let metadata = metadataReader.readWindowMetadata(
                processIdentifiers: Set(items.map(\.processIdentifier))
            )
            guard let window = metadata[item.processIdentifier]?.first(where: { $0.windowID == windowID }),
                  let index = window.zOrderHint else { return false }
            let overlappingOrder = items.compactMap { other -> Int? in
                guard let otherID = other.liveWindow.cgWindowID, otherID != windowID,
                      let otherWindow = metadata[other.processIdentifier]?.first(where: { $0.windowID == otherID }),
                      let otherIndex = otherWindow.zOrderHint else { return nil }
                let overlap = window.bounds.intersection(otherWindow.bounds)
                return overlap.width > 0 && overlap.height > 0 ? otherIndex : nil
            }
            guard !overlappingOrder.isEmpty else { return true }

            // Activation and AXRaise can succeed before the WindowServer updates its order.
            // Wait for a stable observed order before another app can overtake this raise.
            if overlappingOrder.allSatisfy({ index < $0 }) {
                stableObservations += 1
                if stableObservations == 3 { return true }
            } else {
                stableObservations = 0
                windowApplier.raise(item.liveWindow)
            }
            if attempt < 19 { await settleSleeper() }
        }
        return false
    }

    private func observedOrder(for items: [RestoreWindowZOrderItem]) -> String {
        guard items.contains(where: { $0.liveWindow.cgWindowID != nil }) else {
            return "unavailable"
        }
        let metadata = metadataReader.readWindowMetadata(
            processIdentifiers: Set(items.map(\.processIdentifier))
        )
        var orderedWindows: [(index: Int, bundle: String)] = []
        for item in items {
            guard let windowID = item.liveWindow.cgWindowID,
                  let window = metadata[item.processIdentifier]?.first(where: { $0.windowID == windowID }),
                  let index = window.zOrderHint else { continue }
            orderedWindows.append((index, item.savedWindow.bundleIdentifier))
        }
        return orderedWindows.sorted { $0.index < $1.index }.map(\.bundle).joined(separator: ",")
    }
}

protocol RestoreApplicationActivating {
    @discardableResult
    func activate(processIdentifier: pid_t) async -> Bool
}

protocol RestoreApplicationLaunching {
    func isAvailable(bundleIdentifier: String) -> Bool
    @discardableResult
    func requestLaunch(bundleIdentifier: String, preferredApplicationURL: URL?) async -> pid_t?
    func launchInstance(bundleIdentifier: String, preferredApplicationURL: URL?) async -> pid_t?
}

extension RestoreApplicationLaunching {
    func launchInstance(bundleIdentifier: String, preferredApplicationURL: URL?) async -> pid_t? { nil }
}

enum RestoreTargetOpenResult {
    // Delivery was accepted; discovery must still confirm the requested content.
    case opened
    case openedApplicationInstance(pid_t)
    case openedNewBrowserWindow(
        CapturedBrowserWindow,
        startupWindows: [CapturedBrowserWindow] = [],
        openedTargetCount: Int? = nil
    )
    case failed(RestoreTargetIssueReason)

    var wasSubmitted: Bool {
        switch self {
        case .openedNewBrowserWindow(_, _, let openedTargetCount):
            return openedTargetCount != 0
        case .opened, .openedApplicationInstance, .failed(.openRequestFailed):
            return true
        case .failed:
            return false
        }
    }
}

enum RestoreTargetOpenDisposition: Equatable {
    case applicationDefault
    case newWindow
    case newBrowserWindow
    case newApplicationInstance
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

        if (Self.codeBasedEditorBundleIdentifiers.contains(bundleIdentifier) || UnityProjectResolver.isUnity(bundleIdentifier: bundleIdentifier)),
           let firstLocalTarget = indexedLocalTargets.first {
            indexedRequests.append((
                firstLocalTarget.offset,
                RestoreTargetOpenRequest(
                    targets: indexedLocalTargets.map(\.element),
                    disposition: UnityProjectResolver.isUnity(bundleIdentifier: bundleIdentifier) ? .applicationDefault : .newWindow
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
    func open(targets: [WindowOpenTarget], bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition, preferredApplicationURL: URL?) async -> RestoreTargetOpenResult
    func openBrowserWindow(targets: [WindowOpenTarget], bundleIdentifier: String,
        excludingWindowIdentifiers: Set<String>, preferredApplicationURL: URL?,
        remainingWindowTargets: [[WindowOpenTarget]]) async -> RestoreTargetOpenResult
}

extension RestoreTargetOpening {
    func openBrowserWindow(targets: [WindowOpenTarget], bundleIdentifier: String,
        excludingWindowIdentifiers: Set<String>, preferredApplicationURL: URL?,
        remainingWindowTargets: [[WindowOpenTarget]]) async -> RestoreTargetOpenResult {
        await open(targets: targets, bundleIdentifier: bundleIdentifier, disposition: .newBrowserWindow,
            preferredApplicationURL: preferredApplicationURL)
    }
}

struct NSWorkspaceRestoreTargetOpener: RestoreTargetOpening {
    private let applicationURLProvider: (String) -> URL?
    private let commandRunner: (URL, [String]) async -> Bool
    private let browserWindowOpener: BrowserWindowOpening
    private let workspaceOpener:
        ([URL], URL, NSWorkspace.OpenConfiguration) async -> Bool
    private let instanceWorkspaceOpener:
        ([URL], URL, NSWorkspace.OpenConfiguration) async -> pid_t?
    private let runningUnityProjectsProvider: () -> Set<URL>

    init(
        workspace: NSWorkspace = .shared,
        applicationURLProvider: ((String) -> URL?)? = nil,
        commandRunner: @escaping (URL, [String]) async -> Bool = Self.runCommand,
        browserWindowOpener: BrowserWindowOpening? = nil,
        workspaceOpener:
            (([URL], URL, NSWorkspace.OpenConfiguration) async -> Bool)? = nil,
        instanceWorkspaceOpener:
            (([URL], URL, NSWorkspace.OpenConfiguration) async -> pid_t?)? = nil,
        runningUnityProjectsProvider: (() -> Set<URL>)? = nil
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
        self.instanceWorkspaceOpener = instanceWorkspaceOpener ?? { urls, applicationURL, configuration in
            await withCheckedContinuation { continuation in
                let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                    continuation.resume(returning: error == nil ? app?.processIdentifier : nil)
                }
                if urls.isEmpty {
                    workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: completion)
                } else {
                    workspace.open(urls, withApplicationAt: applicationURL, configuration: configuration, completionHandler: completion)
                }
            }
        }
        self.runningUnityProjectsProvider = runningUnityProjectsProvider ?? {
            let resolver = UnityProjectResolver()
            return Set(workspace.runningApplications.compactMap { application in
                guard application.bundleIdentifier.map(UnityProjectResolver.isUnity(bundleIdentifier:)) == true,
                    !application.isTerminated, application.activationPolicy == .regular else { return nil }
                return resolver.resolve(processIdentifier: application.processIdentifier, documentURL: nil)
            })
        }
    }

    func open(targets: [WindowOpenTarget], bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition, preferredApplicationURL: URL? = nil) async -> RestoreTargetOpenResult {
        await open(targets: targets, bundleIdentifier: bundleIdentifier, disposition: disposition,
            excludingWindowIdentifiers: [], preferredApplicationURL: preferredApplicationURL)
    }

    func openBrowserWindow(targets: [WindowOpenTarget], bundleIdentifier: String,
        excludingWindowIdentifiers: Set<String>, preferredApplicationURL: URL? = nil,
        remainingWindowTargets: [[WindowOpenTarget]] = []) async -> RestoreTargetOpenResult {
        await open(targets: targets, bundleIdentifier: bundleIdentifier, disposition: .newBrowserWindow,
            excludingWindowIdentifiers: excludingWindowIdentifiers, preferredApplicationURL: preferredApplicationURL,
            remainingWindowTargets: remainingWindowTargets)
    }

    private func open(targets: [WindowOpenTarget], bundleIdentifier: String,
        disposition: RestoreTargetOpenDisposition, excludingWindowIdentifiers: Set<String>,
        preferredApplicationURL: URL?, remainingWindowTargets: [[WindowOpenTarget]] = []) async -> RestoreTargetOpenResult {
        let preferredInstallation = preferredApplicationURL?.validatedApplicationBundleURL(
            withBundleIdentifier: bundleIdentifier)
        let applicationURL = preferredInstallation ?? applicationURLProvider(bundleIdentifier)
        if UnityProjectResolver.isUnity(bundleIdentifier: bundleIdentifier) {
            return await openUnityProject(targets: targets, preferredApplicationURL: applicationURL)
        }
        guard let applicationURL else {
            return .failed(.applicationUnavailable)
        }

        if UnrealProjectResolver.isUnreal(bundleIdentifier: bundleIdentifier) {
            guard let target = targets.first, target.kind == .file,
                let project = UnrealProjectResolver().projectURL(target.url),
                targets.allSatisfy({ $0.kind == .file && $0.url.isFileURL &&
                    $0.url.standardizedFileURL == project }) else { return .failed(.unsupportedTarget) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.promptsUserIfNeeded = true
            // File delivery opens the project but omits its path from the new process's arguments.
            configuration.arguments = [project.path]
            guard let pid = await instanceWorkspaceOpener([], applicationURL, configuration), pid > 0 else {
                return .failed(.openRequestFailed)
            }
            return .openedApplicationInstance(pid)
        }

        if disposition == .newBrowserWindow,
           let browser = BrowserAutomationBrowser.allCases.first(
               where: { $0.bundleIdentifier == bundleIdentifier }
           ) {
            let result = await browserWindowOpener.openNewWindow(
                targets: targets,
                browser: browser,
                excludingWindowIdentifiers: excludingWindowIdentifiers,
                preferredApplicationURL: preferredInstallation,
                remainingWindowTargets: remainingWindowTargets
            )
            if case let .opened(openedWindow, startupWindows, openedTargetCount) = result {
                return .openedNewBrowserWindow(
                    openedWindow,
                    startupWindows: startupWindows,
                    openedTargetCount: openedTargetCount
                )
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
        configuration.createsNewApplicationInstance = disposition == .newApplicationInstance
        configuration.allowsRunningApplicationSubstitution = preferredInstallation == nil && disposition != .newApplicationInstance
        configuration.promptsUserIfNeeded = true

        if disposition == .newApplicationInstance {
            guard let pid = await instanceWorkspaceOpener(targets.map(\.url), applicationURL, configuration) else {
                return .failed(.openRequestFailed)
            }
            return .openedApplicationInstance(pid)
        }

        var deliveryURLs = targets.map(\.url)
        if BrowserAutomationBrowser.allCases.contains(where: { $0.bundleIdentifier == bundleIdentifier && $0.isChromium }),
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

    private func openUnityProject(targets: [WindowOpenTarget], preferredApplicationURL: URL?) async -> RestoreTargetOpenResult {
        let resolver = UnityProjectResolver()
        let projects = targets.compactMap { resolver.projectURL(containing: $0.url) }
        guard !targets.isEmpty, projects.count == targets.count, let project = projects.first,
            projects.allSatisfy({ $0 == project }), targets.allSatisfy({ $0.kind != .webURL }) else {
            return .failed(.unsupportedTarget)
        }
        let documents = targets.filter { $0.kind == .file }
        guard documents.count <= 1,
            documents.allSatisfy({ ["unity", "unitypackage"].contains($0.url.pathExtension.lowercased()) }) else {
            return .failed(.unsupportedTarget)
        }
        // Native file delivery can select a different running Unity project and replace
        // its unsaved scene. Never deliver to an arbitrary existing Editor.
        guard !runningUnityProjectsProvider().contains(project) else { return .failed(.openingNotConfirmed) }
        guard let editor = resolver.editorURL(projectURL: project,
            preferredApplicationURL: preferredApplicationURL) ?? resolver.editorURL(projectURL: project,
                preferredApplicationURL: applicationURLProvider("com.unity3d.UnityEditor5.x")) else {
            return .failed(.applicationUnavailable)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = true
        configuration.arguments = ["-projectPath", project.path]
        if let document = documents.first { configuration.arguments += ["-openfile", document.url.path] }
        guard let pid = await instanceWorkspaceOpener([], editor, configuration), pid > 0 else {
            return .failed(.openRequestFailed)
        }
        return .openedApplicationInstance(pid)
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
    private let applicationURLProvider: (String) -> URL?
    private let applicationOpener: (URL, NSWorkspace.OpenConfiguration) async -> pid_t?

    init(workspace: NSWorkspace = .shared,
        applicationURLProvider: ((String) -> URL?)? = nil,
        applicationOpener: ((URL, NSWorkspace.OpenConfiguration) async -> pid_t?)? = nil) {
        self.applicationURLProvider = applicationURLProvider ?? {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        self.applicationOpener = applicationOpener ?? { applicationURL, configuration in
            await withCheckedContinuation { continuation in
                workspace.openApplication(at: applicationURL, configuration: configuration) { app, error in
                    continuation.resume(returning: error == nil ? app?.processIdentifier : nil)
                }
            }
        }
    }

    func isAvailable(bundleIdentifier: String) -> Bool {
        applicationURLProvider(bundleIdentifier).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func requestLaunch(bundleIdentifier: String, preferredApplicationURL: URL? = nil) async -> pid_t? {
        await launch(bundleIdentifier: bundleIdentifier, preferredApplicationURL: preferredApplicationURL,
            createsNewApplicationInstance: false)
    }

    func launchInstance(bundleIdentifier: String, preferredApplicationURL: URL? = nil) async -> pid_t? {
        await launch(bundleIdentifier: bundleIdentifier, preferredApplicationURL: preferredApplicationURL,
            createsNewApplicationInstance: true)
    }

    private func launch(bundleIdentifier: String, preferredApplicationURL: URL?,
        createsNewApplicationInstance: Bool) async -> pid_t? {
        let preferredInstallation = preferredApplicationURL?.validatedApplicationBundleURL(
            withBundleIdentifier: bundleIdentifier)
        guard let applicationURL = preferredInstallation ?? applicationURLProvider(bundleIdentifier) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = createsNewApplicationInstance
        configuration.allowsRunningApplicationSubstitution = preferredInstallation == nil && !createsNewApplicationInstance
        configuration.promptsUserIfNeeded = true
        return await applicationOpener(applicationURL, configuration)
    }
}

struct AXRestoreApplicationActivator: RestoreApplicationActivating {
    @MainActor
    func activate(processIdentifier: pid_t) async -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ) else {
            return false
        }

        // AppKit can decline activation from a background menu-bar app. Restore already
        // has Accessibility authorization, and the caller checks the app's Space membership.
        let error = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard error == .success else {
            AppLogger.restore.info("Application activation pid=\(processIdentifier) AXFrontmost error=\(error.rawValue).")
            return false
        }
        for _ in 0..<20 {
            if application.isActive {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return application.isActive
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

struct OpenWebTargetIndex {
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

    mutating func replaceStartupWindows(
        _ windows: [CapturedBrowserWindow],
        consuming targets: [WindowOpenTarget],
        bundleIdentifier: String
    ) {
        let startupIndex = OpenWebTargetIndex(
            captureResult: BrowserTabCaptureResult(windows: windows, issues: [])
        )
        countsByBundleIdentifier[bundleIdentifier] =
            startupIndex.countsByBundleIdentifier[bundleIdentifier]
        for target in targets {
            _ = consume(target, bundleIdentifier: bundleIdentifier)
        }
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

        return [url.absoluteString, path, abbreviatedPath].contains { candidate in
            ranges(of: candidate).contains { range in
                (range.lowerBound == startIndex || self[index(before: range.lowerBound)].isLocalPathReferenceBoundary) &&
                (range.upperBound == endIndex || self[range.upperBound].isLocalPathReferenceBoundary)
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
        isWhitespace || [":", "|", "(", ")", "[", "]", "{", "}", "\"", "'", "—", "–"].contains(self)
    }
}

private extension DiscoveredApplication {
    func hasUnreadyLocalTarget(_ target: WindowOpenTarget) -> Bool {
        guard target.kind != .webURL, target.url.isFileURL,
            !windows.contains(where: { $0.role == "AXWindow" && $0.subrole == "AXStandardWindow" }) else { return false }
        return windows.contains { window in
            window.role == "AXWindow" && window.subrole == "AXUnknown" &&
                window.documentURLs.contains { $0.isFileURL && $0.standardizedFileURL == target.url.standardizedFileURL }
        }
    }
}

private extension UnexposedApplicationWindows {
    func referencesLocalTarget(_ target: WindowOpenTarget) -> Bool {
        target.kind != .webURL && target.url.isFileURL && documentURLs.contains {
            $0.isFileURL && $0.standardizedFileURL == target.url.standardizedFileURL
        }
    }

    func hasUnexposedOrdinaryWindow(membership: (CGWindowID) -> Set<UInt64>?,
        excludingWindowID: CGWindowID? = nil) -> Bool {
        // CG records can outlive closed windows. Unknown membership still blocks.
        windows.contains {
            $0.windowID != excludingWindowID &&
                $0.processIdentifier == pid && $0.windowID != 0 && $0.layer == 0 &&
                $0.bounds.width > 0 && $0.bounds.height > 0 &&
                $0.bounds.origin.x.isFinite && $0.bounds.origin.y.isFinite &&
                $0.bounds.width.isFinite && $0.bounds.height.isFinite &&
                (membership($0.windowID)?.isEmpty != true)
        }
    }
}

struct RestoreWindowCandidate {
    let id: Int
    let bundleIdentifier: String
    let pid: pid_t
    let browserScriptingIdentifier: String?
    let documentURLs: [URL]
    let documentTitles: [String]
    let title: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    var cgWindowID: CGWindowID? = nil
    var isMinimized: Bool = false
    var isModal: Bool? = nil

    func matchesMinimizedAppWindow(_ savedWindow: WindowRecord) -> Bool {
        // Some app windows report AXDialog while minimized. Require the same saved identity,
        // confirmed through fresh AX/CG discovery, rather than treating any dialog as an app window.
        role == "AXWindow" && subrole == "AXDialog" && isMinimized && isModal == false &&
            savedWindow.role == "AXWindow" &&
            (savedWindow.subrole == "AXStandardWindow" || savedWindow.captureSignature.source == .coreGraphics) &&
            pid > 0 && pid == savedWindow.pidAtCapture && pid == savedWindow.captureSignature.owningPid &&
            cgWindowID != nil && cgWindowID != 0 && cgWindowID == savedWindow.captureSignature.cgWindowID
    }

    func referencesLocalTarget(_ target: WindowOpenTarget) -> Bool {
        guard target.kind != .webURL, target.url.isFileURL else { return false }
        let url = target.url.standardizedFileURL
        return documentURLs.contains { $0.isFileURL && $0.standardizedFileURL == url } ||
            documentTitles.contains { $0.referencesLocalURL(url) }
    }
}

struct RestoreWindowPlan {
    let savedWindow: WindowRecord
    let candidate: RestoreWindowCandidate?
    let matchStrategy: RestoreWindowMatchStrategy?
    let skip: RestoreSkip?
}

enum RestoreWindowMatchStrategy: String {
    case browserIdentifier
    case singleton
    case scored
}

struct RestoreWindowMatchPlanner {
    func plans(
        for savedWindows: [WindowRecord],
        candidates: [RestoreWindowCandidate],
        runningBundleIdentifiers: Set<String>? = nil,
        genericColdOpenedBrowserWindowIDs: Set<UUID> = [],
        preferredBrowserScriptingIdentifiers: [UUID: String] = [:],
        openedBrowserWindowIDs: Set<UUID> = [],
        preferredProcessIdentifiers: [UUID: pid_t] = [:],
        preferredCandidateIdentifiers: [UUID: Int] = [:],
        requiresRuntimeRole: Bool = false
    ) -> [RestoreWindowPlan] {
        let runningBundleIdentifiers = runningBundleIdentifiers ?? Set(candidates.map(\.bundleIdentifier))
        var plans = Array<RestoreWindowPlan?>(repeating: nil, count: savedWindows.count)
        var matchableSavedWindows: [String: [(index: Int, window: WindowRecord)]] = [:]

        for (index, savedWindow) in savedWindows.enumerated() {
            guard runningBundleIdentifiers.contains(savedWindow.bundleIdentifier) else {
                plans[index] = RestoreWindowPlan(
                    savedWindow: savedWindow,
                    candidate: nil,
                    matchStrategy: nil,
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
            var assignments = preferredAssignments(
                for: savedWindowsForBundle,
                from: candidatesForBundle,
                preferredBrowserScriptingIdentifiers: preferredBrowserScriptingIdentifiers
            )
            var matchStrategies = Dictionary(
                uniqueKeysWithValues: assignments.keys.map { ($0, RestoreWindowMatchStrategy.browserIdentifier) }
            )
            let assignedCandidateIDs = Set(assignments.values.map(\.id))
            let remainingSavedWindows = savedWindowsForBundle.filter {
                assignments[$0.index] == nil &&
                    !openedBrowserWindowIDs.contains($0.window.id)
            }
            let remainingCandidates = candidatesForBundle.filter {
                !assignedCandidateIDs.contains($0.id)
            }
            let scoredAssignments = bestAssignments(
                for: remainingSavedWindows,
                from: remainingCandidates,
                preferredProcessIdentifiers: preferredProcessIdentifiers,
                preferredCandidateIdentifiers: preferredCandidateIdentifiers,
                requiresRuntimeRole: requiresRuntimeRole
            )
            assignments.merge(
                scoredAssignments,
                uniquingKeysWith: { preferred, _ in preferred }
            )
            for index in scoredAssignments.keys where matchStrategies[index] == nil {
                matchStrategies[index] = .scored
            }

            for savedWindow in savedWindowsForBundle where assignments[savedWindow.index] == nil {
                let pid = preferredProcessIdentifiers[savedWindow.window.id]
                let savedCount = savedWindowsForBundle.count {
                    pid == nil || preferredProcessIdentifiers[$0.window.id] == pid
                }
                let singletonCandidates = candidatesForBundle.filter { pid == nil || $0.pid == pid }
                guard savedCount == 1,
                    singletonCandidates.count == 1,
                    let candidate = singletonCandidates.first,
                    !assignments.values.contains(where: { $0.id == candidate.id }),
                    preferredCandidateIdentifiers[savedWindow.window.id].map({ $0 == candidate.id }) != false,
                    canUseSingletonFallback(
                        for: savedWindow.window,
                        candidate: candidate,
                        preferredProcessIdentifier: pid,
                        genericColdOpenedBrowserWindowIDs: genericColdOpenedBrowserWindowIDs,
                        openedBrowserWindowIDs: openedBrowserWindowIDs
                    ) else { continue }
                assignments[savedWindow.index] = candidate
                matchStrategies[savedWindow.index] = .singleton
            }

            for (index, savedWindow) in savedWindowsForBundle {
                if let candidate = assignments[index] {
                    plans[index] = RestoreWindowPlan(
                        savedWindow: savedWindow,
                        candidate: candidate,
                        matchStrategy: matchStrategies[index],
                        skip: nil
                    )
                } else {
                    plans[index] = RestoreWindowPlan(
                        savedWindow: savedWindow,
                        candidate: nil,
                        matchStrategy: nil,
                        skip: RestoreSkip(
                            bundleIdentifier: savedWindow.bundleIdentifier,
                            windowTitle: savedWindow.windowTitle,
                            reason: openedBrowserWindowIDs.contains(savedWindow.id)
                                ? RestoreSkipReason.openedBrowserWindowNotIdentified
                                : RestoreSkipReason.windowNotFound
                        )
                    )
                }
            }
        }

        return savedWindows.enumerated().map { index, savedWindow in
            plans[index] ?? RestoreWindowPlan(
                savedWindow: savedWindow,
                candidate: nil,
                matchStrategy: nil,
                skip: RestoreSkip(
                    bundleIdentifier: savedWindow.bundleIdentifier,
                    windowTitle: savedWindow.windowTitle,
                    reason: openedBrowserWindowIDs.contains(savedWindow.id)
                        ? RestoreSkipReason.openedBrowserWindowNotIdentified
                        : RestoreSkipReason.windowNotFound
                )
            )
        }
    }

    private func preferredAssignments(
        for savedWindows: [(index: Int, window: WindowRecord)],
        from candidates: [RestoreWindowCandidate],
        preferredBrowserScriptingIdentifiers: [UUID: String]
    ) -> [Int: RestoreWindowCandidate] {
        let preferredSavedWindows = Dictionary(grouping: savedWindows) {
            preferredBrowserScriptingIdentifiers[$0.window.id]
        }
        let candidatesByIdentifier = Dictionary(grouping: candidates) {
            $0.browserScriptingIdentifier
        }
        var assignments: [Int: RestoreWindowCandidate] = [:]

        for (identifier, matchingSavedWindows) in preferredSavedWindows {
            guard let identifier,
                  matchingSavedWindows.count == 1,
                  let matchingCandidates = candidatesByIdentifier[identifier],
                  matchingCandidates.count == 1,
                  let savedWindow = matchingSavedWindows.first,
                  let candidate = matchingCandidates.first else {
                continue
            }
            assignments[savedWindow.index] = candidate
        }

        return assignments
    }

    private func canUseSingletonFallback(
        for savedWindow: WindowRecord,
        candidate: RestoreWindowCandidate,
        preferredProcessIdentifier: pid_t?,
        genericColdOpenedBrowserWindowIDs: Set<UUID>,
        openedBrowserWindowIDs: Set<UUID>
    ) -> Bool {
        guard !savedWindow.openingConfiguration.effectiveTargets.contains(where: { $0.kind != .webURL }) else {
            return false
        }
        let minimizedAppWindow = candidate.matchesMinimizedAppWindow(savedWindow)
        guard savedWindow.role == kAXWindowRole as String,
              candidate.role == kAXWindowRole as String,
              candidate.subrole == kAXStandardWindowSubrole as String || minimizedAppWindow else {
            return false
        }
        if savedWindow.captureSignature.source == .coreGraphics, savedWindow.subrole == nil,
            savedWindow.openingConfiguration.effectiveTargets.isEmpty {
            return preferredProcessIdentifier == candidate.pid
        }
        // Mail can expose its minimized main window as AXDialog, then AXStandardWindow after relaunch.
        let minimizedMailWindow = savedWindow.bundleIdentifier == "com.apple.mail" &&
            savedWindow.isMinimized && savedWindow.subrole == kAXDialogSubrole as String
        guard savedWindow.subrole == candidate.subrole || minimizedMailWindow || minimizedAppWindow else { return false }

        if openedBrowserWindowIDs.contains(savedWindow.id) {
            return genericColdOpenedBrowserWindowIDs.contains(savedWindow.id)
        }
        return true
    }

    private func bestAssignments(
        for savedWindows: [(index: Int, window: WindowRecord)],
        from candidates: [RestoreWindowCandidate],
        preferredProcessIdentifiers: [UUID: pid_t],
        preferredCandidateIdentifiers: [UUID: Int],
        requiresRuntimeRole: Bool
    ) -> [Int: RestoreWindowCandidate] {
        let scoredMatches = savedWindows.flatMap { savedWindow in
            candidates.compactMap { candidate in
                scoredMatch(
                    savedIndex: savedWindow.index,
                    savedWindow: savedWindow.window,
                    candidate: candidate,
                    preferredProcessIdentifier: preferredProcessIdentifiers[savedWindow.window.id],
                    preferredCandidateIdentifier: preferredCandidateIdentifiers[savedWindow.window.id],
                    requiresRuntimeRole: requiresRuntimeRole
                )
            }
        }
        .sorted()

        var savedIndexByCandidateID: [Int: Int] = [:]
        var assignments: [Int: RestoreWindowCandidate] = [:]

        for scoredMatch in scoredMatches {
            guard assignments[scoredMatch.savedIndex] == nil,
                  savedIndexByCandidateID[scoredMatch.candidate.id] == nil else {
                continue
            }

            savedIndexByCandidateID[scoredMatch.candidate.id] = scoredMatch.savedIndex
            assignments[scoredMatch.savedIndex] = scoredMatch.candidate
        }

        // Keep the preferred matches unless an unmatched local document needs one.
        // Only other local-document matches may move; web-only and position-only matches stay fixed.
        let localWindowIndexes = Set(savedWindows.filter {
            $0.window.openingConfiguration.effectiveTargets.contains { $0.kind != .webURL }
        }.map(\.index))
        let matchesBySavedIndex = Dictionary(grouping: scoredMatches, by: \.savedIndex)
        func reserve(_ savedIndex: Int, visited: inout Set<Int>) -> Bool {
            guard localWindowIndexes.contains(savedIndex) else { return false }
            for match in matchesBySavedIndex[savedIndex, default: []] where visited.insert(match.candidate.id).inserted {
                if let previous = savedIndexByCandidateID[match.candidate.id],
                    !reserve(previous, visited: &visited) { continue }
                savedIndexByCandidateID[match.candidate.id] = savedIndex
                assignments[savedIndex] = match.candidate
                return true
            }
            return false
        }
        for savedWindow in savedWindows where assignments[savedWindow.index] == nil {
            var visited: Set<Int> = []
            _ = reserve(savedWindow.index, visited: &visited)
        }

        return assignments
    }

    private func scoredMatch(
        savedIndex: Int,
        savedWindow: WindowRecord,
        candidate: RestoreWindowCandidate,
        preferredProcessIdentifier: pid_t?,
        preferredCandidateIdentifier: Int?,
        requiresRuntimeRole: Bool
    ) -> RestoreWindowScoredMatch? {
        if let preferredProcessIdentifier, candidate.pid != preferredProcessIdentifier { return nil }
        if let preferredCandidateIdentifier, candidate.id != preferredCandidateIdentifier { return nil }
        if requiresRuntimeRole || preferredProcessIdentifier != nil, savedWindow.role == kAXWindowRole as String,
            savedWindow.subrole == kAXStandardWindowSubrole as String {
            guard candidate.role == kAXWindowRole as String,
                candidate.subrole == kAXStandardWindowSubrole as String else { return nil }
        }
        let savedFrame = savedWindow.frame.cgRect
        let distance = candidate.frame.restoreDistance(to: savedFrame)
        let pidMatches = candidate.pid == (preferredProcessIdentifier ?? savedWindow.pidAtCapture)
        let validator = WindowOpenTargetValidator()
        let savedTargetURLs = Set(
            savedWindow.openingConfiguration.matchingTargets.compactMap { target in
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
        let requiredLocalTargets = savedWindow.openingConfiguration.effectiveTargets.filter { $0.kind != .webURL }
        guard requiredLocalTargets.isEmpty || requiredLocalTargets.contains(where: candidate.referencesLocalTarget) else { return nil }
        if UnityProjectResolver.isUnity(bundleIdentifier: savedWindow.bundleIdentifier) {
            // Project identity complements a saved scene; it cannot stand in for that scene.
            let scenes = requiredLocalTargets.filter { $0.kind == .file }
            guard scenes.allSatisfy(candidate.referencesLocalTarget) else { return nil }
        }
        let localTitleTargetMatches = savedTargetURLs.contains { savedURL in
            savedURL.isFileURL && candidate.documentTitles.contains {
                $0.referencesLocalURL(savedURL)
            }
        }
        let targetMatches = localTitleTargetMatches ||
            !savedTargetURLs.isDisjoint(with: candidateTargetURLs)
        let savedTitle = savedWindow.windowTitle?.nonEmptyRestoreValue
        let titleMatches = savedTitle != nil &&
            candidate.title?.nonEmptyRestoreValue == savedTitle
        if savedWindow.captureSignature.source == .coreGraphics {
            // CG capture cannot establish an AX role. A fresh standard AX window is required.
            guard candidate.role == kAXWindowRole as String,
                candidate.subrole == kAXStandardWindowSubrole as String,
                !requiredLocalTargets.isEmpty || titleMatches || preferredCandidateIdentifier != nil else { return nil }
        }
        let roleMatches = candidate.role == savedWindow.role &&
            (candidate.subrole == savedWindow.subrole || savedWindow.captureSignature.source == .coreGraphics)
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
    ) async throws -> RestoreWindowApplyResult

    func restoreFrame(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult

    @discardableResult
    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult
}

extension RestoreWindowApplying {
    func restoreFrame(savedWindow: WindowRecord, targetFrame: CGRect, to discoveredWindow: DiscoveredWindow) async throws -> RestoreWindowApplyResult {
        try await apply(savedWindow: savedWindow, targetFrame: targetFrame, to: discoveredWindow)
    }
}

protocol RestoreWindowGeometryAccessing {
    func point(from element: AXUIElement, attribute: CFString) -> CGPoint?
    func size(from element: AXUIElement, attribute: CFString) -> CGSize?
    func setPoint(_ point: CGPoint, on element: AXUIElement, attribute: CFString) -> Bool
    func setSize(_ size: CGSize, on element: AXUIElement, attribute: CFString) -> Bool
}

extension AXAttributeReader: RestoreWindowGeometryAccessing {}

struct RestoreWindowApplyResult {
    let didRestore: Bool
    let downgrade: RestoreDowngrade?
    let failureReason: String?
    let attemptCount: Int
    let finalObservedFrame: CGRect?

    static func restored(
        downgrade: RestoreDowngrade? = nil,
        attemptCount: Int = 0,
        finalObservedFrame: CGRect? = nil
    ) -> RestoreWindowApplyResult {
        RestoreWindowApplyResult(
            didRestore: true,
            downgrade: downgrade,
            failureReason: nil,
            attemptCount: attemptCount,
            finalObservedFrame: finalObservedFrame
        )
    }

    static func failed(
        reason: String,
        attemptCount: Int = 0,
        finalObservedFrame: CGRect? = nil
    ) -> RestoreWindowApplyResult {
        RestoreWindowApplyResult(
            didRestore: false,
            downgrade: nil,
            failureReason: reason,
            attemptCount: attemptCount,
            finalObservedFrame: finalObservedFrame
        )
    }
}

struct RestoreWindowFocusResult {
    let didRaise: Bool
    let didSetMain: Bool
    let didSetFocused: Bool
}

struct AXRestoreWindowApplier: RestoreWindowApplying {
    private let geometryAccessor: RestoreWindowGeometryAccessing
    private let attributeReader: AXAttributeReader
    private let setMinimized: (Bool, AXUIElement) -> Bool
    private let attemptLimit: Int
    private let settleNanoseconds: UInt64
    private let sleeper: (UInt64) async throws -> Void

    init(
        geometryAccessor: RestoreWindowGeometryAccessing = AXAttributeReader(),
        attributeReader: AXAttributeReader = AXAttributeReader(),
        setMinimized: ((Bool, AXUIElement) -> Bool)? = nil,
        attemptLimit: Int = restoreWindowApplyAttemptLimit,
        settleNanoseconds: UInt64 = restoreWindowSettleNanoseconds,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:)
    ) {
        self.geometryAccessor = geometryAccessor
        self.attributeReader = attributeReader
        self.setMinimized = setMinimized ?? {
            attributeReader.setBool($0, on: $1, attribute: kAXMinimizedAttribute as CFString)
        }
        self.attemptLimit = attemptLimit
        self.settleNanoseconds = settleNanoseconds
        self.sleeper = sleeper
    }

    func apply(
        savedWindow: WindowRecord,
        targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow
    ) async throws -> RestoreWindowApplyResult {
        try Task.checkCancellation()

        if savedWindow.isMinimized, discoveredWindow.isMinimized,
           attributeReader.bool(from: discoveredWindow.axElement, attribute: kAXMinimizedAttribute as CFString) == true,
           let frame = observedFrame(of: discoveredWindow.axElement),
           frame.approximatelyMatchesRestoreFrame(targetFrame) {
            return .restored(downgrade: fullscreenDowngrade(for: savedWindow), finalObservedFrame: frame)
        }

        if discoveredWindow.isMinimized, !setMinimized(false, discoveredWindow.axElement) {
            return .failed(reason: RestoreSkipReason.restoreFailed)
        }

        let result: RestoreWindowApplyResult
        do {
            result = try await applyFrame(savedWindow: savedWindow, targetFrame: targetFrame,
                to: discoveredWindow, attempts: attemptLimit)
        } catch {
            if savedWindow.isMinimized { _ = setMinimized(true, discoveredWindow.axElement) }
            throw error
        }

        if savedWindow.isMinimized, !setMinimized(true, discoveredWindow.axElement) {
            return .failed(reason: RestoreSkipReason.restoreFailed, attemptCount: result.attemptCount,
                finalObservedFrame: result.finalObservedFrame)
        }
        return result
    }

    func restoreFrame(savedWindow: WindowRecord, targetFrame: CGRect, to discoveredWindow: DiscoveredWindow) async throws -> RestoreWindowApplyResult {
        try await applyFrame(savedWindow: savedWindow, targetFrame: targetFrame, to: discoveredWindow, attempts: 1)
    }

    private func applyFrame(savedWindow: WindowRecord, targetFrame: CGRect,
        to discoveredWindow: DiscoveredWindow, attempts: Int) async throws -> RestoreWindowApplyResult {
        var lastObservedFrame: CGRect?
        for attemptIndex in 0..<attempts {
            try Task.checkCancellation()
            applyGeometry(targetFrame, to: discoveredWindow.axElement)

            lastObservedFrame = observedFrame(of: discoveredWindow.axElement)
            try await sleeper(settleNanoseconds)
            try Task.checkCancellation()

            lastObservedFrame = observedFrame(of: discoveredWindow.axElement)
            if lastObservedFrame?.approximatelyMatchesRestoreFrame(targetFrame) == true {
                return .restored(
                    downgrade: fullscreenDowngrade(for: savedWindow),
                    attemptCount: attemptIndex + 1,
                    finalObservedFrame: lastObservedFrame
                )
            }
        }

        let actualFrameDescription = lastObservedFrame.map(String.init(describing:)) ?? "unavailable"
        AppLogger.app.error(
            "Window geometry did not settle for \(savedWindow.bundleIdentifier). Expected \(String(describing: targetFrame)); observed \(actualFrameDescription)."
        )
        return .failed(
            reason: RestoreSkipReason.windowGeometryDidNotSettle,
            attemptCount: attempts,
            finalObservedFrame: lastObservedFrame
        )
    }

    private func applyGeometry(_ frame: CGRect, to element: AXUIElement) {
        _ = geometryAccessor.setPoint(
            frame.origin,
            on: element,
            attribute: kAXPositionAttribute as CFString
        )
        _ = geometryAccessor.setSize(
            frame.size,
            on: element,
            attribute: kAXSizeAttribute as CFString
        )
        _ = geometryAccessor.setPoint(
            frame.origin,
            on: element,
            attribute: kAXPositionAttribute as CFString
        )
    }

    private func observedFrame(of element: AXUIElement) -> CGRect? {
        guard let position = geometryAccessor.point(
            from: element,
            attribute: kAXPositionAttribute as CFString
        ),
        let size = geometryAccessor.size(
            from: element,
            attribute: kAXSizeAttribute as CFString
        ) else {
            return nil
        }

        return CGRect(origin: position, size: size)
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
    static let appNotFound = "app not found"
    static let appNotRunning = "app not running"
    static let windowNotFound = "window not found"
    static let openedBrowserWindowNotIdentified = "opened browser window could not be identified"
    static let desktopUnconfirmed = "window desktop could not be confirmed"
    static let inspectionNotReturned = "inspected window could not be returned"
    static let restoreFailed = "restore failed"
    static let windowGeometryDidNotSettle = "window geometry did not settle"
    static let appInstanceUnconfirmed = "separate app instance could not be confirmed"
}

enum RestoreDowngradeReason {
    static let windowIdentityUnconfirmed = "window identity could not be confirmed"
}

private extension CGRect {
    func approximatelyMatchesRestoreFrame(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= restoreFrameVerificationTolerance &&
            abs(minY - other.minY) <= restoreFrameVerificationTolerance &&
            abs(width - other.width) <= restoreFrameVerificationTolerance &&
            abs(height - other.height) <= restoreFrameVerificationTolerance
    }

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
