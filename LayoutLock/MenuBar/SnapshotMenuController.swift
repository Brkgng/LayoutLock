import Foundation

private func runSnapshotOperationOffMain<T>(_ operation: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try operation())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class SnapshotMenuController: ObservableObject {
    typealias HotkeyPrompt = (
        _ snapshotName: String,
        _ unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    ) -> HotkeyBinding?
    typealias SnapshotNamePrompter = (_ defaultName: String) -> String?
    typealias SnapshotRenamePrompter = (_ currentName: String) -> String?
    typealias SnapshotCapturer = (_ snapshotName: String) throws -> Snapshot
    typealias AppNameResolver = (_ bundleIdentifier: String) -> String

    struct Status {
        enum Kind {
            case info
            case warning
            case proRequired
            case error
        }

        let message: String
        let kind: Kind

        var isError: Bool { kind == .error }
        var isWarning: Bool { kind == .warning }
    }

    @Published private(set) var snapshotSummaries: [SnapshotSummary]
    @Published private(set) var status: Status? {
        didSet {
            scheduleStatusClear()
        }
    }
    @Published private(set) var isOperating = false {
        didSet {
            scheduleStatusClear()
        }
    }
    @Published private(set) var lastCapturedSnapshotID: UUID?
    @Published private(set) var restoreCompletionID: UUID?

    private let snapshotStore: SnapshotStore?
    private let snapshotCaptureService: SnapshotCaptureService?
    private let restoreEngine: RestoreEngine?
    private let hotkeyPrompt: HotkeyPrompt
    private let snapshotNamePrompt: SnapshotNamePrompter
    private let snapshotRenamePrompt: SnapshotRenamePrompter
    private let snapshotCapture: SnapshotCapturer?
    private let captureContextProvider: @MainActor () -> SnapshotCaptureService.CaptureContext
    private let appNameResolver: AppNameResolver
    private let operationOverlayPresenter: OperationOverlayPresenting
    private let entitlementProvider: EntitlementProviding
    private var snapshotSummariesDidChange: (([SnapshotSummary]) -> Error?)?
    private var hotkeyCaptureActivityDidChange: ((Bool) -> Error?)?
    private var statusClearTask: Task<Void, Never>?
    private let statusAutoClearDelay: TimeInterval
    private let uiSleep: @MainActor (TimeInterval) async throws -> Void

    init(
        snapshotStore: SnapshotStore? = nil,
        snapshotCaptureService: SnapshotCaptureService? = nil,
        restoreEngine: RestoreEngine? = nil,
        hotkeyPrompt: @escaping HotkeyPrompt = HotkeyCapturePrompt.prompt,
        snapshotNamePrompt: @escaping SnapshotNamePrompter = SnapshotNamePrompt.prompt,
        snapshotRenamePrompt: @escaping SnapshotRenamePrompter = SnapshotNamePrompt.promptRename,
        snapshotCapture: SnapshotCapturer? = nil,
        captureContextProvider: @escaping @MainActor () -> SnapshotCaptureService.CaptureContext = SnapshotCaptureService.CaptureContext.current,
        appNameResolver: @escaping AppNameResolver = {
            DashboardAppIdentityResolver.shared.identity(for: $0).name
        },
        operationOverlayPresenter: OperationOverlayPresenting = NoOpOperationOverlayPresenter(),
        entitlementProvider: EntitlementProviding = StaticEntitlementProvider(isProUnlocked: true),
        statusAutoClearDelay: TimeInterval = 5,
        uiSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) {
        self.snapshotStore = snapshotStore
        self.snapshotCaptureService = snapshotCaptureService
        self.restoreEngine = restoreEngine
        self.hotkeyPrompt = hotkeyPrompt
        self.snapshotNamePrompt = snapshotNamePrompt
        self.snapshotRenamePrompt = snapshotRenamePrompt
        self.snapshotCapture = snapshotCapture
        self.captureContextProvider = captureContextProvider
        self.appNameResolver = appNameResolver
        self.operationOverlayPresenter = operationOverlayPresenter
        self.entitlementProvider = entitlementProvider
        self.statusAutoClearDelay = statusAutoClearDelay
        self.uiSleep = uiSleep
        snapshotSummaries = []
        refreshSummaries()
    }

    private func scheduleStatusClear() {
        statusClearTask?.cancel()

        guard status != nil, !isOperating else { return }

        let delay = statusAutoClearDelay
        let uiSleep = uiSleep
        statusClearTask = Task { @MainActor [weak self] in
            do {
                try await uiSleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    func setSnapshotSummariesDidChange(_ callback: @escaping ([SnapshotSummary]) -> Error?) {
        snapshotSummariesDidChange = callback
        if let error = notifySnapshotSummariesDidChange() {
            reportHotkeyRegistrationFailure(error)
        }
    }

    func setHotkeyCaptureActivityDidChange(_ callback: @escaping (Bool) -> Error?) {
        hotkeyCaptureActivityDidChange = callback
    }

    func reportLayoutRequiresWindow() {
        status = Status(
            message: SnapshotStoreError.layoutRequiresWindow.userFacingDescription,
            kind: .error
        )
    }

    func reportProRequired(for feature: ProFeature) {
        status = Status(
            message: feature.requiredPlanMessage,
            kind: .proRequired
        )
    }

    func canUseProFeature(_ feature: ProFeature) -> Bool {
        guard entitlementProvider.isProUnlocked else {
            reportProRequired(for: feature)
            return false
        }

        return true
    }

    @discardableResult
    func setHotkeyCaptureActive(_ isActive: Bool) -> Error? {
        if let error = hotkeyCaptureActivityDidChange?(isActive) {
            reportHotkeyRegistrationFailure(error)
            return error
        }
        return nil
    }

    @discardableResult
    func captureCurrentSnapshot() -> Task<Void, Never>? {
        guard let defaultName = suggestedSnapshotNameForCapture() else {
            return nil
        }

        guard let snapshotName = snapshotNamePrompt(defaultName) else {
            return nil
        }

        return captureCurrentSnapshot(named: snapshotName)
    }

    func suggestedSnapshotNameForCapture() -> String? {
        guard let snapshotCaptureService = snapshotCaptureServiceForNewSnapshot() else {
            return nil
        }

        return snapshotCaptureService.defaultSnapshotName()
    }

    @discardableResult
    func captureCurrentSnapshot(named snapshotName: String) -> Task<Void, Never>? {
        guard let snapshotCaptureService = snapshotCaptureServiceForNewSnapshot() else {
            return nil
        }

        isOperating = true
        status = Status(message: "Saving...", kind: .info)

        return Task { @MainActor [self] in
            await operationOverlayPresenter.showOverlay(kind: .save)
            defer {
                isOperating = false
                operationOverlayPresenter.hideOverlay()
            }

            do {
                let captureContext = captureContextProvider()
                let snapshotCapture = self.snapshotCapture
                let captureResult = try await runSnapshotOperationOffMain {
                    if let snapshotCapture {
                        return SnapshotCaptureService.CaptureResult(
                            snapshot: try snapshotCapture(snapshotName),
                            browserCaptureIssues: []
                        )
                    }
                    return try snapshotCaptureService.captureSnapshotWithIssues(
                        named: snapshotName,
                        context: captureContext
                    )
                }
                let snapshot = captureResult.snapshot
                let refreshError = refreshSummaries()
                if snapshotSummaries.contains(where: { $0.id == snapshot.id }) {
                    lastCapturedSnapshotID = snapshot.id
                }

                if let error = refreshError {
                    reportHotkeyRegistrationFailure(error)
                    return
                }

                status = captureStatus(
                    action: "Saved",
                    snapshot: snapshot,
                    captureIssueMessages: captureResult.browserCaptureIssues.map(\.message)
                )
            } catch {
                status = Status(
                    message: error.userFacingDescription,
                    kind: .error
                )
            }
        }
    }

    private func snapshotCaptureServiceForNewSnapshot() -> SnapshotCaptureService? {
        guard !isOperating else {
            return nil
        }

        guard let snapshotCaptureService else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return nil
        }

        guard canCreateNewSnapshot() else {
            return nil
        }

        return snapshotCaptureService
    }

    @discardableResult
    func restoreSnapshot(id: UUID) -> Task<Void, Never>? {
        guard !isOperating else {
            return nil
        }

        guard let restoreEngine else {
            status = Status(
                message: "Layout restore is unavailable.",
                kind: .error
            )
            return nil
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == id })?.name ?? "Layout"

        isOperating = true
        status = Status(message: "Restoring...", kind: .info)

        return Task { @MainActor [self] in
            await operationOverlayPresenter.showOverlay(kind: .restore)
            let loadingOverlayTask = Task { @MainActor [self] in
                do {
                    try await uiSleep(15)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                operationOverlayPresenter.hideOverlay()
                status = Status(message: "Restoring in the background", kind: .info)
            }
            var didShowRestoreCompletion = false
            defer {
                loadingOverlayTask.cancel()
                isOperating = false
                if !didShowRestoreCompletion {
                    operationOverlayPresenter.hideOverlay()
                }
            }

            do {
                try Task.checkCancellation()
                let result = try await withTaskCancellationHandler {
                    try await restoreEngine.restoreSnapshot(id: id)
                } onCancel: {
                    loadingOverlayTask.cancel()
                }
                try Task.checkCancellation()
                status = Status(
                    message: restoreStatusMessage(snapshotName: snapshotName, result: result),
                    kind: .info
                )
                let completion = restoreCompletionMessage(snapshotName: snapshotName, result: result)
                operationOverlayPresenter.showRestoreCompletion(completion)
                didShowRestoreCompletion = true
                restoreCompletionID = UUID()
            } catch is CancellationError {
                status = Status(message: "Restore cancelled.", kind: .info)
            } catch {
                status = Status(
                    message: error.userFacingDescription,
                    kind: .error
                )
            }
        }
    }

    @discardableResult
    func updateSnapshot(id: UUID) -> Task<Void, Never>? {
        guard !isOperating else {
            return nil
        }

        guard let snapshotCaptureService else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return nil
        }

        isOperating = true
        status = Status(message: "Saving...", kind: .info)

        return Task { @MainActor [self] in
            await operationOverlayPresenter.showOverlay(kind: .save)
            defer {
                isOperating = false
                operationOverlayPresenter.hideOverlay()
            }

            do {
                let captureContext = captureContextProvider()
                let result = try await runSnapshotOperationOffMain {
                    try snapshotCaptureService.updateSnapshot(
                        id: id,
                        context: captureContext
                    )
                }
                if let error = refreshSummaries() {
                    reportHotkeyRegistrationFailure(error)
                    return
                }

                let snapshot = result.snapshot
                if result.unmatchedManualConfigurationCount > 0 {
                    let configurationLabel = result.unmatchedManualConfigurationCount == 1
                        ? "opening-target configuration"
                        : "opening-target configurations"
                    let captureIssueMessages = result.browserCaptureIssues.map(\.message)
                    let captureWarning = captureIssueMessages.isEmpty
                        ? ""
                        : " \(captureIssueMessages.joined(separator: " "))"
                    status = Status(
                        message: "Updated \"\(snapshot.name)\" with \(windowCountDescription(snapshot.windows.count)). \(result.unmatchedManualConfigurationCount) manual \(configurationLabel) could not be matched and needs review.\(captureWarning)",
                        kind: .error
                    )
                } else {
                    status = captureStatus(
                        action: "Updated",
                        snapshot: snapshot,
                        captureIssueMessages: result.browserCaptureIssues.map(\.message)
                    )
                }
            } catch {
                status = Status(
                    message: error.userFacingDescription,
                    kind: .error
                )
            }
        }
    }

    private func captureStatus(
        action: String,
        snapshot: Snapshot,
        captureIssueMessages: [String]
    ) -> Status {
        let summary = "\(action) \"\(snapshot.name)\" with \(windowCountDescription(snapshot.windows.count))."
        guard !captureIssueMessages.isEmpty else {
            return Status(message: summary, kind: .info)
        }

        let issueMessages = captureIssueMessages.joined(separator: " ")
        return Status(
            message: "\(summary) \(issueMessages)",
            kind: .warning
        )
    }

    @discardableResult
    func setHotkey(_ hotkey: HotkeyBinding, for snapshotID: UUID) -> Bool {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return false
        }

        guard let snapshot = snapshotSummaries.first(where: { $0.id == snapshotID }) else {
            status = Status(
                message: "The layout could not be found.",
                kind: .error
            )
            return false
        }

        do {
            try snapshotStore.setHotkey(for: snapshotID, hotkey: hotkey)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return false
            }

            status = Status(
                message: "Assigned \(hotkey.displayString) to \"\(snapshot.name)\".",
                kind: .info
            )
            return true
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return false
        }
    }

    func togglePin(for snapshotID: UUID) {
        guard let snapshotStore else {
            status = Status(message: "Layout storage is unavailable.", kind: .error)
            return
        }

        guard let snapshot = snapshotSummaries.first(where: { $0.id == snapshotID }) else {
            status = Status(message: "The layout could not be found.", kind: .error)
            return
        }

        do {
            try snapshotStore.setPinned(!snapshot.isPinned, for: snapshotID)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return
            }

            status = Status(
                message: "\(snapshot.isPinned ? "Unpinned" : "Pinned") \"\(snapshot.name)\".",
                kind: .info
            )
        } catch {
            status = Status(message: error.userFacingDescription, kind: .error)
        }
    }

    func assignHotkey(to snapshotID: UUID) {
        guard snapshotStore != nil else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return
        }

        guard snapshotSummaries.contains(where: { $0.id == snapshotID }) else {
            status = Status(
                message: "The layout could not be found.",
                kind: .error
            )
            return
        }

        if let enterError = hotkeyCaptureActivityDidChange?(true) {
            reportHotkeyRegistrationFailure(enterError)
            return
        }
        defer {
            if let resumeError = hotkeyCaptureActivityDidChange?(false) {
                reportHotkeyRegistrationFailure(resumeError)
            }
        }

        let unavailableHotkeys = snapshotSummaries.compactMap { summary -> (binding: HotkeyBinding, snapshotName: String)? in
            guard summary.id != snapshotID, let hotkey = summary.hotkey else {
                return nil
            }

            return (binding: hotkey, snapshotName: summary.name)
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"
        guard let hotkey = hotkeyPrompt(snapshotName, unavailableHotkeys) else {
            return
        }

        _ = setHotkey(hotkey, for: snapshotID)
    }

    func clearHotkey(for snapshotID: UUID) {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"

        do {
            try snapshotStore.setHotkey(for: snapshotID, hotkey: nil)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return
            }

            status = Status(
                message: "Cleared hotkey for \"\(snapshotName)\".",
                kind: .info
            )
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
        }
    }

    func renameSnapshot(id snapshotID: UUID) {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return
        }

        guard let snapshot = snapshotSummaries.first(where: { $0.id == snapshotID }) else {
            status = Status(
                message: "The layout could not be found.",
                kind: .error
            )
            return
        }

        guard let newName = snapshotRenamePrompt(snapshot.name) else {
            return
        }

        do {
            try snapshotStore.renameSnapshot(id: snapshotID, to: newName)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return
            }

            let renamedSnapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? newName
            status = Status(
                message: "Renamed \"\(snapshot.name)\" to \"\(renamedSnapshotName)\".",
                kind: .info
            )
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
        }
    }

    func removeWindow(
        windowID: UUID,
        windowTitle: String?,
        appName: String,
        from snapshotID: UUID
    ) {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"
        let windowDescription = windowTitle?.nonEmptyValue.map { "\"\($0)\"" } ?? "\(appName) window"

        do {
            let didRemoveWindow = try snapshotStore.removeWindow(
                windowID: windowID,
                from: snapshotID
            )
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return
            }

            if didRemoveWindow {
                status = Status(
                    message: "Removed \(windowDescription) from \"\(snapshotName)\".",
                    kind: .info
                )
            } else {
                status = Status(
                    message: "\"\(snapshotName)\" has no saved window matching \(windowDescription).",
                    kind: .info
                )
            }
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
        }
    }

    @discardableResult
    func reorderWindows(
        displayID: UInt32,
        orderedWindowIDs: [UUID],
        in snapshotID: UUID
    ) -> Bool {
        guard canUseProFeature(.customRestoreOrder) else {
            return false
        }

        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return false
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"

        do {
            let didReorder = try snapshotStore.reorderDisplayWindows(
                snapshotID: snapshotID,
                displayID: displayID,
                orderedWindowIDs: orderedWindowIDs
            )
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return didReorder
            }

            if didReorder {
                status = Status(
                    message: "Updated restore order for \"\(snapshotName)\".",
                    kind: .info
                )
            }
            return didReorder
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return false
        }
    }

    @discardableResult
    func setOpeningTargets(
        _ targets: [WindowOpenTarget],
        for windowID: UUID,
        in snapshotID: UUID
    ) -> Bool {
        updateOpeningConfiguration(
            manualTargets: targets,
            windowID: windowID,
            snapshotID: snapshotID
        )
    }

    @discardableResult
    func renameSnapshotInline(id snapshotID: UUID, newName: String) -> Bool {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return false
        }

        guard let old = snapshotSummaries.first(where: { $0.id == snapshotID }) else {
            status = Status(
                message: "The layout could not be found.",
                kind: .error
            )
            return false
        }

        do {
            try snapshotStore.renameSnapshot(id: snapshotID, to: newName)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return true
            }

            status = Status(
                message: "Renamed \"\(old.name)\" to \"\(newName)\".",
                kind: .info
            )
            return true
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return false
        }
    }

    func deleteSnapshot(id snapshotID: UUID) {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"

        do {
            try snapshotStore.deleteSnapshot(id: snapshotID)
            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return
            }

            status = Status(
                message: "Deleted \"\(snapshotName)\".",
                kind: .info
            )
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
        }
    }

    func loadSnapshot(id snapshotID: UUID) -> Snapshot? {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return nil
        }

        do {
            return try snapshotStore.loadSnapshot(id: snapshotID)
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return nil
        }
    }

    private func updateOpeningConfiguration(
        manualTargets: [WindowOpenTarget],
        windowID: UUID,
        snapshotID: UUID
    ) -> Bool {
        guard let snapshotStore else {
            status = Status(
                message: "Layout storage is unavailable.",
                kind: .error
            )
            return false
        }

        let snapshotName = snapshotSummaries.first(where: { $0.id == snapshotID })?.name ?? "Layout"

        do {
            let didUpdate = try snapshotStore.setOpeningConfiguration(
                snapshotID: snapshotID,
                windowID: windowID,
                manualTargets: manualTargets
            )
            guard didUpdate else {
                status = Status(
                    message: "The saved window could not be found or its opening targets were unchanged.",
                    kind: .info
                )
                return false
            }

            if let error = refreshSummaries() {
                reportHotkeyRegistrationFailure(error)
                return false
            }

            status = Status(
                message: "Updated opening targets for \"\(snapshotName)\".",
                kind: .info
            )
            return true
        } catch {
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return false
        }
    }

    func reportHotkeyRegistrationFailure(_ error: Error) {
        status = Status(
            message: error.userFacingDescription,
            kind: .error
        )
    }

    @discardableResult
    func refreshSummaries() -> Error? {
        guard let snapshotStore else {
            snapshotSummaries = []
            return notifySnapshotSummariesDidChange()
        }

        do {
            snapshotSummaries = try snapshotStore.listSummaries()
            return notifySnapshotSummariesDidChange()
        } catch {
            snapshotSummaries = []
            _ = notifySnapshotSummariesDidChange()
            status = Status(
                message: error.userFacingDescription,
                kind: .error
            )
            return error
        }
    }

    private func notifySnapshotSummariesDidChange() -> Error? {
        snapshotSummariesDidChange?(snapshotSummaries)
    }

    private func canCreateNewSnapshot() -> Bool {
        if entitlementProvider.isProUnlocked ||
            snapshotSummaries.count < LayoutLockProConfiguration.freeLayoutLimit {
            return true
        }

        reportProRequired(for: .unlimitedLayouts)
        return false
    }

    private func restoreStatusMessage(
        snapshotName: String,
        result: RestoreResult
    ) -> String {
        let restoredLabel = result.restoredWindows == 1 ? "window" : "windows"
        let details = restoreSummaryDetails(for: result)

        guard !details.isEmpty else {
            return "Restored \"\(snapshotName)\": \(result.restoredWindows) \(restoredLabel) restored."
        }

        return "Restored \"\(snapshotName)\": \(result.restoredWindows) \(restoredLabel) restored, \(details.joined(separator: ", "))."
    }

    private func restoreCompletionMessage(
        snapshotName: String,
        result: RestoreResult
    ) -> RestoreCompletionMessage {
        let restoredLabel = result.restoredWindows == 1 ? "window" : "windows"
        let details = restoreSummaryDetails(for: result)
        let hasIssues = !details.isEmpty
        let summary = (["\(result.restoredWindows) \(restoredLabel) restored"] + details)
            .joined(separator: " · ")

        return RestoreCompletionMessage(
            title: "\"\(snapshotName)\" restored\(hasIssues ? " with issues" : "")",
            summary: summary,
            issues: result.targetIssues.map(targetIssueDetail) + result.skippedItems.map(skippedWindowDetail)
                + result.downgradedItems.filter { $0.reason == RestoreDowngradeReason.windowIdentityUnconfirmed }.map {
                    skippedWindowDetail(for: RestoreSkip(
                        bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle, reason: $0.reason))
                },
            hasIssues: hasIssues
        )
    }

    private func restoreSummaryDetails(for result: RestoreResult) -> [String] {
        let fallbackLabel = result.displayFallbacks.count == 1 ? "display fallback" : "display fallbacks"
        let targetIssueLabel = result.targetIssues.count == 1 ? "target issue" : "target issues"
        return [
            result.skippedItems.isEmpty ? nil : "\(result.skippedItems.count) skipped",
            result.targetIssues.isEmpty ? nil : "\(result.targetIssues.count) \(targetIssueLabel)",
            result.downgradedItems.contains { $0.reason == RestoreDowngradeReason.windowIdentityUnconfirmed }
                ? "desktop placement unconfirmed" : nil,
            result.displayFallbacks.isEmpty ? nil : "\(result.displayFallbacks.count) \(fallbackLabel)"
        ].compactMap { $0 }
    }

    private func targetIssueDetail(for issue: RestoreTargetIssue) -> RestoreCompletionIssue {
        let appName = appNameResolver(issue.bundleIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = appName.isEmpty ? issue.bundleIdentifier : appName
        let targetDescription = issue.target.kind == .webURL
            ? issue.target.url.absoluteString
            : (issue.target.url.path as NSString).abbreviatingWithTildeInPath
        return RestoreCompletionIssue(appName: displayName, context: targetDescription, reason: issue.reason.userFacingDescription)
    }

    private func skippedWindowDetail(for skippedItem: RestoreSkip) -> RestoreCompletionIssue {
        let appName = appNameResolver(skippedItem.bundleIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = appName.isEmpty ? skippedItem.bundleIdentifier : appName
        let title = skippedItem.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RestoreCompletionIssue(
            appName: displayName,
            context: title?.isEmpty == false ? title : nil,
            reason: friendlySkipReason(skippedItem.reason)
        )
    }

    private func friendlySkipReason(_ reason: String) -> String {
        switch reason {
        case RestoreSkipReason.appNotRunning:
            return "Application is not running."
        case RestoreSkipReason.windowNotFound:
            return "Matching window was not found."
        case RestoreSkipReason.openedBrowserWindowNotIdentified:
            return "Opened browser window could not be matched."
        case RestoreSkipReason.appInstanceUnconfirmed:
            return "A separate app instance could not be confirmed."
        case RestoreSkipReason.desktopUnconfirmed:
            return "Window could not be brought to the current desktop."
        case RestoreSkipReason.inspectionNotReturned:
            return "Inspected window could not be returned to its original desktop and position."
        case RestoreDowngradeReason.windowIdentityUnconfirmed:
            return "Position restored; desktop placement could not be confirmed."
        case RestoreSkipReason.windowGeometryDidNotSettle:
            return "Window did not accept the saved position and size."
        default:
            return "Window could not be restored."
        }
    }

    private func windowCountDescription(_ count: Int) -> String {
        count == 1 ? "1 window" : "\(count) windows"
    }
}
