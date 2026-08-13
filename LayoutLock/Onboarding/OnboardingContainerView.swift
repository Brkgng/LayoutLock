import AppKit
import SwiftUI

struct OnboardingContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var controller: OnboardingController
    @ObservedObject var permissionCoordinator: PermissionCoordinator
    @ObservedObject var settingsNavigationController: SettingsNavigationController
    @ObservedObject var raycastRecommendationController: RaycastRecommendationController

    var body: some View {
        ScrollView {
            Group {
                switch controller.step {
                case .welcome:
                    OnboardingWelcomeStep {
                        controller.getStarted()
                    }
                case .permission:
                    OnboardingPermissionEducationView(
                        showsSuccess: controller.showsPermissionSuccess,
                        hasOpenedSystemSettings: controller.hasOpenedSystemSettings,
                        onOpenSystemSettings: controller.openAccessibilitySettings,
                        onCheckAgain: controller.checkAgain
                    )
                    .frame(maxWidth: 460, alignment: .leading)
                case .authorizedReady:
                    OnboardingAuthorizedReadyStep(
                        onSetUpBrowsers: openBrowserSettings,
                        onInstallRaycast: openRaycastSetup,
                        onOpenDashboard: controller.openDashboardAndComplete,
                        onDone: controller.finishWithoutDashboard
                    )
                case .ready:
                    OnboardingReadyStep(
                        onSetUpBrowsers: openBrowserSettings,
                        onInstallRaycast: openRaycastSetup,
                        onOpenDashboard: controller.openDashboardAndComplete,
                        onDone: controller.finishWithoutDashboard
                    )
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(OnboardingWindowTitleObserver(title: controller.windowTitle))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controller.step)
        .onChange(of: permissionCoordinator.authorizationState) { _, state in
            controller.handleAuthorizationState(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.applicationDidBecomeActive()
        }
        .task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }

            controller.reconcileCurrentAuthorizationState()
        }
        .onChange(of: controller.shouldCloseWindow) { _, shouldClose in
            guard shouldClose else {
                return
            }

            dismiss()
            controller.consumeWindowCloseRequest()
        }
        .onChange(of: controller.shouldOpenDashboard) { _, shouldOpen in
            guard shouldOpen else {
                return
            }

            DashboardWindowSupport.openOrFocusDashboard(using: openWindow)
            controller.consumeOpenDashboardRequest()
        }
        .onDisappear {
            controller.windowWillClose()
        }
    }

    private func openBrowserSettings() {
        settingsNavigationController.selectedTab = .integrations
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func openRaycastSetup() {
        raycastRecommendationController.extensionSetupRequested()
        NSWorkspace.shared.open(LayoutLockSupport.raycastURL)
    }
}

private struct OnboardingWindowTitleObserver: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> OnboardingWindowTitleObserverView {
        OnboardingWindowTitleObserverView(title: title)
    }

    func updateNSView(_ nsView: OnboardingWindowTitleObserverView, context _: Context) {
        nsView.title = title
        nsView.updateWindowTitle()
    }
}

private final class OnboardingWindowTitleObserverView: NSView {
    var title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowTitle()
    }

    func updateWindowTitle() {
        window?.title = title
    }
}

enum OnboardingWindowSupport {
    static let sceneID = "onboarding"
    static let accessibilityRequiredTitle = "LayoutLock - Accessibility Required"
    static let welcomeTitle = "Welcome to LayoutLock"
}
