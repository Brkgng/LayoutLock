import AppKit
import Foundation

private let excludedSnapshotBundleIdentifiers: Set<String> = [
    "com.apple.finder"
]

enum SnapshotCaptureServiceError: LocalizedError {
    case noDisplaysAvailable
    case noWindowsAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplaysAvailable:
            return "No active displays were available for layout capture."
        case .noWindowsAvailable:
            return "No windows were available to capture. Unhide or restore a window, then try again."
        }
    }
}

struct SnapshotCaptureService {
    struct CaptureResult {
        let snapshot: Snapshot
        let browserCaptureIssues: [BrowserCaptureIssue]
    }

    struct UpdateResult {
        let snapshot: Snapshot
        let unmatchedManualConfigurationCount: Int
        let browserCaptureIssues: [BrowserCaptureIssue]
    }

    struct CaptureContext {
        let runningApplications: [RunningApplicationSnapshot]
        let screens: [DisplayResolver.ScreenSnapshot]

        @MainActor
        static func current() -> CaptureContext {
            CaptureContext(
                runningApplications: NSWorkspace.shared.runningApplications.map(RunningApplicationSnapshot.init),
                screens: DisplayResolver.ScreenSnapshot.currentScreens()
            )
        }
    }

    let windowDiscoveryEngine: WindowDiscoveryEngine
    let displayResolver: DisplayResolver
    let snapshotStore: SnapshotStore
    let telemetryLogger: TelemetryLogging
    private let browserTabCapturer: BrowserTabCapturing
    private let discoveryResultProvider: (() throws -> WindowDiscoveryResult)?
    private let restoreSpaceAccess: RestoreSpaceAccess

    init(
        windowDiscoveryEngine: WindowDiscoveryEngine = WindowDiscoveryEngine(),
        displayResolver: DisplayResolver = DisplayResolver(),
        snapshotStore: SnapshotStore,
        telemetryLogger: TelemetryLogging = NoOpTelemetryLogger(),
        browserTabCapturer: BrowserTabCapturing = BrowserTabCaptureService(),
        discoveryResultProvider: (() throws -> WindowDiscoveryResult)? = nil,
        restoreSpaceAccess: RestoreSpaceAccess = .live
    ) {
        self.windowDiscoveryEngine = windowDiscoveryEngine
        self.displayResolver = displayResolver
        self.snapshotStore = snapshotStore
        self.telemetryLogger = telemetryLogger
        self.browserTabCapturer = browserTabCapturer
        self.discoveryResultProvider = discoveryResultProvider
        self.restoreSpaceAccess = restoreSpaceAccess
    }

    func defaultSnapshotName(now: Date = Date()) -> String {
        formattedName(prefix: "Layout", now: now)
    }

    @discardableResult
    func captureSnapshot(
        named name: String,
        now: Date = Date()
    ) throws -> Snapshot {
        try captureSnapshotWithIssues(
            named: name,
            now: now,
            displayResolver: displayResolver,
            discoveryResultProvider: activeDiscoveryResultProvider(),
            runningApplications: []
        ).snapshot
    }

    @discardableResult
    func captureSnapshot(
        named name: String,
        now: Date = Date(),
        context: CaptureContext
    ) throws -> Snapshot {
        try captureSnapshotWithIssues(
            named: name,
            now: now,
            displayResolver: DisplayResolver(screenProvider: { context.screens }),
            discoveryResultProvider: activeDiscoveryResultProvider(context: context),
            runningApplications: context.runningApplications
        ).snapshot
    }

    func captureSnapshotWithIssues(
        named name: String,
        now: Date = Date(),
        context: CaptureContext
    ) throws -> CaptureResult {
        try captureSnapshotWithIssues(
            named: name,
            now: now,
            displayResolver: DisplayResolver(screenProvider: { context.screens }),
            discoveryResultProvider: activeDiscoveryResultProvider(context: context),
            runningApplications: context.runningApplications
        )
    }

    private func captureSnapshotWithIssues(
        named name: String,
        now: Date,
        displayResolver: DisplayResolver,
        discoveryResultProvider: () throws -> WindowDiscoveryResult,
        runningApplications: [RunningApplicationSnapshot]
    ) throws -> CaptureResult {
        do {
            let capturedState = try captureCurrentWindowState(
                displayResolver: displayResolver,
                discoveryResultProvider: discoveryResultProvider,
                runningApplications: runningApplications
            )
            let snapshot = Snapshot(
                name: name,
                createdAt: now,
                updatedAt: now,
                sourceDisplayState: capturedState.displayState,
                windows: capturedState.windows
            )

            try snapshotStore.save(snapshot)
            telemetryLogger.log(
                .captureCompleted(
                    snapshot: snapshot,
                    discoveryDiagnostics: capturedState.discoveryDiagnostics
                )
            )
            logBrowserCaptureIssues(capturedState.browserCaptureIssues)
            return CaptureResult(
                snapshot: snapshot,
                browserCaptureIssues: capturedState.browserCaptureIssues
            )
        } catch {
            telemetryLogger.log(.captureFailed(error: error))
            throw error
        }
    }

    @discardableResult
    func updateSnapshot(
        id: UUID,
        now: Date = Date()
    ) throws -> UpdateResult {
        try updateSnapshot(
            id: id,
            now: now,
            displayResolver: displayResolver,
            discoveryResultProvider: activeDiscoveryResultProvider(),
            runningApplications: []
        )
    }

    @discardableResult
    func updateSnapshot(
        id: UUID,
        now: Date = Date(),
        context: CaptureContext
    ) throws -> UpdateResult {
        try updateSnapshot(
            id: id,
            now: now,
            displayResolver: DisplayResolver(screenProvider: { context.screens }),
            discoveryResultProvider: activeDiscoveryResultProvider(context: context),
            runningApplications: context.runningApplications
        )
    }

    private func updateSnapshot(
        id: UUID,
        now: Date,
        displayResolver: DisplayResolver,
        discoveryResultProvider: () throws -> WindowDiscoveryResult,
        runningApplications: [RunningApplicationSnapshot]
    ) throws -> UpdateResult {
        let existingSnapshot = try snapshotStore.loadSnapshot(id: id)

        do {
            let capturedState = try captureCurrentWindowState(
                displayResolver: displayResolver,
                discoveryResultProvider: discoveryResultProvider,
                runningApplications: runningApplications
            )
            let mergedWindows = SnapshotWindowOpeningConfigurationMerger().merge(
                previousWindows: existingSnapshot.windows,
                capturedWindows: capturedState.windows
            )
            let snapshot = Snapshot(
                id: existingSnapshot.id,
                name: existingSnapshot.name,
                createdAt: existingSnapshot.createdAt,
                updatedAt: now,
                schemaVersion: existingSnapshot.schemaVersion,
                sourceDisplayState: capturedState.displayState,
                windows: mergedWindows.windows,
                hotkey: existingSnapshot.hotkey,
                isPinned: existingSnapshot.isPinned
            )

            try snapshotStore.save(snapshot)
            telemetryLogger.log(
                .captureCompleted(
                    snapshot: snapshot,
                    discoveryDiagnostics: capturedState.discoveryDiagnostics
                )
            )
            logBrowserCaptureIssues(capturedState.browserCaptureIssues)
            return UpdateResult(
                snapshot: snapshot,
                unmatchedManualConfigurationCount: mergedWindows.unmatchedManualConfigurationCount,
                browserCaptureIssues: capturedState.browserCaptureIssues
            )
        } catch {
            telemetryLogger.log(.captureFailed(error: error))
            throw error
        }
    }

    func makeWindowRecord(
        application: DiscoveredApplication,
        window: DiscoveredWindow,
        displayState: DisplayState
    ) throws -> WindowRecord {
        guard let display = displayResolver.resolveDisplay(
            for: window.frame,
            in: displayState
        ) else {
            throw SnapshotCaptureServiceError.noDisplaysAvailable
        }

        return WindowRecord(
            bundleIdentifier: application.bundleIdentifier,
            pidAtCapture: application.pid,
            windowTitle: window.title,
            role: window.role,
            subrole: window.subrole,
            frame: CGRectCodable(window.frame),
            displayID: display.id,
            normalizedFrame: displayResolver.normalizedFrame(for: window.frame, in: display),
            zOrderHint: window.zOrderHint,
            isMinimized: window.isMinimized,
            isFullscreen: window.isFullscreen,
            isVisible: window.isVisible,
            captureSignature: WindowSignature(application: application, window: window),
            openingConfiguration: WindowOpeningConfiguration(
                automaticallyCapturedTargets: automaticOpenTargets(for: window)
            )
        )
    }

    private func automaticOpenTargets(for window: DiscoveredWindow) -> [WindowOpenTarget] {
        let validator = WindowOpenTargetValidator()
        var targets = window.capturedOpeningTargets

        for documentURL in window.documentURLs {
            if let localTarget = validator.existingLocalTarget(url: documentURL) {
                if !containsEquivalentTarget(localTarget, in: targets) {
                    targets.append(localTarget)
                }
            } else if let webTarget = validator.webTarget(url: documentURL) {
                targets.append(webTarget)
            }
        }

        let resolver = WindowDocumentURLResolver()
        for title in window.documentTitles {
            guard let documentURL = resolver.resolveLocalPathReference(in: title),
                  let localTarget = validator.existingLocalTarget(url: documentURL) else {
                continue
            }
            if !containsEquivalentTarget(localTarget, in: targets) {
                targets.append(localTarget)
            }
        }

        return targets
    }

    private func containsEquivalentTarget(
        _ candidate: WindowOpenTarget,
        in targets: [WindowOpenTarget]
    ) -> Bool {
        targets.contains { target in
            guard target.kind == candidate.kind else {
                return false
            }

            switch candidate.kind {
            case .file, .folder:
                return (target.url.path as NSString).standardizingPath ==
                    (candidate.url.path as NSString).standardizingPath
            case .webURL:
                return target.url == candidate.url
            }
        }
    }

    private func formattedName(prefix: String, now: Date) -> String {
        "\(prefix) - \(Self.nameFormatter.string(from: now))"
    }

    private func captureCurrentWindowState(
        displayResolver: DisplayResolver,
        discoveryResultProvider: () throws -> WindowDiscoveryResult,
        runningApplications: [RunningApplicationSnapshot]
    ) throws -> CapturedWindowState {
        let rawDiscoveryResult = try discoveryResultProvider()
        let captureEligibleDiscoveryResult = WindowDiscoveryResult(
            applications: rawDiscoveryResult.applications.filter {
                !excludedSnapshotBundleIdentifiers.contains($0.bundleIdentifier)
            },
            diagnostics: rawDiscoveryResult.diagnostics,
            unexposedApplications: rawDiscoveryResult.unexposedApplications.filter {
                !excludedSnapshotBundleIdentifiers.contains($0.bundleIdentifier)
            }
        )
        let browserCaptureResult = browserTabCapturer.captureTabs(
            runningApplications: runningApplications
        )
        let enrichment = BrowserWindowTargetEnricher().enrich(
            captureEligibleDiscoveryResult,
            with: browserCaptureResult
        )
        let discoveryResult = enrichment.discoveryResult
        let displayState = displayResolver.captureDisplayState()

        guard !displayState.displays.isEmpty else {
            throw SnapshotCaptureServiceError.noDisplaysAvailable
        }

        let activeSpaces = restoreSpaceAccess.inventory(displayState.displays.map(\.id))
            .map { Set($0.activeByDisplay.values) }
        let windows = try discoveryResult.applications.flatMap { application in
            try application.windows.filter { window in
                // Unreal exposes loading/helper panels as untitled AXUnknown windows.
                // Keep discovery intact so restore can still recognize an Editor that is loading.
                if UnrealProjectResolver.isUntitledHelperWindow(window, bundleIdentifier: application.bundleIdentifier) {
                    return false
                }
                guard let windowID = window.cgWindowID else { return false }
                if let activeSpaces, !activeSpaces.isEmpty,
                   let membership = restoreSpaceAccess.membership(windowID), !membership.isEmpty {
                    return !membership.isDisjoint(with: activeSpaces)
                }
                // Only trust the on-screen hint when discovery confirmed this window's CG identity.
                return window.isOnScreen == true
            }.map { window in
                try makeWindowRecord(
                    application: application,
                    window: window,
                    displayState: displayState
                )
            }
        }
        guard !windows.isEmpty else {
            throw SnapshotCaptureServiceError.noWindowsAvailable
        }

        return CapturedWindowState(
            displayState: displayState,
            windows: windows,
            discoveryDiagnostics: discoveryResult.diagnostics,
            browserCaptureIssues: enrichment.issues
        )
    }

    private struct CapturedWindowState {
        let displayState: DisplayState
        let windows: [WindowRecord]
        let discoveryDiagnostics: [WindowDiscoveryDiagnostic]
        let browserCaptureIssues: [BrowserCaptureIssue]
    }

    private func logBrowserCaptureIssues(_ issues: [BrowserCaptureIssue]) {
        for issue in issues {
            telemetryLogger.log(
                .browserAutomation(
                    browser: issue.browser,
                    outcome: issue.reason.rawValue
                )
            )
        }
    }

    private func activeDiscoveryResultProvider() -> () throws -> WindowDiscoveryResult {
        discoveryResultProvider ?? {
            try windowDiscoveryEngine.discoverRunningWindowsWithDiagnostics()
        }
    }

    private func activeDiscoveryResultProvider(
        context: CaptureContext
    ) -> () throws -> WindowDiscoveryResult {
        discoveryResultProvider ?? {
            try windowDiscoveryEngine.discoverRunningWindowsWithDiagnostics(
                runningApplications: context.runningApplications
            )
        }
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct SnapshotWindowOpeningConfigurationMerger {
    struct Result {
        let windows: [WindowRecord]
        let unmatchedManualConfigurationCount: Int
    }

    func merge(
        previousWindows: [WindowRecord],
        capturedWindows: [WindowRecord]
    ) -> Result {
        var unmatchedPreviousIndices = Set(previousWindows.indices)
        var unmatchedCapturedIndices = Set(capturedWindows.indices)
        var previousIndexByCapturedIndex: [Int: Int] = [:]

        matchUniqueWindows(
            previousWindows: previousWindows,
            capturedWindows: capturedWindows,
            unmatchedPreviousIndices: &unmatchedPreviousIndices,
            unmatchedCapturedIndices: &unmatchedCapturedIndices,
            previousIndexByCapturedIndex: &previousIndexByCapturedIndex,
            key: processWindowKey
        )
        matchUniqueWindows(
            previousWindows: previousWindows,
            capturedWindows: capturedWindows,
            unmatchedPreviousIndices: &unmatchedPreviousIndices,
            unmatchedCapturedIndices: &unmatchedCapturedIndices,
            previousIndexByCapturedIndex: &previousIndexByCapturedIndex,
            key: descriptiveWindowKey
        )
        matchUniqueWindows(
            previousWindows: previousWindows,
            capturedWindows: capturedWindows,
            unmatchedPreviousIndices: &unmatchedPreviousIndices,
            unmatchedCapturedIndices: &unmatchedCapturedIndices,
            previousIndexByCapturedIndex: &previousIndexByCapturedIndex,
            key: windowTitleKey,
            canMatch: { previous, captured in
                previous.captureSignature.source == .coreGraphics &&
                    previous.role == "AXWindow" && previous.subrole == nil &&
                    captured.captureSignature.source == .accessibility &&
                    captured.subrole == "AXStandardWindow"
            }
        )
        matchSingletonApplications(
            previousWindows: previousWindows,
            capturedWindows: capturedWindows,
            unmatchedPreviousIndices: &unmatchedPreviousIndices,
            unmatchedCapturedIndices: &unmatchedCapturedIndices,
            previousIndexByCapturedIndex: &previousIndexByCapturedIndex
        )

        let windows = capturedWindows.enumerated().map { index, window in
            guard let previousIndex = previousIndexByCapturedIndex[index] else {
                return window
            }

            return window.preservingIdentityAndManualTargets(from: previousWindows[previousIndex])
        }
        let unmatchedManualConfigurationCount = unmatchedPreviousIndices.filter {
            previousWindows[$0].openingConfiguration.isManual
        }.count

        return Result(
            windows: windows,
            unmatchedManualConfigurationCount: unmatchedManualConfigurationCount
        )
    }

    private func matchUniqueWindows<Key: Hashable>(
        previousWindows: [WindowRecord],
        capturedWindows: [WindowRecord],
        unmatchedPreviousIndices: inout Set<Int>,
        unmatchedCapturedIndices: inout Set<Int>,
        previousIndexByCapturedIndex: inout [Int: Int],
        key: (WindowRecord) -> Key?,
        canMatch: (WindowRecord, WindowRecord) -> Bool = { _, _ in true }
    ) {
        let previousGroups = Dictionary(grouping: unmatchedPreviousIndices) {
            key(previousWindows[$0])
        }
        let capturedGroups = Dictionary(grouping: unmatchedCapturedIndices) {
            key(capturedWindows[$0])
        }

        for (matchKey, previousIndices) in previousGroups {
            guard let matchKey,
                  previousIndices.count == 1,
                  let capturedIndices = capturedGroups[matchKey],
                  capturedIndices.count == 1,
                  let previousIndex = previousIndices.first,
                  let capturedIndex = capturedIndices.first,
                  canMatch(previousWindows[previousIndex], capturedWindows[capturedIndex]) else {
                continue
            }

            unmatchedPreviousIndices.remove(previousIndex)
            unmatchedCapturedIndices.remove(capturedIndex)
            previousIndexByCapturedIndex[capturedIndex] = previousIndex
        }
    }

    private func matchSingletonApplications(
        previousWindows: [WindowRecord],
        capturedWindows: [WindowRecord],
        unmatchedPreviousIndices: inout Set<Int>,
        unmatchedCapturedIndices: inout Set<Int>,
        previousIndexByCapturedIndex: inout [Int: Int]
    ) {
        let previousGroups = Dictionary(grouping: unmatchedPreviousIndices) {
            previousWindows[$0].bundleIdentifier
        }
        let capturedGroups = Dictionary(grouping: unmatchedCapturedIndices) {
            capturedWindows[$0].bundleIdentifier
        }

        for (bundleIdentifier, previousIndices) in previousGroups {
            guard previousIndices.count == 1,
                  let capturedIndices = capturedGroups[bundleIdentifier],
                  capturedIndices.count == 1,
                  let previousIndex = previousIndices.first,
                  let capturedIndex = capturedIndices.first,
                  previousWindows[previousIndex].role == capturedWindows[capturedIndex].role,
                  previousWindows[previousIndex].subrole == capturedWindows[capturedIndex].subrole else {
                continue
            }

            unmatchedPreviousIndices.remove(previousIndex)
            unmatchedCapturedIndices.remove(capturedIndex)
            previousIndexByCapturedIndex[capturedIndex] = previousIndex
        }
    }

    private func processWindowKey(_ window: WindowRecord) -> ProcessWindowKey? {
        guard let owningPid = window.captureSignature.owningPid,
              let cgWindowID = window.captureSignature.cgWindowID else {
            return nil
        }

        return ProcessWindowKey(
            bundleIdentifier: window.bundleIdentifier,
            owningPid: owningPid,
            cgWindowID: cgWindowID
        )
    }

    private func descriptiveWindowKey(_ window: WindowRecord) -> DescriptiveWindowKey? {
        guard let title = window.windowTitle?.nonEmptyValue else {
            return nil
        }

        return DescriptiveWindowKey(
            bundleIdentifier: window.bundleIdentifier,
            title: title,
            role: window.role,
            subrole: window.subrole
        )
    }

    private func windowTitleKey(_ window: WindowRecord) -> WindowTitleKey? {
        guard let title = window.windowTitle?.nonEmptyValue else {
            return nil
        }

        return WindowTitleKey(
            bundleIdentifier: window.bundleIdentifier,
            title: title,
            role: window.role
        )
    }

    private struct ProcessWindowKey: Hashable {
        let bundleIdentifier: String
        let owningPid: Int32
        let cgWindowID: UInt32
    }

    private struct DescriptiveWindowKey: Hashable {
        let bundleIdentifier: String
        let title: String
        let role: String
        let subrole: String?
    }

    private struct WindowTitleKey: Hashable {
        let bundleIdentifier: String
        let title: String
        let role: String
    }
}
