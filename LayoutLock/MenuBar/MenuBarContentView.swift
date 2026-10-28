import AppKit
import SwiftUI

private let visibleLayoutLimit = 7

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    let bootstrapErrorMessage: String?
    let diagnosticLogController: DiagnosticLogController?
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
            }

            if let progress = snapshotMenuController.restoreProgressMessage {
                Text(progress)
                    .font(.caption)
            } else if let status = snapshotMenuController.status, status.kind != .info {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(
                        status.kind == .error
                            ? Color.red
                            : status.kind == .warning ? Color.orange : Color.secondary
                    )
            }

            snapshotSection

            if !permissionCoordinator.shouldShowLimitedMode || !snapshotMenuController.snapshotSummaries.isEmpty {
                Divider()
            }

            if !permissionCoordinator.shouldShowLimitedMode {
                Button {
                    if planStatusPresentation.isLimitReached {
                        performUpgradeAction()
                    } else {
                        handleSaveSnapshot()
                    }
                } label: {
                    if planStatusPresentation.isLimitReached {
                        Label("Save Layout…", systemImage: "lock")
                    } else {
                        Text("Save Layout…")
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)
            }

            if !snapshotMenuController.snapshotSummaries.isEmpty {
                Menu("Update Layout") {
                    ForEach(snapshotMenuController.snapshotSummaries) { snapshot in
                        Button(shortMenuTitle(snapshot.name)) {
                            handleUpdateSnapshot(snapshot)
                        }
                    }
                }
                .disabled(bootstrapErrorMessage != nil || snapshotMenuController.isOperating)
            }

            Divider()

            Button("Open LayoutLock") {
                openDashboardWindow()
            }

            Button("Settings…") {
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            if !planStatusPresentation.isProUnlocked {
                Button("Upgrade to Pro…") {
                    performUpgradeAction()
                }
            }

            Button("\(updateController.actionTitle)…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)

            Button("Send Feedback…") {
                LayoutLockSupport.openFeedbackEmail(diagnosticLogController: diagnosticLogController)
            }

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
    private func performUpgradeAction() {
        switch PlanStatusActionResolver.upgradeAction(purchaseURL: LayoutLockProConfiguration.purchaseURL) {
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
            Text("Restore Layout")
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
    private func handleUpdateSnapshot(_ snapshot: SnapshotSummary) {
        guard bootstrapErrorMessage == nil, !snapshotMenuController.isOperating else {
            return
        }

        SnapshotNamePrompt.confirmUpdate(currentName: snapshot.name) { confirmed in
            guard confirmed, bootstrapErrorMessage == nil, !snapshotMenuController.isOperating,
                  requestMenuBarAuthorization(kind: .saveLayout) else {
                return
            }

            snapshotMenuController.updateSnapshot(id: snapshot.id)
        }
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
            diagnosticLogController: nil,
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
