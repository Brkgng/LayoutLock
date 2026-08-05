import Foundation

@MainActor
final class OnboardingController: ObservableObject {
    enum Step: Equatable {
        case welcome
        case permission
        case authorizedReady
        case ready
    }

    private static let successPause: Duration = .milliseconds(800)

    @Published private(set) var step: Step
    @Published private(set) var showsPermissionSuccess = false
    @Published private(set) var hasOpenedSystemSettings = false
    @Published private(set) var windowTitle = OnboardingWindowSupport.welcomeTitle
    @Published private(set) var shouldCloseWindow = false
    @Published private(set) var shouldOpenDashboard = false

    private let store: OnboardingStore
    private let permissionCoordinator: PermissionCoordinator
    private var hasHandledAutomaticFirstLaunchPresentation = false
    private var successAdvanceTask: Task<Void, Never>?

    init(
        store: OnboardingStore = OnboardingStore(),
        permissionCoordinator: PermissionCoordinator
    ) {
        self.store = store
        self.permissionCoordinator = permissionCoordinator
        step = permissionCoordinator.authorizationState == .authorized ? .authorizedReady : .welcome
    }

    deinit {
        successAdvanceTask?.cancel()
    }

    var storedStatus: OnboardingStatus? {
        store.readStatus()
    }

    var shouldPresentOnFirstLaunch: Bool {
        switch store.readStatus() {
        case nil:
            return true
        case .deferred:
            return permissionCoordinator.authorizationState == .unauthorized
        case .completedAuthorized:
            return false
        }
    }

    func startFirstLaunchIfNeeded() -> Bool {
        guard !hasHandledAutomaticFirstLaunchPresentation else {
            return false
        }

        hasHandledAutomaticFirstLaunchPresentation = true

        switch store.readStatus() {
        case nil:
            resetPermissionPresentationState()
            windowTitle = OnboardingWindowSupport.welcomeTitle
            step = permissionCoordinator.authorizationState == .authorized ? .authorizedReady : .welcome
        case .deferred where permissionCoordinator.authorizationState == .unauthorized:
            resetPermissionPresentationState()
            windowTitle = OnboardingWindowSupport.accessibilityRequiredTitle
            step = .permission
        case .deferred, .completedAuthorized:
            return false
        }
        resetWindowRequests()
        return true
    }

    func startPermissionRequiredFlow() {
        hasHandledAutomaticFirstLaunchPresentation = true
        resetPermissionPresentationState()
        windowTitle = OnboardingWindowSupport.accessibilityRequiredTitle
        step = .permission
        resetWindowRequests()
    }

    func getStarted() {
        resetPermissionPresentationState()
        step = permissionCoordinator.authorizationState == .authorized ? .authorizedReady : .permission
    }

    func openAccessibilitySettings() {
        hasOpenedSystemSettings = true
        permissionCoordinator.openAccessibilitySettings()
    }

    func applicationDidBecomeActive() {
        guard step == .permission, hasOpenedSystemSettings else {
            return
        }

        hasOpenedSystemSettings = false
    }

    func checkAgain() {
        handleAuthorizationState(permissionCoordinator.refreshTrust(trigger: .manualCheckAgain))
    }

    func reconcileCurrentAuthorizationState() {
        handleAuthorizationState(permissionCoordinator.authorizationState)
    }

    func handleAuthorizationState(_ state: AccessibilityAuthorizationState) {
        guard state == .authorized else {
            cancelSuccessAdvance()
            if hasOpenedSystemSettings {
                hasOpenedSystemSettings = false
            }
            if step == .ready || step == .authorizedReady {
                step = .permission
            }
            return
        }

        switch step {
        case .permission:
            showPermissionSuccessThenAdvance()
        case .authorizedReady, .ready, .welcome:
            break
        }
    }

    func openDashboardAndComplete() {
        store.writeStatus(.completedAuthorized)
        shouldOpenDashboard = true
        shouldCloseWindow = true
    }

    func finishWithoutDashboard() {
        if permissionCoordinator.authorizationState == .authorized {
            store.writeStatus(.completedAuthorized)
        }
        shouldCloseWindow = true
    }

    func windowWillClose() {
        if permissionCoordinator.authorizationState == .authorized,
           step == .ready || step == .authorizedReady {
            store.writeStatus(.completedAuthorized)
        } else if store.readStatus() != .completedAuthorized {
            store.writeStatus(.deferred)
        }

        cancelSuccessAdvance()
    }

    func consumeWindowCloseRequest() {
        shouldCloseWindow = false
    }

    func consumeOpenDashboardRequest() {
        shouldOpenDashboard = false
    }

    private func resetWindowRequests() {
        if shouldCloseWindow {
            shouldCloseWindow = false
        }
        if shouldOpenDashboard {
            shouldOpenDashboard = false
        }
    }

    private func resetPermissionPresentationState() {
        cancelSuccessAdvance()
        if hasOpenedSystemSettings {
            hasOpenedSystemSettings = false
        }
    }

    private func cancelSuccessAdvance() {
        successAdvanceTask?.cancel()
        successAdvanceTask = nil
        if showsPermissionSuccess {
            showsPermissionSuccess = false
        }
    }

    private func showPermissionSuccessThenAdvance() {
        guard !showsPermissionSuccess else {
            return
        }

        showsPermissionSuccess = true
        successAdvanceTask?.cancel()
        successAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.successPause)
            guard !Task.isCancelled else {
                return
            }

            self?.step = .ready
            self?.showsPermissionSuccess = false
            self?.successAdvanceTask = nil
        }
    }
}
