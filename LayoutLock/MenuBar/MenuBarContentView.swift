import AppKit
import SwiftUI

private let visibleLayoutLimit = 7

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    let bootstrapErrorMessage: String?
    @ObservedObject var permissionCoordinator: PermissionCoordinator
    @ObservedObject var permissionRouter: PermissionInterventionRouter
    @ObservedObject var onboardingController: OnboardingController
    @ObservedObject var snapshotMenuController: SnapshotMenuController
    @ObservedObject var entitlementController: EntitlementController
    @ObservedObject var settingsNavigationController: SettingsNavigationController
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        Group {
            if let bootstrapErrorMessage {
                Text("Storage setup failed")
                Text(bootstrapErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if permissionCoordinator.shouldShowLimitedMode {
                Button {
                    permissionCoordinator.openAccessibilitySettings()
                } label: {
                    Label("Accessibility Access Required", systemImage: "exclamationmark.triangle.fill")
                }

                Divider()
            } else if planStatusPresentation.isLimitReached {
                Button {
                    performPlanStatusAction()
                } label: {
                    Label("Upgrade to Pro to Save Layouts", systemImage: "lock")
                }
                .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)
            } else {
                Button("Save Current Layout") {
                    handleSaveSnapshot()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)
            }

            if !planStatusPresentation.isProUnlocked && !planStatusPresentation.isLimitReached {
                PlanStatusView(
                    presentation: planStatusPresentation,
                    style: .menuBar,
                    action: performPlanStatusAction
                )
            }

            if let status = snapshotMenuController.status, status.kind != .info {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(
                        status.kind == .error
                            ? Color.red
                            : status.kind == .warning ? Color.orange : Color.secondary
                    )
            }

            Divider()

            snapshotSection

            Divider()

            Button("Open LayoutLock") {
                openDashboardWindow()
            }

            Button("Settings") {
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button(updateController.actionTitle) {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)

            Divider()

            Button("Quit LayoutLock") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @MainActor
    private func openDashboardWindow() {
        DashboardWindowSupport.openOrFocusDashboard(using: openWindow)
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

    @MainActor
    private func openOnboardingWindow() {
        openWindow(id: OnboardingWindowSupport.sceneID)
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var snapshotSection: some View {
        if snapshotMenuController.snapshotSummaries.isEmpty {
            Text("No layouts saved yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Layouts")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(visibleSnapshotSummaries) { snapshot in
                restoreButton(for: snapshot)
            }

            if snapshotMenuController.snapshotSummaries.count > visibleLayoutLimit {
                Menu("More Layouts") {
                    ForEach(remainingSnapshotSummaries) { snapshot in
                        restoreButton(for: snapshot)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func restoreButton(for snapshot: SnapshotSummary) -> some View {
        let button = Button {
            handleRestoreSnapshot(id: snapshot.id)
        } label: {
            if snapshot.isPinned {
                Label(shortMenuTitle(snapshot.name), systemImage: "pin.fill")
            } else {
                Text(shortMenuTitle(snapshot.name))
            }
        }
        .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)

        if let shortcut = snapshot.hotkey?.shortcutRepresentation {
            button.keyboardShortcut(shortcut.0, modifiers: shortcut.1)
        } else if let hotkeyDisplay = snapshot.hotkey?.displayString {
            button.help("Hotkey: \(hotkeyDisplay)")
        } else {
            button
        }
    }

    @MainActor
    private func handleSaveSnapshot() {
        guard entitlementController.isProUnlocked ||
                snapshotMenuController.snapshotSummaries.count < LayoutLockProConfiguration.freeLayoutLimit else {
            snapshotMenuController.reportProRequired(for: .unlimitedLayouts)
            return
        }

        guard requestMenuBarAuthorization(kind: .saveLayout) else {
            return
        }

        snapshotMenuController.captureCurrentSnapshot()
    }

    @MainActor
    private func handleRestoreSnapshot(id: UUID) {
        guard requestMenuBarAuthorization(kind: .restoreLayout) else {
            return
        }

        snapshotMenuController.restoreSnapshot(id: id)
    }

    @MainActor
    private func requestMenuBarAuthorization(kind: PrivilegedActionKind) -> Bool {
        if permissionRouter.requestAuthorization(kind: kind, source: .menuBar) {
            return true
        }

        onboardingController.startPermissionRequiredFlow()
        openOnboardingWindow()
        return false
    }

    private var visibleSnapshotSummaries: ArraySlice<SnapshotSummary> {
        snapshotMenuController.snapshotSummaries.prefix(visibleLayoutLimit)
    }

    private var remainingSnapshotSummaries: ArraySlice<SnapshotSummary> {
        snapshotMenuController.snapshotSummaries.dropFirst(visibleLayoutLimit)
    }

    private var planStatusPresentation: PlanStatusPresentation {
        PlanStatusPresentation(
            isProUnlocked: entitlementController.isProUnlocked,
            layoutCount: snapshotMenuController.snapshotSummaries.count
        )
    }

    private func shortMenuTitle(_ title: String) -> String {
        let maxTitleLength = 42

        guard title.count > maxTitleLength else {
            return title
        }

        return "\(title.prefix(maxTitleLength - 3))..."
    }
}

#Preview {
        MenuBarContentView(
            bootstrapErrorMessage: nil,
            permissionCoordinator: PermissionCoordinator(
                trustChecker: AccessibilityTrustChecker { true }
            ),
            permissionRouter: PermissionInterventionRouter(
                permissionCoordinator: PermissionCoordinator(
                    trustChecker: AccessibilityTrustChecker { true }
                )
            ),
            onboardingController: OnboardingController(
                permissionCoordinator: PermissionCoordinator(
                    trustChecker: AccessibilityTrustChecker { true }
                )
            ),
            snapshotMenuController: SnapshotMenuController(),
            entitlementController: EntitlementController(),
            settingsNavigationController: SettingsNavigationController(),
            updateController: AppUpdateController(startingUpdater: false)
        )
}
