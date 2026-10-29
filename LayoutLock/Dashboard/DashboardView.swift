import AppKit
import SwiftUI

private enum DashboardFocusTarget: Hashable {
    case layoutList
    case layoutSearch
}

struct DashboardSnapshotNameRequest: Identifiable {
    let id = UUID()
    let defaultName: String

    func submissionName(for draftName: String) -> String {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? defaultName : trimmedName
    }
}

struct DashboardOpeningTargetsRequest: Identifiable {
    let snapshotID: UUID
    let window: WindowRecord

    var id: UUID {
        window.id
    }
}

struct DashboardCommandAvailability: Equatable {
    let canCreateLayout: Bool
    let canRestoreLayout: Bool
    let canUpdateLayout: Bool
    let canRenameLayout: Bool
    let canAssignHotkey: Bool
    let canClearHotkey: Bool
    let canDeleteLayout: Bool
    let hotkeyCommandTitle: String

    init(
        isSnapshotActionDisabled: Bool,
        isAccessibilityAuthorized: Bool,
        hasSelectedLayout: Bool,
        selectedLayoutHasHotkey: Bool
    ) {
        let canUseSelectedLayout = !isSnapshotActionDisabled && hasSelectedLayout
        let canUsePrivilegedSelectedLayout = canUseSelectedLayout && isAccessibilityAuthorized

        canCreateLayout = !isSnapshotActionDisabled && isAccessibilityAuthorized
        canRestoreLayout = canUsePrivilegedSelectedLayout
        canUpdateLayout = canUsePrivilegedSelectedLayout
        canRenameLayout = canUseSelectedLayout
        canAssignHotkey = canUseSelectedLayout
        canClearHotkey = canUseSelectedLayout && selectedLayoutHasHotkey
        canDeleteLayout = canUseSelectedLayout
        hotkeyCommandTitle = selectedLayoutHasHotkey ? "Change Hotkey" : "Set Hotkey"
    }
}

enum DashboardDetailContentPreference: Equatable {
    case permissionEducation
    case selectedLayout
    case emptyState

    static func resolve(
        showsPermissionEducation: Bool,
        isAccessibilityAuthorized: Bool,
        hasSavedLayouts: Bool,
        hasSelectedLayout: Bool
    ) -> DashboardDetailContentPreference {
        if showsPermissionEducation || (!isAccessibilityAuthorized && !hasSavedLayouts) {
            return .permissionEducation
        }

        return hasSelectedLayout ? .selectedLayout : .emptyState
    }
}

struct DashboardCommandContext {
    let canCreateLayout: Bool
    let canRestoreLayout: Bool
    let canUpdateLayout: Bool
    let canRenameLayout: Bool
    let canAssignHotkey: Bool
    let canClearHotkey: Bool
    let canDeleteLayout: Bool
    let canSearchLayouts: Bool
    let hotkeyCommandTitle: String
    let createLayout: () -> Void
    let restoreLayout: () -> Void
    let updateLayout: () -> Void
    let renameLayout: () -> Void
    let assignHotkey: () -> Void
    let clearHotkey: () -> Void
    let deleteLayout: () -> Void
    let focusLayoutSearch: () -> Void
}

private struct DashboardCommandContextKey: FocusedValueKey {
    typealias Value = DashboardCommandContext
}

extension FocusedValues {
    var dashboardCommandContext: DashboardCommandContext? {
        get { self[DashboardCommandContextKey.self] }
        set { self[DashboardCommandContextKey.self] = newValue }
    }
}

struct DashboardView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    let bootstrapErrorMessage: String?
    let diagnosticLogController: DiagnosticLogController?
    @ObservedObject var permissionCoordinator: PermissionCoordinator
    @ObservedObject var permissionRouter: PermissionInterventionRouter
    @ObservedObject var snapshotMenuController: SnapshotMenuController
    @ObservedObject var entitlementController: EntitlementController
    @ObservedObject var settingsNavigationController: SettingsNavigationController
    @ObservedObject var updateController: AppUpdateController
    @ObservedObject var raycastRecommendationController: RaycastRecommendationController
    let windowPresentationCoordinator: DashboardWindowPresentationCoordinator

    @State private var selectedSnapshotID: UUID?
    @State private var selectedSnapshot: Snapshot?
    @State private var layoutSearchText = ""
    @State private var pendingUpdate: SnapshotSummary?
    @State private var pendingDeletion: SnapshotSummary?
    @State private var pendingWindowRemoval: DashboardWindowRemovalConfirmation?
    @State private var pendingSnapshotNameRequest: DashboardSnapshotNameRequest?
    @State private var pendingOpeningTargetsRequest: DashboardOpeningTargetsRequest?
    @State private var proUpgradePrompt: ProFeature?
    @State private var inlineRenameRequestID: UUID?
    @State private var hotkeyEditRequestID: UUID?
    @FocusState private var dashboardFocus: DashboardFocusTarget?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if permissionCoordinator.authorizationState == .authorized {
                    SidebarActionButton(
                        title: "New Layout",
                        systemImage: "plus",
                        isPrimary: true,
                        isDisabled: bootstrapErrorMessage != nil || snapshotMenuController.isOperating,
                        isConstrained: isFreeLayoutLimitReached,
                        topPadding: 0,
                        bottomPadding: 8,
                        action: saveSnapshot
                    )
                }

                if !planStatusPresentation.isProUnlocked {
                    PlanStatusView(
                        presentation: planStatusPresentation,
                        style: .dashboard,
                        action: performPlanStatusAction
                    )
                }

                if showsLayoutSearch {
                    SidebarSearchField(
                        searchText: $layoutSearchText,
                        focus: $dashboardFocus
                    )
                }

                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { selectedSnapshotID },
                        set: { newValue in
                            selectedSnapshotID = newValue
                            if let newValue {
                                selectedSnapshot = snapshotMenuController.loadSnapshot(id: newValue)
                            } else {
                                selectedSnapshot = nil
                            }
                        }
                    )) {
                        if snapshotMenuController.snapshotSummaries.isEmpty {
                            Text("No layouts saved yet")
                                .foregroundStyle(.secondary)
                        } else if visibleSnapshotSummaries.isEmpty {
                            Text("No matching layouts")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visibleSnapshotSummaries) { snapshot in
                                DashboardSnapshotRow(
                                    snapshot: snapshot,
                                    isSelected: selectedSnapshotID == snapshot.id,
                                    renameSnapshotInline: renameSnapshotInline,
                                    assignHotkey: {
                                        assignHotkey(to: snapshot)
                                    },
                                    clearHotkey: {
                                        clearHotkey(from: snapshot)
                                    },
                                    togglePin: {
                                        snapshotMenuController.togglePin(for: snapshot.id)
                                    },
                                    deleteSnapshot: {
                                        deleteSnapshot(snapshot)
                                    },
                                    isActionDisabled: isSnapshotActionDisabled
                                )
                                .tag(snapshot.id)
                                .id(snapshot.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .focusable()
                    .focused($dashboardFocus, equals: .layoutList)
                    .onReceive(snapshotMenuController.$lastCapturedSnapshotID) { snapshotID in
                        guard let snapshotID,
                              snapshotMenuController.snapshotSummaries.contains(where: { $0.id == snapshotID }) else {
                            return
                        }

                        layoutSearchText = ""
                        selectSnapshot(id: snapshotID)
                        Task { @MainActor in
                            await Task.yield()
                            dashboardFocus = .layoutList
                            withAnimation {
                                proxy.scrollTo(snapshotID, anchor: .top)
                            }
                        }
                    }
                }

                Divider()

                if let availableUpdate = updateController.availableUpdate {
                    SidebarActionButton(
                        title: availableUpdate.actionTitle,
                        systemImage: "arrow.down.circle.fill",
                        isPrimary: true,
                        isDisabled: !updateController.canCheckForUpdates,
                        topPadding: 8,
                        bottomPadding: 0,
                        action: updateController.checkForUpdates
                    )
                }

                SidebarActionButton(
                    title: "Send Feedback",
                    systemImage: "bubble.left",
                    isPrimary: false,
                    isDisabled: false,
                    topPadding: updateController.availableUpdate == nil ? 8 : 0,
                    bottomPadding: 0,
                    action: {
                        LayoutLockSupport.openFeedbackEmail(diagnosticLogController: diagnosticLogController)
                    }
                )

                SidebarActionButton(
                    title: "Settings",
                    systemImage: "gearshape",
                    isPrimary: false,
                    isDisabled: false,
                    topPadding: 0,
                    bottomPadding: 12,
                    action: openSettingsWindow
                )
            }
            .navigationTitle("Layouts")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if raycastRecommendationController.shouldShow {
                    RaycastRecommendationBanner(
                        install: openRaycastSetup,
                        dismiss: raycastRecommendationController.dismiss
                    )
                    Divider()
                }

                DashboardDetailView(
                    bootstrapErrorMessage: bootstrapErrorMessage,
                    permissionCoordinator: permissionCoordinator,
                    permissionRouter: permissionRouter,
                    snapshotMenuController: snapshotMenuController,
                    selectedSnapshotID: selectedSnapshotID,
                    selectedSnapshot: selectedSnapshot,
                    selectedSummary: selectedSummary,
                    inlineRenameRequestID: inlineRenameRequestID,
                    hotkeyEditRequestID: hotkeyEditRequestID,
                    renameSnapshotInline: renameSnapshotInline,
                    clearHotkey: clearHotkeyFromSelectedSnapshot,
                    deleteSnapshot: deleteSelectedSnapshot,
                    removeWindow: requestWindowRemoval,
                    editOpeningTargets: requestOpeningTargetsEdit,
                    reorderWindows: reorderDisplayWindows,
                    updateSnapshot: updateSelectedSnapshot,
                    restoreSnapshot: restoreSelectedSnapshot,
                    saveSnapshot: saveSnapshot
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 940, minHeight: 640)
        .background(
            DashboardWindowObserver(
                permissionRouter: permissionRouter,
                presentationCoordinator: windowPresentationCoordinator
            )
        )
        .focusedSceneValue(\.dashboardCommandContext, dashboardCommandContext)
        .alert(
            "Update?",
            isPresented: Binding(
                get: { pendingUpdate != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingUpdate = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingUpdate = nil
            }

            Button("Update", role: .destructive) {
                updatePendingSnapshot()
            }
        } message: {
            Text(updateConfirmationMessage)
        }
        .alert(
            "Delete?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletion = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                if let snapshot = pendingDeletion {
                    snapshotMenuController.deleteSnapshot(id: snapshot.id)
                }

                pendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .sheet(item: $pendingSnapshotNameRequest) { request in
            DashboardSnapshotNamePromptView(
                request: request,
                isSaveDisabled: snapshotMenuController.isOperating,
                cancel: {
                    pendingSnapshotNameRequest = nil
                },
                save: { snapshotName in
                    guard snapshotMenuController.captureCurrentSnapshot(named: snapshotName) != nil else {
                        return
                    }

                    pendingSnapshotNameRequest = nil
                }
            )
        }
        .sheet(item: $pendingOpeningTargetsRequest) { request in
            DashboardOpeningTargetsEditorView(
                window: request.window,
                appIdentity: DashboardAppIdentityResolver.shared.identity(
                    for: request.window.bundleIdentifier
                ),
                cancel: {
                    pendingOpeningTargetsRequest = nil
                },
                save: { targets in
                    guard snapshotMenuController.setOpeningTargets(
                        targets,
                        for: request.window.id,
                        in: request.snapshotID
                    ) else {
                        return
                    }

                    pendingOpeningTargetsRequest = nil
                    refreshSelectedSnapshot()
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { pendingWindowRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingWindowRemoval = nil
                    }
                }
            )
        ) {
            if let pendingWindowRemoval {
                DashboardWindowRemovalConfirmationView(
                    confirmation: pendingWindowRemoval,
                    cancel: {
                        self.pendingWindowRemoval = nil
                    },
                    remove: removePendingWindow
                )
            }
        }
        .alert(
            "LayoutLock Pro Required",
            isPresented: Binding(
                get: { proUpgradePrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        proUpgradePrompt = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                proUpgradePrompt = nil
            }

            Button(proUpgradeAction.actionTitle) {
                proUpgradePrompt = nil
                performProUpgradeAction()
            }
        } message: {
            Text(proUpgradePrompt?.requiredPlanMessage ?? "This is a Pro feature.")
        }
        .onAppear {
            reconcileSelection(with: snapshotMenuController.snapshotSummaries)
            refreshSelectedSnapshot()
            focusLayoutList()
            raycastRecommendationController.refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            raycastRecommendationController.refreshAvailability()
        }
        .onReceive(snapshotMenuController.$snapshotSummaries) { summaries in
            reconcileSelection(with: summaries)
            refreshSelectedSnapshot()
            if let selectedSnapshotID,
               !summaries.contains(where: { $0.id == selectedSnapshotID }) {
                hotkeyEditRequestID = nil
            }
            if !DashboardSidebarSearch.showsSearchField(layoutCount: summaries.count) {
                layoutSearchText = ""
            }
        }
        .onChange(of: selectedSnapshotID) { _, _ in
            permissionRouter.clearDashboardPermissionEducationForContextChange()
        }
    }

    private func openRaycastSetup() {
        raycastRecommendationController.extensionSetupRequested()
        openURL(LayoutLockSupport.raycastURL)
    }

    private var deleteConfirmationMessage: String {
        guard let pendingDeletion else {
            return "This cannot be undone."
        }

        return "Delete \"\(pendingDeletion.name)\"? This cannot be undone."
    }

    private var updateConfirmationMessage: String {
        guard let pendingUpdate else {
            return "This replaces the saved windows with the current window state. The layout name and hotkey will be kept."
        }

        return "Replace the saved windows in \"\(pendingUpdate.name)\" with the current window state? The layout name and hotkey will be kept."
    }

    private var isSnapshotActionDisabled: Bool {
        bootstrapErrorMessage != nil || snapshotMenuController.isOperating
    }

    private var selectedSummary: SnapshotSummary? {
        guard let selectedSnapshotID else {
            return nil
        }

        return snapshotMenuController.snapshotSummaries.first(where: { $0.id == selectedSnapshotID })
    }

    private var planStatusPresentation: PlanStatusPresentation {
        PlanStatusPresentation(
            isProUnlocked: entitlementController.isProUnlocked,
            layoutCount: snapshotMenuController.snapshotSummaries.count
        )
    }

    private var isFreeLayoutLimitReached: Bool {
        !entitlementController.isProUnlocked &&
            snapshotMenuController.snapshotSummaries.count >= LayoutLockProConfiguration.freeLayoutLimit
    }

    private var showsLayoutSearch: Bool {
        DashboardSidebarSearch.showsSearchField(
            layoutCount: snapshotMenuController.snapshotSummaries.count
        )
    }

    private var visibleSnapshotSummaries: [SnapshotSummary] {
        guard showsLayoutSearch else {
            return snapshotMenuController.snapshotSummaries
        }

        return DashboardSidebarSearch.filteredSummaries(
            snapshotMenuController.snapshotSummaries,
            query: layoutSearchText
        )
    }

    private var dashboardCommandContext: DashboardCommandContext {
        let availability = DashboardCommandAvailability(
            isSnapshotActionDisabled: isSnapshotActionDisabled,
            isAccessibilityAuthorized: permissionCoordinator.authorizationState == .authorized,
            hasSelectedLayout: selectedSummary != nil,
            selectedLayoutHasHotkey: selectedSummary?.hotkey != nil
        )

        return DashboardCommandContext(
            canCreateLayout: availability.canCreateLayout,
            canRestoreLayout: availability.canRestoreLayout,
            canUpdateLayout: availability.canUpdateLayout,
            canRenameLayout: availability.canRenameLayout,
            canAssignHotkey: availability.canAssignHotkey,
            canClearHotkey: availability.canClearHotkey,
            canDeleteLayout: availability.canDeleteLayout,
            canSearchLayouts: showsLayoutSearch,
            hotkeyCommandTitle: availability.hotkeyCommandTitle,
            createLayout: saveSnapshot,
            restoreLayout: restoreSelectedSnapshot,
            updateLayout: updateSelectedSnapshot,
            renameLayout: requestInlineRenameForSelectedSnapshot,
            assignHotkey: assignHotkeyToSelectedSnapshot,
            clearHotkey: clearHotkeyFromSelectedSnapshot,
            deleteLayout: deleteSelectedSnapshot,
            focusLayoutSearch: focusLayoutSearchField
        )
    }

    private func focusLayoutList() {
        Task { @MainActor in
            await Task.yield()
            dashboardFocus = .layoutList
        }
    }

    private func focusLayoutSearchField() {
        Task { @MainActor in
            await Task.yield()
            dashboardFocus = .layoutSearch
        }
    }

    private func reconcileSelection(with summaries: [SnapshotSummary]) {
        guard !summaries.isEmpty else {
            selectedSnapshotID = nil
            pendingUpdate = nil
            pendingDeletion = nil
            pendingWindowRemoval = nil
            return
        }

        if let selectedSnapshotID,
           summaries.contains(where: { $0.id == selectedSnapshotID }) {
            return
        }

        selectedSnapshotID = DashboardSidebarSearch.replacementSelectionID(
            in: summaries,
            query: layoutSearchText
        )
    }

    @MainActor
    private func selectSnapshot(id snapshotID: UUID) {
        selectedSnapshotID = snapshotID
        selectedSnapshot = snapshotMenuController.loadSnapshot(id: snapshotID)
    }

    @MainActor
    private func assignHotkeyToSelectedSnapshot() {
        guard selectedSnapshotID != nil else {
            return
        }

        hotkeyEditRequestID = UUID()
    }

    @MainActor
    private func assignHotkey(to snapshot: SnapshotSummary) {
        selectSnapshot(id: snapshot.id)
        hotkeyEditRequestID = UUID()
    }

    @MainActor
    private func clearHotkeyFromSelectedSnapshot() {
        guard let selectedSnapshotID else {
            return
        }

        snapshotMenuController.clearHotkey(for: selectedSnapshotID)
    }

    @MainActor
    private func clearHotkey(from snapshot: SnapshotSummary) {
        selectSnapshot(id: snapshot.id)
        snapshotMenuController.clearHotkey(for: snapshot.id)
    }

    @MainActor
    private func deleteSelectedSnapshot() {
        pendingDeletion = selectedSummary
    }

    @MainActor
    private func deleteSnapshot(_ snapshot: SnapshotSummary) {
        selectSnapshot(id: snapshot.id)
        pendingDeletion = snapshot
    }

    @MainActor
    private func updateSelectedSnapshot() {
        pendingUpdate = selectedSummary
    }

    @MainActor
    private func updatePendingSnapshot() {
        guard let pendingUpdate else {
            return
        }

        defer {
            self.pendingUpdate = nil
        }

        guard permissionRouter.requestAuthorization(kind: .saveLayout, source: .dashboard) else {
            return
        }

        selectSnapshot(id: pendingUpdate.id)
        snapshotMenuController.updateSnapshot(id: pendingUpdate.id)
    }

    @MainActor
    private func requestWindowRemoval(_ window: WindowRecord) {
        guard let selectedSnapshotID,
              let selectedSummary,
              let selectedSnapshot else {
            return
        }
        guard selectedSnapshot.windows.count > 1 else {
            snapshotMenuController.reportLayoutRequiresWindow()
            return
        }

        let displayWindowCount = window.displayID.map { displayID in
            selectedSnapshot.windows.filter { $0.displayID == displayID }.count
        } ?? 0

        let appIdentity = DashboardAppIdentityResolver.shared.identity(for: window.bundleIdentifier)
        pendingWindowRemoval = DashboardWindowRemovalConfirmation(
            snapshotID: selectedSnapshotID,
            snapshotName: selectedSummary.name,
            appIdentity: appIdentity,
            windowID: window.id,
            windowTitle: window.windowTitle,
            isLastWindowOnDisplay: displayWindowCount == 1
        )
    }

    @MainActor
    private func requestOpeningTargetsEdit(_ window: WindowRecord) {
        guard let selectedSnapshotID else {
            return
        }

        pendingOpeningTargetsRequest = DashboardOpeningTargetsRequest(
            snapshotID: selectedSnapshotID,
            window: window
        )
    }

    @MainActor
    private func removePendingWindow() {
        guard let pendingWindowRemoval else {
            return
        }

        snapshotMenuController.removeWindow(
            windowID: pendingWindowRemoval.windowID,
            windowTitle: pendingWindowRemoval.windowTitle,
            appName: pendingWindowRemoval.appName,
            from: pendingWindowRemoval.snapshotID
        )
        self.pendingWindowRemoval = nil
        refreshSelectedSnapshot()
    }

    @MainActor
    private func reorderDisplayWindows(displayID: UInt32, orderedWindowIDs: [UUID]) -> Bool {
        guard let selectedSnapshotID else {
            return false
        }
        guard requirePro(.customRestoreOrder) else {
            return false
        }

        let didReorder = snapshotMenuController.reorderWindows(
            displayID: displayID,
            orderedWindowIDs: orderedWindowIDs,
            in: selectedSnapshotID
        )
        refreshSelectedSnapshot()
        return didReorder
    }

    @MainActor
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @MainActor
    private func openProSettingsWindow() {
        settingsNavigationController.showPro()
        openSettingsWindow()
    }

    @MainActor
    private func performPlanStatusAction() {
        switch PlanStatusActionResolver.action(
            for: planStatusPresentation,
            purchaseURL: LayoutLockProConfiguration.purchaseURL
        ) {
        case let .purchase(url):
            openURL(url)
        case .proSettings:
            openProSettingsWindow()
        }
    }

    private var proUpgradeAction: PlanStatusAction {
        PlanStatusActionResolver.upgradeAction(purchaseURL: LayoutLockProConfiguration.purchaseURL)
    }

    @MainActor
    private func performProUpgradeAction() {
        switch proUpgradeAction {
        case let .purchase(url):
            openURL(url)
        case .proSettings:
            openProSettingsWindow()
        }
    }

    @MainActor
    private func refreshSelectedSnapshot() {
        guard let selectedSnapshotID else {
            selectedSnapshot = nil
            return
        }

        selectedSnapshot = snapshotMenuController.loadSnapshot(id: selectedSnapshotID)
    }

    @MainActor
    private func requestInlineRenameForSelectedSnapshot() {
        guard selectedSnapshotID != nil else {
            return
        }

        inlineRenameRequestID = UUID()
    }

    @MainActor
    private func renameSnapshotInline(id snapshotID: UUID, newName: String) -> Bool {
        let success = snapshotMenuController.renameSnapshotInline(id: snapshotID, newName: newName)
        refreshSelectedSnapshot()
        return success
    }

    @MainActor
    private func restoreSelectedSnapshot() {
        guard let selectedSnapshotID else {
            return
        }

        guard permissionRouter.requestAuthorization(kind: .restoreLayout, source: .dashboard) else {
            return
        }

        snapshotMenuController.restoreSnapshot(id: selectedSnapshotID)
    }

    @MainActor
    private func saveSnapshot() {
        guard entitlementController.isProUnlocked ||
                snapshotMenuController.snapshotSummaries.count < LayoutLockProConfiguration.freeLayoutLimit else {
            requestProFeature(.unlimitedLayouts)
            return
        }

        guard permissionRouter.requestAuthorization(kind: .saveLayout, source: .dashboard) else {
            return
        }

        guard let defaultName = snapshotMenuController.suggestedSnapshotNameForCapture() else {
            return
        }

        pendingSnapshotNameRequest = DashboardSnapshotNameRequest(defaultName: defaultName)
    }

    @MainActor
    private func requestProFeature(_ feature: ProFeature) {
        snapshotMenuController.reportProRequired(for: feature)
        proUpgradePrompt = feature
    }

    @MainActor
    private func requirePro(_ feature: ProFeature) -> Bool {
        guard entitlementController.isProUnlocked else {
            requestProFeature(feature)
            return false
        }

        return true
    }
}

private struct DashboardSnapshotNamePromptView: View {
    let request: DashboardSnapshotNameRequest
    let isSaveDisabled: Bool
    let cancel: () -> Void
    let save: (String) -> Void

    @State private var draftName: String
    @FocusState private var isNameFieldFocused: Bool

    init(
        request: DashboardSnapshotNameRequest,
        isSaveDisabled: Bool,
        cancel: @escaping () -> Void,
        save: @escaping (String) -> Void
    ) {
        self.request = request
        self.isSaveDisabled = isSaveDisabled
        self.cancel = cancel
        self.save = save
        _draftName = State(initialValue: request.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save Current Layout")
                .font(.headline)

            Text("Choose a name for this layout.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Layout name", text: $draftName)
                .focused($isNameFieldFocused)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save(request.submissionName(for: draftName))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}

@MainActor
enum SavedResourcesEditorPrompt {
    static func prompt(window: WindowRecord) -> [WindowOpenTarget]? {
        let panel = SavedResourcesEditorWindow(savedWindow: window)
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.close()
        return response == .OK ? panel.savedTargets : nil
    }
}

private final class SavedResourcesEditorWindow: NSPanel, NSWindowDelegate {
    var savedTargets: [WindowOpenTarget]?

    init(savedWindow: WindowRecord) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Edit Saved Resources"
        isReleasedWhenClosed = false
        delegate = self
        contentViewController = NSHostingController(rootView: DashboardOpeningTargetsEditorView(
            window: savedWindow,
            appIdentity: DashboardAppIdentityResolver.shared.identity(for: savedWindow.bundleIdentifier),
            cancel: { NSApp.stopModal(withCode: .cancel) },
            save: { [weak self] targets in
                self?.savedTargets = targets
                NSApp.stopModal(withCode: .OK)
            }
        ))
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return false
    }

    override func cancelOperation(_: Any?) {
        NSApp.stopModal(withCode: .cancel)
    }
}

private struct DashboardOpeningTargetsEditorView: View {
    let window: WindowRecord
    let appIdentity: DashboardAppIdentity
    let cancel: () -> Void
    let save: ([WindowOpenTarget]) -> Void
    let pathSuggestionProvider: DashboardPathSuggestionProvider

    @State private var draftTargets: [WindowOpenTarget]
    @State private var pathInput = ""
    @State private var urlInput = ""
    @State private var editingURLTargetID: UUID?
    @State private var urlEditInput = ""
    @State private var urlEditFrame = CGRect.zero
    @State private var validationMessage: String?
    @State private var pathSuggestions: [DashboardPathSuggestion] = []
    @State private var highlightedPathSuggestionIndex: Int?
    @State private var dismissedSuggestionInput: String?
    @FocusState private var isPathInputFocused: Bool
    @FocusState private var focusedURLTargetID: UUID?

    private var capabilities: DashboardOpeningTargetCapabilities {
        DashboardOpeningTargetCapabilities.resolve(for: window)
    }

    private var localTargetSelection: DashboardLocalTargetSelection {
        capabilities.localTargetSelection
    }

    init(
        window: WindowRecord,
        appIdentity: DashboardAppIdentity,
        cancel: @escaping () -> Void,
        save: @escaping ([WindowOpenTarget]) -> Void,
        pathSuggestionProvider: DashboardPathSuggestionProvider = DashboardPathSuggestionProvider()
    ) {
        self.window = window
        self.appIdentity = appIdentity
        self.cancel = cancel
        self.save = save
        self.pathSuggestionProvider = pathSuggestionProvider
        _draftTargets = State(initialValue: window.openingConfiguration.effectiveTargets)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(nsImage: appIdentity.icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(appIdentity.name)
                                .font(.headline)
                        }
                    }
                }

                Section {
                    if draftTargets.isEmpty {
                        ContentUnavailableView(
                            "No Saved Resources",
                            systemImage: "app"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(draftTargets.enumerated()), id: \.element.id) { index, target in
                            targetRow(target, at: index)
                        }
                    }
                } header: {
                    Text("Saved Resources")
                } footer: {
                    Text("Files, folders, and websites to reopen with this window.")
                }

                if localTargetSelection != .none {
                    Section(localTargetSelection.sectionTitle) {
                        HStack {
                            TextField("Path", text: $pathInput, prompt: Text("~/"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .accessibilityLabel(localTargetSelection.accessibilityLabel)
                                .focused($isPathInputFocused)
                                .onChange(of: isPathInputFocused) { _, isFocused in
                                    if isFocused {
                                        dismissedSuggestionInput = nil
                                    }
                                }
                                .onSubmit {
                                    submitTypedPath()
                                }
                                .onKeyPress(.upArrow) {
                                    movePathSuggestionHighlight(offset: -1)
                                }
                                .onKeyPress(.downArrow) {
                                    movePathSuggestionHighlight(offset: 1)
                                }
                                .onKeyPress(.tab) {
                                    completeHighlightedPathSuggestion()
                                }
                                .onKeyPress(.escape) {
                                    dismissPathSuggestions()
                                }

                            Button(localTargetSelection.addButtonTitle) {
                                addTypedPath()
                            }
                            .disabled(pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !pathSuggestions.isEmpty, isPathInputFocused {
                            pathSuggestionList
                        }

                        Button(localTargetSelection.chooseButtonTitle) {
                            chooseLocalTargets()
                        }
                    }
                }

                if capabilities.supportsWebURLs {
                    Section("Add URLs") {
                        TextEditor(text: $urlInput)
                            .font(.body.monospaced())
                            .frame(minHeight: 72)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor))
                            )
                            .accessibilityLabel("URLs, one per line")

                        HStack {
                            Text("Enter one web address per line. HTTPS is added when omitted.")
                                .font(.caption)
                                .foregroundStyle(DashboardVisualStyle.supportingText)

                            Spacer()

                            Button("Add URLs") {
                                addTypedURLs()
                            }
                            .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

            }
            .formStyle(.grouped)
            .coordinateSpace(name: "openingTargetsEditor")
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("openingTargetsEditor"))
                    .onEnded { [editingURLTargetID] event in
                        guard let editingURLTargetID,
                              self.editingURLTargetID == editingURLTargetID,
                              !urlEditFrame.contains(event.location) else {
                            return
                        }

                        _ = commitURLEdit()
                    }
            )
            .navigationTitle("Saved Resources")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePendingInputs()
                    }
                }
            }
        }
        .frame(width: 680, height: 640)
        .task(id: pathSuggestionRequest) {
            await refreshPathSuggestions(for: pathSuggestionRequest)
        }
    }

    @ViewBuilder
    private func targetRow(_ target: WindowOpenTarget, at index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: targetSystemImage(for: target))
                .frame(width: 18)
                .foregroundStyle(target.isMissing() ? .orange : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if editingURLTargetID == target.id {
                    TextField("URL", text: $urlEditInput)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedURLTargetID, equals: target.id)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("openingTargetsEditor"))
                        } action: { frame in
                            urlEditFrame = frame
                        }
                        .onChange(of: focusedURLTargetID) { previousID, focusedID in
                            if previousID == target.id,
                               focusedID != target.id,
                               editingURLTargetID == target.id {
                                _ = commitURLEdit()
                            }
                        }
                        .onSubmit { _ = commitURLEdit() }
                        .onKeyPress(.escape) {
                            editingURLTargetID = nil
                            validationMessage = nil
                            return .handled
                        }
                        .accessibilityLabel("Saved resource URL")
                } else {
                    Text(targetDisplayName(for: target))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(target.url.isFileURL ? target.url.path : target.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(target.isMissing() ? .orange : DashboardVisualStyle.supportingText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if target.isMissing() {
                    Text("Missing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                moveTarget(at: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move resource earlier")
            .accessibilityLabel("Move Resource Earlier")

            Button {
                moveTarget(at: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == draftTargets.count - 1)
            .help("Move resource later")
            .accessibilityLabel("Move Resource Later")

            Button {
                editTarget(target)
            } label: {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.borderless)
            .help(targetEditHelp(for: target))
            .accessibilityLabel("\(targetEditHelp(for: target)) \(targetDisplayName(for: target))")

            Button(role: .destructive) {
                if editingURLTargetID == target.id {
                    editingURLTargetID = nil
                    validationMessage = nil
                }
                draftTargets.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove resource")
            .accessibilityLabel("Remove Resource")
        }
    }

    private func targetSystemImage(for target: WindowOpenTarget) -> String {
        switch target.kind {
        case .file:
            return "doc"
        case .folder:
            return "folder"
        case .webURL:
            return "link"
        }
    }

    private func targetDisplayName(for target: WindowOpenTarget) -> String {
        target.compactDisplayName
    }

    private func targetEditHelp(for target: WindowOpenTarget) -> String {
        switch target.kind {
        case .file:
            return target.isMissing() ? "Locate missing file…" : "Change file…"
        case .folder:
            return target.isMissing() ? "Locate missing folder…" : "Change folder…"
        case .webURL:
            return "Edit URL…"
        }
    }

    @ViewBuilder
    private var pathSuggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pathSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            completePathSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.kind == .folder ? "folder" : "doc")
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)

                                Text(suggestion.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                index == highlightedPathSuggestionIndex
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .id(index)
                        .onHover { isHovered in
                            if isHovered {
                                highlightedPathSuggestionIndex = index
                            }
                        }
                        .accessibilityLabel(
                            "\(suggestion.kind == .folder ? "Folder" : "File"), \(suggestion.name)"
                        )
                        .accessibilityHint(
                            suggestion.isSelectable
                                ? "Complete this resource path"
                                : "Open this folder to continue browsing"
                        )
                    }
                }
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            }
            .onChange(of: highlightedPathSuggestionIndex) { _, index in
                guard let index else {
                    return
                }

                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private var pathSuggestionRequest: DashboardPathSuggestionRequest {
        DashboardPathSuggestionRequest(
            input: pathInput,
            selection: localTargetSelection,
            isActive: isPathInputFocused
                && dismissedSuggestionInput != pathInput
        )
    }

    private func refreshPathSuggestions(
        for request: DashboardPathSuggestionRequest
    ) async {
        guard request.isActive else {
            pathSuggestions = []
            highlightedPathSuggestionIndex = nil
            return
        }

        pathSuggestions = []
        highlightedPathSuggestionIndex = nil

        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return
        }

        let suggestions = await pathSuggestionProvider.suggestions(
            for: request.input,
            selection: request.selection
        )
        guard !Task.isCancelled, request == pathSuggestionRequest else {
            return
        }

        pathSuggestions = suggestions
        highlightedPathSuggestionIndex = suggestions.isEmpty ? nil : 0
    }

    private func movePathSuggestionHighlight(offset: Int) -> KeyPress.Result {
        guard !pathSuggestions.isEmpty else {
            return .ignored
        }

        highlightedPathSuggestionIndex = DashboardPathSuggestionNavigation.movedIndex(
            from: highlightedPathSuggestionIndex,
            offset: offset,
            suggestionCount: pathSuggestions.count
        )
        return .handled
    }

    private func completeHighlightedPathSuggestion() -> KeyPress.Result {
        guard let highlightedPathSuggestion else {
            return .ignored
        }

        completePathSuggestion(highlightedPathSuggestion)
        return .handled
    }

    private func dismissPathSuggestions() -> KeyPress.Result {
        guard !pathSuggestions.isEmpty else {
            return .ignored
        }

        dismissedSuggestionInput = pathInput
        pathSuggestions = []
        highlightedPathSuggestionIndex = nil
        return .handled
    }

    private var highlightedPathSuggestion: DashboardPathSuggestion? {
        guard let highlightedPathSuggestionIndex,
              pathSuggestions.indices.contains(highlightedPathSuggestionIndex) else {
            return nil
        }

        return pathSuggestions[highlightedPathSuggestionIndex]
    }

    private func completePathSuggestion(_ suggestion: DashboardPathSuggestion) {
        pathInput = suggestion.displayPath
        dismissedSuggestionInput = suggestion.kind == .file
            ? suggestion.displayPath
            : nil
        validationMessage = nil
        highlightedPathSuggestionIndex = nil
        isPathInputFocused = true
    }

    private func submitTypedPath() {
        if validatedTypedPath() != nil {
            addTypedPath()
        } else if let highlightedPathSuggestion {
            completePathSuggestion(highlightedPathSuggestion)
        } else {
            addTypedPath()
        }
    }

    private func validatedTypedPath() -> WindowOpenTarget? {
        try? WindowOpenTargetValidator().localTarget(
            path: pathInput,
            expectedKind: localTargetSelection.expectedKind
        )
    }

    private func addTypedPath() {
        do {
            draftTargets.append(
                try WindowOpenTargetValidator().localTarget(
                    path: pathInput,
                    expectedKind: localTargetSelection.expectedKind
                )
            )
            pathInput = ""
            dismissedSuggestionInput = nil
            pathSuggestions = []
            highlightedPathSuggestionIndex = nil
            validationMessage = nil
        } catch {
            validationMessage = error.userFacingDescription
        }
    }

    private func addTypedURLs() {
        do {
            draftTargets.append(
                contentsOf: try WindowOpenTargetValidator().webTargets(from: urlInput)
            )
            urlInput = ""
            validationMessage = nil
        } catch {
            validationMessage = error.userFacingDescription
        }
    }

    private func chooseLocalTargets() {
        guard localTargetSelection != .none else {
            return
        }

        let panel = NSOpenPanel()
        panel.worksWhenModal = true
        panel.canChooseFiles = localTargetSelection.canChooseFiles
        panel.canChooseDirectories = localTargetSelection.canChooseDirectories
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        panel.begin { response in
            guard response == .OK else {
                return
            }

            do {
                let targets = try panel.urls.map { url in
                    defer { url.stopAccessingSecurityScopedResource() }
                    return try WindowOpenTargetValidator().localTarget(
                        url: url
                    )
                }
                draftTargets.append(contentsOf: targets)
                validationMessage = nil
            } catch {
                validationMessage = error.userFacingDescription
            }
        }
    }

    private func editTarget(_ target: WindowOpenTarget) {
        if editingURLTargetID == target.id {
            focusedURLTargetID = target.id
            return
        }

        guard commitURLEdit() else {
            return
        }

        if target.kind == .webURL {
            editingURLTargetID = target.id
            urlEditInput = target.url.absoluteString
            validationMessage = nil
            focusedURLTargetID = target.id
            return
        }

        let panel = NSOpenPanel()
        panel.worksWhenModal = true
        panel.canChooseFiles = target.kind == .file
        panel.canChooseDirectories = target.kind == .folder
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = target.isMissing() ? "Locate" : "Choose"
        panel.directoryURL = target.isMissing()
            ? FileManager.default.homeDirectoryForCurrentUser
            : target.url.deletingLastPathComponent()

        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  let index = draftTargets.firstIndex(where: { $0.id == target.id }) else {
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let replacement = try WindowOpenTargetValidator().localTarget(
                    url: url,
                    expectedKind: target.kind
                )
                draftTargets[index] = target.replacingURL(replacement.url)
                validationMessage = nil
            } catch {
                validationMessage = error.userFacingDescription
            }
        }
    }

    private func commitURLEdit() -> Bool {
        guard let editingURLTargetID,
              let index = draftTargets.firstIndex(where: { $0.id == editingURLTargetID }) else {
            return true
        }

        do {
            let replacement = try WindowOpenTargetValidator().webTarget(from: urlEditInput)
            draftTargets[index] = draftTargets[index].replacingURL(replacement.url)
            self.editingURLTargetID = nil
            validationMessage = nil
            return true
        } catch {
            validationMessage = error.userFacingDescription
            focusedURLTargetID = editingURLTargetID
            return false
        }
    }

    private func moveTarget(at index: Int, offset: Int) {
        let targetIndex = index + offset
        guard draftTargets.indices.contains(targetIndex) else {
            return
        }

        draftTargets.swapAt(index, targetIndex)
    }

    private func savePendingInputs() {
        guard commitURLEdit() else {
            return
        }

        if !pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addTypedPath()
            guard validationMessage == nil else {
                return
            }
        }

        if !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addTypedURLs()
            guard validationMessage == nil else {
                return
            }
        }

        save(draftTargets)
    }
}

private struct DashboardPathSuggestionRequest: Hashable {
    let input: String
    let selection: DashboardLocalTargetSelection
    let isActive: Bool
}

private struct DashboardWindowRemovalConfirmationView: View {
    let confirmation: DashboardWindowRemovalConfirmation
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remove Window from Layout?")
                .font(.headline)

            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: confirmation.appIdentity.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmation.appName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(confirmation.windowDisplayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(confirmation.appName), \(confirmation.windowDisplayTitle)")

            Text(confirmation.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Remove", role: .destructive) {
                    remove()
                }
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}

private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let isDisabled: Bool
    var isConstrained: Bool = false
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(foregroundStyle)
                .opacity(isConstrained && !isDisabled ? 0.62 : 1)
                .background {
                    if isHovered && !isDisabled {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isConstrained && !isDisabled ? "Upgrade to Pro to save more layouts" : title)
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .padding(.horizontal, 12)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var foregroundStyle: HierarchicalShapeStyle {
        if isDisabled {
            return .tertiary
        }

        if isHovered || isPrimary {
            return .primary
        }

        return .secondary
    }
}

private struct SidebarSearchField: View {
    @Binding var searchText: String
    @FocusState.Binding var focus: DashboardFocusTarget?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search layouts", text: $searchText)
                .textFieldStyle(.plain)
                .focused($focus, equals: .layoutSearch)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct PlanStatusView: View {
    enum Style {
        case dashboard
        case menuBar
    }

    let presentation: PlanStatusPresentation
    let style: Style
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch style {
        case .dashboard:
            dashboardButton
        case .menuBar:
            menuBarButton
        }
    }

    private var dashboardButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: presentation.systemImageName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(presentation.detail)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DashboardVisualStyle.supportingText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var iconColor: Color {
        presentation.isProUnlocked ? .secondary : .accentColor
    }

    private var boost: Double {
        colorScheme == .light ? 1.5 : 1
    }

    private var backgroundColor: Color {
        if presentation.isProUnlocked {
            return Color.primary.opacity((isHovered ? 0.07 : 0.035) * boost)
        }

        if presentation.isLimitReached {
            return Color.accentColor.opacity((isHovered ? 0.18 : 0.12) * boost)
        }

        return Color.accentColor.opacity((isHovered ? 0.12 : 0.07) * boost)
    }

    private var strokeColor: Color {
        if presentation.isProUnlocked {
            return Color.primary.opacity((isHovered ? 0.1 : 0.06) * boost)
        }

        if presentation.isLimitReached {
            return Color.accentColor.opacity((isHovered ? 0.32 : 0.22) * boost)
        }

        return Color.accentColor.opacity((isHovered ? 0.22 : 0.12) * boost)
    }

    private var menuBarButton: some View {
        Button(action: action) {
            Label(presentation.menuTitle, systemImage: presentation.systemImageName)
        }
        .help(helpText)
    }

    private var helpText: String {
        presentation.isLimitReached ? "Open Pro checkout" : "Open Pro settings"
    }
}

private struct RaycastRecommendationBanner: View {
    let install: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Use LayoutLock with Raycast")
                    .font(.headline)
                Text("Save and restore layouts without leaving Raycast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Install Extension", action: install)
                .buttonStyle(.borderedProminent)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss Raycast Recommendation")
        }
        .padding(12)
        .background(.bar)
    }
}

private struct DashboardDetailView: View {
    let bootstrapErrorMessage: String?
    @ObservedObject var permissionCoordinator: PermissionCoordinator
    @ObservedObject var permissionRouter: PermissionInterventionRouter
    @ObservedObject var snapshotMenuController: SnapshotMenuController
    let selectedSnapshotID: UUID?
    let selectedSnapshot: Snapshot?
    let selectedSummary: SnapshotSummary?
    let inlineRenameRequestID: UUID?
    let hotkeyEditRequestID: UUID?
    let renameSnapshotInline: (UUID, String) -> Bool
    let clearHotkey: () -> Void
    let deleteSnapshot: () -> Void
    let removeWindow: (WindowRecord) -> Void
    let editOpeningTargets: (WindowRecord) -> Void
    let reorderWindows: (_ displayID: UInt32, _ orderedWindowIDs: [UUID]) -> Bool
    let updateSnapshot: () -> Void
    let restoreSnapshot: () -> Void
    let saveSnapshot: () -> Void

    @State private var editingSnapshotID: UUID?
    @State private var draftSnapshotName = ""
    @State private var editingHotkeySnapshotID: UUID?
    @State private var hotkeyCaptureError: String?
    @State private var runningBundleIdentifiers = Set<String>()
    @State private var dashboardPermissionSuccessTask: Task<Void, Never>?
    @State private var hasOpenedDashboardPermissionSettings = false
    @FocusState private var isTitleFieldFocused: Bool

    var body: some View {
        detailContent
        .background(.regularMaterial)
        .onAppear {
            refreshRunningBundleIdentifiers()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningBundleIdentifiers()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningBundleIdentifiers()
        }
        .onReceive(snapshotMenuController.$restoreCompletionID) { completionID in
            if completionID != nil {
                refreshRunningBundleIdentifiers()
            }
        }
        .onReceive(permissionCoordinator.$authorizationState) { authorizationState in
            handleDashboardAuthorizationState(authorizationState)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if hasOpenedDashboardPermissionSettings {
                hasOpenedDashboardPermissionSettings = false
            }
        }
        .onChange(of: permissionRouter.showsDashboardPermissionEducation) { _, showsEducation in
            if !showsEducation {
                hasOpenedDashboardPermissionSettings = false
            }
        }
        .onChange(of: selectedSummary?.id) { _, _ in
            if editingHotkeySnapshotID != nil {
                snapshotMenuController.setHotkeyCaptureActive(false)
                editingHotkeySnapshotID = nil
                hotkeyCaptureError = nil
            }
        }
        .onChange(of: selectedSnapshotID) { _, _ in
            hasOpenedDashboardPermissionSettings = false
        }
        .onDisappear {
            if editingHotkeySnapshotID != nil {
                snapshotMenuController.setHotkeyCaptureActive(false)
                editingHotkeySnapshotID = nil
                hotkeyCaptureError = nil
            }
            dashboardPermissionSuccessTask?.cancel()
            hasOpenedDashboardPermissionSettings = false
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch contentPreference {
        case .permissionEducation:
            centeredPermissionEducationContent
        case .selectedLayout:
            if let selectedSnapshot, let selectedSummary {
                standardDetailContent {
                    selectedLayoutContent(
                        snapshot: selectedSnapshot,
                        summary: selectedSummary
                    )
                }
            }
        case .emptyState:
            centeredEmptyStateContent
        }
    }

    private var contentPreference: DashboardDetailContentPreference {
        DashboardDetailContentPreference.resolve(
            showsPermissionEducation: permissionRouter.showsDashboardPermissionEducation,
            isAccessibilityAuthorized: permissionCoordinator.authorizationState == .authorized,
            hasSavedLayouts: !snapshotMenuController.snapshotSummaries.isEmpty,
            hasSelectedLayout: selectedSnapshot != nil && selectedSummary != nil
        )
    }

    private var centeredPermissionEducationContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    issueSection
                    permissionEducation
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .center
                )
            }
        }
    }

    private var centeredEmptyStateContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    issueSection
                    emptyState
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .center
                )
            }
        }
    }

    private func standardDetailContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                issueSection
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionEducation: some View {
        OnboardingPermissionEducationView(
            showsSuccess: permissionCoordinator.authorizationState == .authorized,
            hasOpenedSystemSettings: hasOpenedDashboardPermissionSettings,
            onOpenSystemSettings: openDashboardPermissionSettings,
            onCheckAgain: checkDashboardPermissionAgain,
            onDismiss: isMandatoryPermissionEducation ? nil : dismissDashboardPermissionEducation
        )
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func selectedLayoutContent(
        snapshot selectedSnapshot: Snapshot,
        summary selectedSummary: SnapshotSummary
    ) -> some View {
        header(snapshot: selectedSnapshot, summary: selectedSummary)
        metrics(summary: selectedSummary)
        DashboardSnapshotPreviewView(
            snapshot: selectedSnapshot,
            appIdentityResolver: .shared,
            removeWindow: removeWindow,
            editOpeningTargets: editOpeningTargets,
            reorderWindows: reorderWindows
        )
        .id(selectedSnapshot.id)
        DashboardInactiveAppsView(
            snapshot: selectedSnapshot,
            appIdentityResolver: .shared,
            runningBundleIdentifiers: runningBundleIdentifiers
        )
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.3.group.bubble.left.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .font(.system(size: 60))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("No Saved Layouts")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                VStack(spacing: 4) {
                    Text("Arrange your windows the way you want, then save the layout.")
                    Text("Saved layouts appear in the sidebar and menu bar.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            if permissionCoordinator.authorizationState == .authorized {
                Button("Save Current Layout") {
                    saveSnapshot()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)
            }
        }
    }

    private func header(snapshot: Snapshot, summary: SnapshotSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if editingSnapshotID == snapshot.id {
                        TextField("Layout name", text: $draftSnapshotName)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(1)
                            .focused($isTitleFieldFocused)
                            .onSubmit {
                                commitInlineRename(for: snapshot)
                            }
                            .onExitCommand {
                                cancelInlineRename()
                            }
                    } else {
                        Text(snapshot.name)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture(count: 2) {
                                beginInlineRename(snapshot)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                snapshotActionStrip(snapshot: snapshot, summary: summary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text("Updated \(DashboardRelativeDateFormatter.string(from: summary.updatedAt))")
                .foregroundStyle(DashboardVisualStyle.supportingText)
        }
        .onChange(of: snapshot.id) { _, _ in
            cancelInlineRename()
            cancelHotkeyEditing()
        }
        .onChange(of: inlineRenameRequestID) { _, requestID in
            guard requestID != nil else {
                return
            }

            beginInlineRename(snapshot)
        }
        .onChange(of: hotkeyEditRequestID) { _, requestID in
            guard requestID != nil else {
                return
            }

            beginHotkeyEditing(for: snapshot)
        }
    }

    private func snapshotActionStrip(snapshot: Snapshot, summary: SnapshotSummary) -> some View {
        let isDisabled = bootstrapErrorMessage != nil || snapshotMenuController.isOperating
        let isPrivilegedActionDisabled = isDisabled || permissionCoordinator.authorizationState != .authorized

        return HStack(alignment: .center, spacing: 8) {
            Button {
                restoreSnapshot()
            } label: {
                Label("Restore", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isPrivilegedActionDisabled)
            .help("Restore the saved windows, apps, and resources in this layout")

            Button {
                updateSnapshot()
            } label: {
                Label("Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isPrivilegedActionDisabled)
            .help("Replace this saved layout with your current windows")

            Button {
                beginInlineRename(snapshot)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(isDisabled)
            .help("Rename")

            Button {
                snapshotMenuController.togglePin(for: snapshot.id)
            } label: {
                Label(
                    summary.isPinned ? "Unpin" : "Pin",
                    systemImage: summary.isPinned ? "pin.fill" : "pin"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .help(summary.isPinned ? "Unpin" : "Pin")

            Button(role: .destructive) {
                deleteSnapshot()
            } label: {
                Image(systemName: "trash")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.medium)
                    .accessibilityLabel("Delete")
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .help("Delete")
        }
        .controlSize(.regular)
    }

    private func beginInlineRename(_ snapshot: Snapshot) {
        guard bootstrapErrorMessage == nil, !snapshotMenuController.isOperating else {
            return
        }

        editingSnapshotID = snapshot.id
        draftSnapshotName = snapshot.name
        Task { @MainActor in
            await Task.yield()
            isTitleFieldFocused = true
        }
    }

    private func commitInlineRename(for snapshot: Snapshot) {
        guard editingSnapshotID == snapshot.id else {
            return
        }

        if renameSnapshotInline(snapshot.id, draftSnapshotName) {
            editingSnapshotID = nil
            isTitleFieldFocused = false
        } else {
            isTitleFieldFocused = true
        }
    }

    private func cancelInlineRename() {
        editingSnapshotID = nil
        draftSnapshotName = ""
        isTitleFieldFocused = false
    }

    private func beginHotkeyEditing(for snapshot: Snapshot) {
        guard bootstrapErrorMessage == nil, !snapshotMenuController.isOperating else {
            return
        }

        if snapshotMenuController.setHotkeyCaptureActive(true) != nil {
            return
        }

        editingHotkeySnapshotID = snapshot.id
        hotkeyCaptureError = nil
    }

    private func beginHotkeyEditing(for summary: SnapshotSummary) {
        guard bootstrapErrorMessage == nil, !snapshotMenuController.isOperating else {
            return
        }

        if snapshotMenuController.setHotkeyCaptureActive(true) != nil {
            return
        }

        editingHotkeySnapshotID = summary.id
        hotkeyCaptureError = nil
    }

    private func cancelHotkeyEditing() {
        if editingHotkeySnapshotID != nil {
            snapshotMenuController.setHotkeyCaptureActive(false)
        }
        editingHotkeySnapshotID = nil
        hotkeyCaptureError = nil
    }

    private func commitHotkeyCapture(_ binding: HotkeyBinding, for snapshotID: UUID) {
        let success = snapshotMenuController.setHotkey(binding, for: snapshotID)
        guard success else {
            return
        }
        snapshotMenuController.setHotkeyCaptureActive(false)
        editingHotkeySnapshotID = nil
        hotkeyCaptureError = nil
    }

    private func unavailableHotkeys(for snapshotID: UUID) -> [(binding: HotkeyBinding, snapshotName: String)] {
        snapshotMenuController.snapshotSummaries.compactMap { summary in
            guard summary.id != snapshotID, let hotkey = summary.hotkey else {
                return nil
            }
            return (binding: hotkey, snapshotName: summary.name)
        }
    }

    private func metrics(summary: SnapshotSummary) -> some View {
        let metrics: [(String, String)] = [
            ("Windows", "\(summary.windowCount)"),
            ("Apps", "\(summary.appCount)"),
            ("Displays", "\(summary.displayCount)")
        ]

        let isEditing = editingHotkeySnapshotID == summary.id

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(metrics, id: \.0) { metric in
                DashboardMetricCard(title: metric.0, value: metric.1)
            }

            DashboardHotkeyMetricCard(
                summary: summary,
                isEditing: isEditing,
                captureError: hotkeyCaptureError,
                isActionDisabled: bootstrapErrorMessage != nil || snapshotMenuController.isOperating,
                unavailableHotkeys: unavailableHotkeys(for: summary.id),
                onEdit: { beginHotkeyEditing(for: summary) },
                onClear: clearHotkey,
                onCancel: cancelHotkeyEditing,
                onCapture: { binding in commitHotkeyCapture(binding, for: summary.id) },
                onError: { error in hotkeyCaptureError = error },
                onDismissError: { hotkeyCaptureError = nil }
            )
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        if hasDashboardIssues {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = snapshotMenuController.restoreProgressMessage {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress)
                            .font(.callout)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardCardSurface(cornerRadius: 10)
                }
                if let bootstrapErrorMessage {
                    DashboardIssueBanner(
                        title: "Storage Setup Failed",
                        message: bootstrapErrorMessage,
                        systemImage: "externaldrive.badge.exclamationmark",
                        tint: .red
                    )
                }

                if showsAccessibilityIssueBanner {
                    DashboardIssueBanner(
                        title: "Accessibility Required",
                        message: "Grant permission before saving or restoring layouts.",
                        systemImage: "hand.raised.fill",
                        tint: .orange,
                        actionTitle: "Open Permissions"
                    ) {
                        permissionCoordinator.openAccessibilitySettings()
                    }
                }

                if let status = snapshotMenuController.status,
                   (status.isError || status.isWarning) && snapshotMenuController.restoreProgressMessage == nil {
                    DashboardIssueBanner(
                        title: status.isWarning ? "Layout Needs Attention" : "Layout Action Failed",
                        message: status.message,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: status.isWarning ? .orange : .red
                    )
                }
            }
        }
    }

    private var hasDashboardIssues: Bool {
        bootstrapErrorMessage != nil
            || snapshotMenuController.restoreProgressMessage != nil
            || showsAccessibilityIssueBanner
            || snapshotMenuController.status?.isError == true
            || snapshotMenuController.status?.isWarning == true
    }

    private var showsAccessibilityIssueBanner: Bool {
        permissionCoordinator.authorizationState != .authorized
            && contentPreference != .permissionEducation
    }

    private var isMandatoryPermissionEducation: Bool {
        permissionCoordinator.authorizationState != .authorized
            && snapshotMenuController.snapshotSummaries.isEmpty
    }

    private static func currentRunningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func refreshRunningBundleIdentifiers() {
        runningBundleIdentifiers = Self.currentRunningBundleIdentifiers()
    }

    private func checkDashboardPermissionAgain() {
        handleDashboardAuthorizationState(
            permissionCoordinator.refreshTrust(trigger: .manualCheckAgain)
        )
    }

    private func handleDashboardAuthorizationState(_ state: AccessibilityAuthorizationState) {
        guard permissionRouter.showsDashboardPermissionEducation else {
            return
        }

        guard state == .authorized else {
            dashboardPermissionSuccessTask?.cancel()
            dashboardPermissionSuccessTask = nil
            hasOpenedDashboardPermissionSettings = false
            return
        }

        dashboardPermissionSuccessTask?.cancel()
        dashboardPermissionSuccessTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else {
                return
            }

            permissionRouter.clearDashboardPermissionEducation()
            hasOpenedDashboardPermissionSettings = false
            dashboardPermissionSuccessTask = nil
        }
    }

    private func openDashboardPermissionSettings() {
        hasOpenedDashboardPermissionSettings = true
        permissionRouter.openAccessibilitySettings()
    }

    private func dismissDashboardPermissionEducation() {
        hasOpenedDashboardPermissionSettings = false
        permissionRouter.dismissDashboardPermissionEducation()
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let actionSystemImage: String?
    let actionAccessibilityLabel: String?
    let isActionDisabled: Bool
    let action: (() -> Void)?

    init(
        title: String,
        value: String,
        actionSystemImage: String? = nil,
        actionAccessibilityLabel: String? = nil,
        isActionDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.value = value
        self.actionSystemImage = actionSystemImage
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.isActionDisabled = isActionDisabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(DashboardVisualStyle.supportingText)

            HStack(spacing: 8) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if let actionSystemImage, let action {
                    Button(action: action) {
                        Image(systemName: actionSystemImage)
                            .symbolRenderingMode(.hierarchical)
                            .imageScale(.medium)
                            .accessibilityLabel(actionAccessibilityLabel ?? title)
                    }
                    .buttonStyle(.plain)
                    .disabled(isActionDisabled)
                    .help(actionAccessibilityLabel ?? title)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 14)
    }
}

private struct DashboardHotkeyMetricCard: View {
    let summary: SnapshotSummary
    let isEditing: Bool
    let captureError: String?
    let isActionDisabled: Bool
    let unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    let onEdit: () -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    let onCapture: (HotkeyBinding) -> Void
    let onError: (String) -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkey")
                .font(.caption.weight(.medium))
                .foregroundStyle(DashboardVisualStyle.supportingText)

            if isEditing {
                HStack(spacing: 8) {
                    InlineHotkeyCaptureField(
                        hasError: captureError != nil,
                        unavailableHotkeys: unavailableHotkeys,
                        onCapture: onCapture,
                        onError: onError,
                        onCancel: onCancel
                    )
                    .frame(minWidth: 100, maxWidth: .infinity, minHeight: 15)

                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .imageScale(.medium)
                            .accessibilityLabel("Cancel")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
                .popover(
                    isPresented: Binding(
                        get: { captureError != nil },
                        set: { isPresented in
                            if !isPresented {
                                onDismissError()
                            }
                        }
                    ),
                    arrowEdge: .bottom
                ) {
                    if let captureError {
                        HotkeyCaptureErrorPopover(message: captureError)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(hotkeySymbolicString(summary.hotkey))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .symbolRenderingMode(.hierarchical)
                            .imageScale(.medium)
                            .accessibilityLabel("Edit Hotkey")
                    }
                    .buttonStyle(.plain)
                    .disabled(isActionDisabled)
                    .help("Edit Hotkey")

                    if summary.hotkey != nil {
                        Button(action: onClear) {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .imageScale(.medium)
                                .accessibilityLabel("Clear Hotkey")
                        }
                        .buttonStyle(.plain)
                        .disabled(isActionDisabled)
                        .help("Clear Hotkey")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 14)
        .animation(.easeInOut(duration: 0.15), value: isEditing)
    }
}

private struct HotkeyCaptureErrorPopover: View {
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)

            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

private func hotkeySymbolicString(_ binding: HotkeyBinding?) -> String {
    guard let binding else {
        return "None"
    }

    return binding.displayString
        .replacingOccurrences(of: "Command-", with: "⌘")
        .replacingOccurrences(of: "Option-", with: "⌥")
        .replacingOccurrences(of: "Control-", with: "⌃")
        .replacingOccurrences(of: "Shift-", with: "⇧")
}

private struct InlineHotkeyCaptureField: NSViewRepresentable {
    let hasError: Bool
    let unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    let onCapture: (HotkeyBinding) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> InlineHotkeyCaptureNSView {
        let view = InlineHotkeyCaptureNSView()
        view.onCapture = onCapture
        view.onError = onError
        view.onCancel = onCancel
        view.hasError = hasError
        view.unavailableHotkeys = unavailableHotkeys
        return view
    }

    func updateNSView(_ nsView: InlineHotkeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onError = onError
        nsView.onCancel = onCancel
        nsView.hasError = hasError
        nsView.unavailableHotkeys = unavailableHotkeys
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class InlineHotkeyCaptureNSView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)] = []
    var hasError = false {
        didSet {
            if oldValue != hasError {
                needsDisplay = true
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let roundedRect = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let fillColor = hasError
            ? NSColor.systemRed.withAlphaComponent(0.10)
            : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12)
        fillColor.setFill()
        roundedRect.fill()
        if hasError {
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            roundedRect.lineWidth = 1
            roundedRect.stroke()
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .paragraphStyle: paragraphStyle
        ]
        let str = NSAttributedString(string: "Press shortcut", attributes: attrs)
        let textRect = str.boundingRect(with: NSSize(width: bounds.width - 8, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textX = (bounds.width - textRect.width) / 2
        let textY = (bounds.height - textRect.height) / 2
        str.draw(in: NSRect(x: textX, y: textY, width: textRect.width, height: textRect.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        do {
            let binding = try HotkeyBindingValidator.binding(from: event)
            if let duplicate = unavailableHotkeys.first(where: { $0.binding.matches(binding) }) {
                onError?("\"\(duplicate.snapshotName)\" already uses that hotkey.")
                return
            }
            onCapture?(binding)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

struct DashboardRelativeDateFormatter {
    private static let justNowThreshold: TimeInterval = 60
    private static let formatter = RelativeDateTimeFormatter()

    static func string(from date: Date, relativeTo referenceDate: Date = Date()) -> String {
        if abs(date.timeIntervalSince(referenceDate)) <= justNowThreshold {
            return "just now"
        }

        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
}

private struct DashboardSnapshotRow: View {
    let snapshot: SnapshotSummary
    let isSelected: Bool
    let renameSnapshotInline: (UUID, String) -> Bool
    let assignHotkey: () -> Void
    let clearHotkey: () -> Void
    let togglePin: () -> Void
    let deleteSnapshot: () -> Void
    let isActionDisabled: Bool

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFieldFocused: Bool

    private var showsActions: Bool {
        isHovered
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if snapshot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(supportingForeground)
                            .accessibilityLabel("Pinned layout")
                    }

                    if isRenaming {
                        TextField("Layout name", text: $draftName)
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .focused($isNameFieldFocused)
                            .onSubmit {
                                commitInlineRename()
                            }
                            .onExitCommand {
                                cancelInlineRename()
                            }
                    } else {
                        Text(snapshot.name)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                beginInlineRename()
                            }
                    }
                    Spacer(minLength: 8)
                    if let hotkey = snapshot.hotkey?.displayString {
                        Text(hotkey)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(supportingForeground)
                            .lineLimit(1)
                    }
                }

                Text("\(snapshot.windowCount) windows • \(snapshot.displayCount) displays • \(DashboardRelativeDateFormatter.string(from: snapshot.updatedAt))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(supportingForeground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                snapshotActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.medium)
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Layout actions")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .opacity(showsActions ? 1 : 0)
            .disabled(!showsActions)
            .accessibilityHidden(!showsActions)
            .help("Layout actions")
            .frame(width: 22, height: 22)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .contextMenu {
            snapshotActions
        }
        .onChange(of: snapshot.id) { _, _ in
            cancelInlineRename()
        }
    }

    private var supportingForeground: Color {
        isSelected
            ? DashboardVisualStyle.selectedSupportingText
            : DashboardVisualStyle.supportingText
    }

    @ViewBuilder
    private var snapshotActions: some View {
        Button("Rename") {
            beginInlineRename()
        }
        .disabled(isActionDisabled)

        Button(snapshot.isPinned ? "Unpin" : "Pin") {
            togglePin()
        }
        .disabled(isActionDisabled)

        Button(snapshot.hotkey == nil ? "Set Hotkey" : "Change Hotkey") {
            assignHotkey()
        }
        .disabled(isActionDisabled)

        if snapshot.hotkey != nil {
            Button("Clear Hotkey") {
                clearHotkey()
            }
            .disabled(isActionDisabled)
        }

        Divider()

        Button("Delete", role: .destructive) {
            deleteSnapshot()
        }
        .disabled(isActionDisabled)
    }

    private func beginInlineRename() {
        guard !isActionDisabled else {
            return
        }

        isRenaming = true
        draftName = snapshot.name
        Task { @MainActor in
            await Task.yield()
            isNameFieldFocused = true
        }
    }

    private func commitInlineRename() {
        guard isRenaming else {
            return
        }

        if renameSnapshotInline(snapshot.id, draftName) {
            isRenaming = false
            isNameFieldFocused = false
        } else {
            isNameFieldFocused = true
        }
    }

    private func cancelInlineRename() {
        isRenaming = false
        draftName = ""
        isNameFieldFocused = false
    }
}

private struct DashboardIssueBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(DashboardVisualStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 8)
    }
}

private struct DashboardWindowObserver: NSViewRepresentable {
    let permissionRouter: PermissionInterventionRouter
    let presentationCoordinator: DashboardWindowPresentationCoordinator

    func makeNSView(context _: Context) -> DashboardWindowObserverView {
        DashboardWindowObserverView(
            presentationCoordinator: presentationCoordinator
        ) { visibility in
            permissionRouter.updateDashboardWindowVisibility(visibility)
        }
    }

    func updateNSView(_: DashboardWindowObserverView, context _: Context) {}
}

private final class DashboardWindowObserverView: NSView {
    private struct ObserverToken {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let onVisibilityChange: (DashboardWindowVisibility) -> Void
    private let presentationCoordinator: DashboardWindowPresentationCoordinator
    private var observedWindow: NSWindow?
    private var observers: [ObserverToken] = []

    init(
        presentationCoordinator: DashboardWindowPresentationCoordinator,
        onVisibilityChange: @escaping (DashboardWindowVisibility) -> Void
    ) {
        self.presentationCoordinator = presentationCoordinator
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removeObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else {
            removeObservers()
            observedWindow = nil
            Task { @MainActor [weak self] in
                guard let self, self.window == nil else {
                    return
                }

                self.onVisibilityChange(.notVisible)
            }
            return
        }

        DashboardWindowSupport.configure(window)
        presentationCoordinator.presentInitialWindow(window)
        observe(window: window)
        Task { @MainActor [weak self, weak window] in
            guard let self,
                  let window,
                  self.window === window,
                  self.observedWindow === window else {
                return
            }

            self.updateVisibility()
        }
    }

    func updateVisibility() {
        guard let window = observedWindow, !NSApp.isHidden else {
            onVisibilityChange(.notVisible)
            return
        }

        onVisibilityChange(
            .from(
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isOnActiveSpace: window.isOnActiveSpace
            )
        )
    }

    private func observe(window: NSWindow) {
        guard observedWindow !== window else {
            return
        }

        removeObservers()
        observedWindow = window

        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ]

        names.forEach { name in
            addObserver(
                center: .default,
                name: name,
                object: window
            ) { [weak self] _ in
                self?.updateVisibility()
            }
        }

        let frameSaveNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification
        ]

        frameSaveNames.forEach { name in
            addObserver(
                center: .default,
                name: name,
                object: window
            ) { [weak window] _ in
                guard let window else {
                    return
                }

                DashboardWindowSupport.saveFrame(window)
            }
        }

        addObserver(
            center: .default,
            name: NSWindow.willCloseNotification,
            object: window
        ) { [weak self] _ in
            if let window = self?.observedWindow {
                DashboardWindowSupport.saveFrame(window)
            }

            self?.removeObservers()
            self?.observedWindow = nil
            self?.onVisibilityChange(.notVisible)
        }

        addObserver(
            center: .default,
            name: NSApplication.willTerminateNotification,
            object: nil
        ) { [weak self] _ in
            guard let window = self?.observedWindow else {
                return
            }

            DashboardWindowSupport.saveFrame(window)
        }

        addObserver(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        ) { [weak self] _ in
            self?.updateVisibility()
        }

        addObserver(
            center: .default,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        ) { [weak self] _ in
            self?.updateVisibility()
        }

        addObserver(
            center: .default,
            name: NSApplication.didHideNotification,
            object: nil
        ) { [weak self] _ in
            self?.onVisibilityChange(.notVisible)
        }

        addObserver(
            center: .default,
            name: NSApplication.didUnhideNotification,
            object: nil
        ) { [weak self] _ in
            self?.updateVisibility()
        }
    }

    private func addObserver(
        center: NotificationCenter,
        name: Notification.Name,
        object: Any?,
        handler: @escaping (Notification) -> Void
    ) {
        let token = center.addObserver(
            forName: name,
            object: object,
            queue: .main,
            using: handler
        )

        observers.append(ObserverToken(center: center, token: token))
    }

    private func removeObservers() {
        observers.forEach { observer in
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }
}

enum DashboardWindowSupport {
    static let frameAutosaveName = "LayoutLockDashboard"
    static let sceneID = "dashboard"
    static let identifier = NSUserInterfaceItemIdentifier("LayoutLockDashboardWindow")
    static let defaultSize = CGSize(width: 940, height: 640)

    @MainActor
    static func configure(_ window: NSWindow, frameAutosaveName: String = Self.frameAutosaveName) {
        window.identifier = identifier
        window.setFrameAutosaveName(frameAutosaveName)
    }

    @MainActor
    static func saveFrame(_ window: NSWindow, frameAutosaveName: String = Self.frameAutosaveName) {
        window.saveFrame(usingName: frameAutosaveName)
    }

    @MainActor
    static func focusExistingWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @MainActor
    @discardableResult
    static func bringToFrontIfVisible() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == identifier &&
            $0.isVisible &&
            !$0.isMiniaturized
        }) else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @MainActor
    static func openOrFocusDashboard(using openWindow: OpenWindowAction) {
        if !focusExistingWindow() {
            openWindow(id: sceneID)
            Task { @MainActor in
                await Task.yield()
                _ = focusExistingWindow()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}
