import SwiftUI

@main
struct LayoutLockApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: LayoutLockAppDelegate
    @StateObject private var permissionCoordinator: PermissionCoordinator
    @StateObject private var permissionRouter: PermissionInterventionRouter
    @StateObject private var onboardingController: OnboardingController
    @StateObject private var snapshotMenuController: SnapshotMenuController
    @StateObject private var launchAtLoginController: LaunchAtLoginController
    @StateObject private var browserAutomationController: BrowserAutomationController
    @StateObject private var entitlementController: EntitlementController
    @StateObject private var settingsNavigationController: SettingsNavigationController
    @StateObject private var updateController: AppUpdateController
    @StateObject private var raycastRecommendationController: RaycastRecommendationController

    private let bootstrapErrorMessage: String?
    private let diagnosticLogController: DiagnosticLogController?
    private let displayChangeRestoreController: DisplayChangeRestoreController?
    private let externalCommandCoordinator: ExternalCommandCoordinator
    private let launchMode: AppLaunchMode
    private let launchPresentationState: AppLaunchPresentationState
    private let dashboardPresentationCoordinator: DashboardWindowPresentationCoordinator
    private let hotkeyManager: HotkeyManager
    private let operationOverlayController: OperationOverlayController

    init() {
        LayoutLockSettings.registerDefaults()

        let snapshotMenuController: SnapshotMenuController
        let browserAutomationController: BrowserAutomationController
        let operationOverlayController = OperationOverlayController()
        let snapshotStoreForDisplayChanges: SnapshotStore?
        let entitlementController = EntitlementController()
        let settingsNavigationController = SettingsNavigationController()
        let updateController = AppUpdateController()
        let raycastRecommendationController = RaycastRecommendationController()
        let launchMode = AppLaunchMode(arguments: ProcessInfo.processInfo.arguments)
        let launchPresentationState = AppLaunchPresentationState()
        let dashboardPresentationCoordinator = DashboardWindowPresentationCoordinator(
            launchMode: launchMode,
            presentationState: launchPresentationState
        )
        let integrationIndexWriter: LayoutIntegrationIndexWriter?

        do {
            let bootstrapper = try AppSupportDirectoryBootstrapper()
            try bootstrapper.prepare()
            integrationIndexWriter = LayoutIntegrationIndexWriter(bootstrapper: bootstrapper)
            bootstrapErrorMessage = nil
            let snapshotStore = SnapshotStore(bootstrapper: bootstrapper)
            snapshotStoreForDisplayChanges = snapshotStore
            let telemetryLogger = TelemetryLogger(
                eventsLogURL: bootstrapper.logsURL.appendingPathComponent("events.log")
            )
            telemetryLogger.performMaintenance()
            diagnosticLogController = DiagnosticLogController(eventsLogURL: telemetryLogger.eventsLogURL)
            browserAutomationController = BrowserAutomationController(
                telemetryLogger: telemetryLogger
            )
            snapshotMenuController = SnapshotMenuController(
                snapshotStore: snapshotStore,
                snapshotCaptureService: SnapshotCaptureService(
                    snapshotStore: snapshotStore,
                    telemetryLogger: telemetryLogger
                ),
                restoreEngine: RestoreEngine(
                    snapshotStore: snapshotStore,
                    telemetryLogger: telemetryLogger
                ),
                operationOverlayPresenter: operationOverlayController,
                entitlementProvider: entitlementController
            )
        } catch {
            bootstrapErrorMessage = error.localizedDescription
            diagnosticLogController = nil
            snapshotStoreForDisplayChanges = nil
            integrationIndexWriter = nil
            browserAutomationController = BrowserAutomationController()
            snapshotMenuController = SnapshotMenuController(entitlementProvider: entitlementController)
            AppLogger.app.error("Failed to prepare Application Support directories: \(error.localizedDescription)")
        }

        let permissionCoordinator = PermissionCoordinator()
        let permissionRouter = PermissionInterventionRouter(
            permissionCoordinator: permissionCoordinator,
            statusNoticePresenter: operationOverlayController
        )
        let onboardingController = OnboardingController(permissionCoordinator: permissionCoordinator)
        let hotkeyManager = HotkeyManager { [weak permissionRouter, weak snapshotMenuController] snapshotID in
            Task { @MainActor in
                guard let permissionRouter,
                      let snapshotMenuController,
                      permissionRouter.requestAuthorization(kind: .restoreLayout, source: .hotkey) else {
                    return
                }

                snapshotMenuController.restoreSnapshot(id: snapshotID)
            }
        }

        snapshotMenuController.setSnapshotSummariesDidChange { [weak snapshotMenuController, hotkeyManager] summaries in
            do {
                try integrationIndexWriter?.write(summaries: summaries)
            } catch {
                AppLogger.app.error("Failed to update the Raycast layout index: \(error.localizedDescription)")
            }

            do {
                try hotkeyManager.reloadBindings(from: summaries)
                return nil
            } catch {
                snapshotMenuController?.reportHotkeyRegistrationFailure(error)
                return error
            }
        }

        snapshotMenuController.setHotkeyCaptureActivityDidChange { isActive in
            if isActive {
                hotkeyManager.suspendBindings()
                return nil
            } else {
                do {
                    try hotkeyManager.resumeBindings()
                    return nil
                } catch {
                    return error
                }
            }
        }

        if let snapshotStoreForDisplayChanges {
            let displayChangeRestoreController = DisplayChangeRestoreController(
                snapshotStore: snapshotStoreForDisplayChanges,
                permissionCoordinator: permissionCoordinator,
                snapshotMenuController: snapshotMenuController,
                suggestionPresenter: operationOverlayController,
                entitlementProvider: entitlementController
            ) { [weak permissionRouter, weak snapshotMenuController] snapshotID in
                guard let permissionRouter,
                      let snapshotMenuController,
                      permissionRouter.requestAuthorization(kind: .restoreLayout, source: .displayChange) else {
                    return
                }

                snapshotMenuController.restoreSnapshot(id: snapshotID)
            }
            displayChangeRestoreController.start()
            self.displayChangeRestoreController = displayChangeRestoreController
        } else {
            self.displayChangeRestoreController = nil
        }

        self.hotkeyManager = hotkeyManager
        self.operationOverlayController = operationOverlayController
        self.launchMode = launchMode
        self.launchPresentationState = launchPresentationState
        self.dashboardPresentationCoordinator = dashboardPresentationCoordinator
        let externalCommandCoordinator = ExternalCommandCoordinator(
            permissionRouter: permissionRouter,
            snapshotMenuController: snapshotMenuController,
            presentationState: launchPresentationState,
            statusNoticePresenter: operationOverlayController,
            externalIntegrationWasUsed: raycastRecommendationController.externalIntegrationWasUsed
        )
        self.externalCommandCoordinator = externalCommandCoordinator
        entitlementController.onEntitlementDidChange = { [weak snapshotMenuController] in
            _ = snapshotMenuController?.refreshSummaries()
        }
        Task { @MainActor in
            await entitlementController.validateCachedLicenseIfNeeded()
        }
        _permissionCoordinator = StateObject(wrappedValue: permissionCoordinator)
        _permissionRouter = StateObject(wrappedValue: permissionRouter)
        _onboardingController = StateObject(wrappedValue: onboardingController)
        _snapshotMenuController = StateObject(wrappedValue: snapshotMenuController)
        _launchAtLoginController = StateObject(wrappedValue: LaunchAtLoginController())
        _browserAutomationController = StateObject(wrappedValue: browserAutomationController)
        _entitlementController = StateObject(wrappedValue: entitlementController)
        _settingsNavigationController = StateObject(wrappedValue: settingsNavigationController)
        _updateController = StateObject(wrappedValue: updateController)
        _raycastRecommendationController = StateObject(wrappedValue: raycastRecommendationController)

        appDelegate.externalCommandHandler = { [weak externalCommandCoordinator] url in
            externalCommandCoordinator?.handle(url)
        }

        permissionCoordinator.refreshTrust(trigger: .launch)
    }

    var body: some Scene {
        Window("LayoutLock", id: DashboardWindowSupport.sceneID) {
            DashboardView(
                bootstrapErrorMessage: bootstrapErrorMessage,
                permissionCoordinator: permissionCoordinator,
                permissionRouter: permissionRouter,
                snapshotMenuController: snapshotMenuController,
                entitlementController: entitlementController,
                settingsNavigationController: settingsNavigationController,
                updateController: updateController,
                raycastRecommendationController: raycastRecommendationController,
                windowPresentationCoordinator: dashboardPresentationCoordinator
            )
            .background(
                OnboardingPresentationBridge(
                    onboardingController: onboardingController,
                    launchMode: launchMode,
                    presentationState: launchPresentationState
                )
            )
        }
        .defaultSize(DashboardWindowSupport.defaultSize)
        .defaultPosition(.center)
        .commands {
            DashboardCommands(updateController: updateController)
        }

        MenuBarExtra("LayoutLock", systemImage: "rectangle.3.group") {
            MenuBarContentView(
                bootstrapErrorMessage: bootstrapErrorMessage,
                permissionCoordinator: permissionCoordinator,
                permissionRouter: permissionRouter,
                onboardingController: onboardingController,
                snapshotMenuController: snapshotMenuController,
                entitlementController: entitlementController,
                settingsNavigationController: settingsNavigationController,
                updateController: updateController
            )
        }
        .menuBarExtraStyle(.menu)

        Window(OnboardingWindowSupport.welcomeTitle, id: OnboardingWindowSupport.sceneID) {
            OnboardingContainerView(
                controller: onboardingController,
                permissionCoordinator: permissionCoordinator,
                settingsNavigationController: settingsNavigationController,
                raycastRecommendationController: raycastRecommendationController
            )
        }
        .defaultSize(width: 560, height: 500)

        Settings {
            SettingsView(
                launchAtLoginController: launchAtLoginController,
                permissionCoordinator: permissionCoordinator,
                browserAutomationController: browserAutomationController,
                diagnosticLogController: diagnosticLogController,
                entitlementController: entitlementController,
                settingsNavigationController: settingsNavigationController,
                updateController: updateController,
                raycastRecommendationController: raycastRecommendationController
            )
        }
    }
}

private struct OnboardingPresentationBridge: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var onboardingController: OnboardingController
    let launchMode: AppLaunchMode
    let presentationState: AppLaunchPresentationState

    @State private var didCheckFirstLaunch = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    presentFirstLaunchIfNeeded()
                }
            }
    }

    private func presentFirstLaunchIfNeeded() {
        guard !didCheckFirstLaunch else {
            return
        }

        didCheckFirstLaunch = true
        guard AutomaticOnboardingPresentationPolicy.startIfAllowed(
            for: launchMode,
            presentationState: presentationState,
            start: onboardingController.startFirstLaunchIfNeeded
        ) else {
            return
        }

        openOnboardingWindow()
    }

    private func openOnboardingWindow() {
        openWindow(id: OnboardingWindowSupport.sceneID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DashboardCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.dashboardCommandContext) private var dashboardCommandContext
    @ObservedObject var updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updateController.actionTitle) {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Dashboard") {
                DashboardWindowSupport.openOrFocusDashboard(using: openWindow)
            }
            .keyboardShortcut("n")
        }

        CommandGroup(after: .textEditing) {
            Button("Search Layouts") {
                dashboardCommandContext?.focusLayoutSearch()
            }
            .disabled(dashboardCommandContext?.canSearchLayouts != true)
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Layout") {
            Button("New Layout") {
                dashboardCommandContext?.createLayout()
            }
            .disabled(dashboardCommandContext?.canCreateLayout != true)

            Divider()

            Button("Restore") {
                dashboardCommandContext?.restoreLayout()
            }
            .disabled(dashboardCommandContext?.canRestoreLayout != true)

            Button("Update") {
                dashboardCommandContext?.updateLayout()
            }
            .disabled(dashboardCommandContext?.canUpdateLayout != true)

            Button("Rename") {
                dashboardCommandContext?.renameLayout()
            }
            .disabled(dashboardCommandContext?.canRenameLayout != true)

            Button(dashboardCommandContext?.hotkeyCommandTitle ?? "Set Hotkey") {
                dashboardCommandContext?.assignHotkey()
            }
            .disabled(dashboardCommandContext?.canAssignHotkey != true)

            Button("Clear Hotkey") {
                dashboardCommandContext?.clearHotkey()
            }
            .disabled(dashboardCommandContext?.canClearHotkey != true)

            Divider()

            Button("Delete", role: .destructive) {
                dashboardCommandContext?.deleteLayout()
            }
            .disabled(dashboardCommandContext?.canDeleteLayout != true)
        }
    }
}

final class LayoutLockAppDelegate: NSObject, NSApplicationDelegate {
    var externalCommandHandler: (@MainActor (URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppearancePreference.resolved().nsAppearance
        NSApp.setActivationPolicy(LayoutLockSettings.resolvedDockActivationPolicy())
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        DashboardReopenPolicy.shouldAllowNormalReopen(
            focusedExistingWindow: DashboardWindowSupport.focusExistingWindow()
        )
    }

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            externalCommandHandler?(url)
        }
    }
}
