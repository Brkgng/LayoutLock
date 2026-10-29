import Combine
import XCTest
@testable import LayoutLock

@MainActor
final class OnboardingControllerTests: XCTestCase {
    func testFreePlanCopyUsesConfiguredLayoutLimit() {
        XCTAssertEqual(
            OnboardingStrings.freePlanBody,
            "Start free with up to \(LayoutLockProConfiguration.freeLayoutLimit) saved layouts."
        )
    }

    func testInitialStepIsWelcomeWhenUnauthorized() {
        let controller = makeController(isTrusted: false)

        XCTAssertEqual(controller.step, .welcome)
        XCTAssertEqual(controller.windowTitle, OnboardingWindowSupport.welcomeTitle)
        XCTAssertTrue(controller.shouldPresentOnFirstLaunch)
    }

    func testInitialStepIsAuthorizedReadyWhenAlreadyAuthorized() {
        let controller = makeController(isTrusted: true)

        XCTAssertEqual(controller.step, .authorizedReady)
        XCTAssertEqual(controller.windowTitle, OnboardingWindowSupport.welcomeTitle)
        XCTAssertTrue(controller.shouldPresentOnFirstLaunch)
    }

    func testGetStartedUsesPermissionStepWhenStillUnauthorized() {
        let controller = makeController(isTrusted: false)

        controller.getStarted()

        XCTAssertEqual(controller.step, .permission)
        XCTAssertFalse(controller.showsPermissionSuccess)
    }

    func testGetStartedUsesAuthorizedReadyWhenPermissionWasGrantedWhileWelcomeIsVisible() {
        var isTrusted = false
        let controller = makeController(isTrusted: { isTrusted })

        isTrusted = true
        controller.checkAgain()

        XCTAssertEqual(controller.step, .welcome)

        controller.getStarted()

        XCTAssertEqual(controller.step, .authorizedReady)
        XCTAssertFalse(controller.showsPermissionSuccess)
    }

    func testStartFirstLaunchSetsWelcomeTitle() {
        let controller = makeController(isTrusted: false)

        XCTAssertTrue(controller.startFirstLaunchIfNeeded())

        XCTAssertEqual(controller.windowTitle, OnboardingWindowSupport.welcomeTitle)
    }

    func testFirstLaunchPresentationIsOnlyStartedOncePerControllerLifetime() {
        let controller = makeController(isTrusted: false)

        XCTAssertTrue(controller.startFirstLaunchIfNeeded())
        controller.getStarted()

        XCTAssertFalse(controller.startFirstLaunchIfNeeded())
        XCTAssertEqual(controller.step, .permission)
    }

    func testPermissionRequiredFlowConsumesAutomaticFirstLaunchPresentation() {
        let controller = makeController(isTrusted: false)

        controller.startPermissionRequiredFlow()

        XCTAssertFalse(controller.startFirstLaunchIfNeeded())
        XCTAssertEqual(controller.step, .permission)
        XCTAssertEqual(controller.windowTitle, OnboardingWindowSupport.accessibilityRequiredTitle)
    }

    func testOpenAccessibilitySettingsShowsWaitingStateAndDelegatesToCoordinator() {
        var settingsOpenCount = 0
        let controller = makeController(
            isTrusted: false,
            accessibilitySettingsOpener: { settingsOpenCount += 1 }
        )

        controller.getStarted()
        controller.openAccessibilitySettings()

        XCTAssertTrue(controller.hasOpenedSystemSettings)
        XCTAssertEqual(settingsOpenCount, 1)
    }

    func testPermissionRequiredFlowClearsOpenedSystemSettingsStateWhenRestarted() {
        let controller = makeController(isTrusted: false)

        controller.startPermissionRequiredFlow()
        controller.openAccessibilitySettings()
        controller.startPermissionRequiredFlow()

        XCTAssertFalse(controller.hasOpenedSystemSettings)
        XCTAssertEqual(controller.step, .permission)
    }

    func testUnauthorizedRefreshClearsOpenedSystemSettingsState() {
        let controller = makeController(isTrusted: false)

        controller.getStarted()
        controller.openAccessibilitySettings()
        controller.checkAgain()

        XCTAssertFalse(controller.hasOpenedSystemSettings)
        XCTAssertEqual(controller.step, .permission)
    }

    func testAppActivationClearsOpenedSystemSettingsStateWhilePermissionIsStillUnauthorized() {
        let controller = makeController(isTrusted: false)

        controller.getStarted()
        controller.openAccessibilitySettings()
        controller.applicationDidBecomeActive()

        XCTAssertFalse(controller.hasOpenedSystemSettings)
        XCTAssertEqual(controller.step, .permission)
    }

    func testAppActivationWithoutOpenedSettingsDoesNotPublishControllerChanges() {
        let controller = makeController(isTrusted: false)
        controller.getStarted()
        var publishedChangeCount = 0
        let cancellable = controller.objectWillChange.sink { _ in
            publishedChangeCount += 1
        }

        withExtendedLifetime(cancellable) {
            controller.applicationDidBecomeActive()
            XCTAssertEqual(publishedChangeCount, 0)
        }
    }

    func testReadyReturnsToPermissionWhenAuthorizationIsRevoked() async {
        var isTrusted = false
        var persistedStatus: OnboardingStatus?
        let controller = makeController(
            isTrusted: { isTrusted },
            writeStatus: { persistedStatus = $0 }
        )

        controller.getStarted()
        isTrusted = true
        controller.checkAgain()
        try? await Task.sleep(for: .milliseconds(850))

        XCTAssertEqual(controller.step, .ready)

        isTrusted = false
        controller.checkAgain()

        XCTAssertEqual(controller.step, .permission)
        XCTAssertFalse(controller.showsPermissionSuccess)
        XCTAssertFalse(controller.hasOpenedSystemSettings)
        XCTAssertFalse(controller.shouldCloseWindow)
        XCTAssertFalse(controller.shouldOpenDashboard)
        XCTAssertNil(persistedStatus)
    }

    func testCompletedOnboardingDoesNotPresentOnFirstLaunch() {
        let controller = makeController(isTrusted: true, storedStatus: .completedAuthorized)

        XCTAssertFalse(controller.shouldPresentOnFirstLaunch)
        XCTAssertFalse(controller.startFirstLaunchIfNeeded())
    }

    func testRevokedAuthorizedReadyReturnsToPermissionWithoutDowngradingCompletedStatus() {
        var isTrusted = true
        var persistedStatus: OnboardingStatus? = .completedAuthorized
        let controller = makeController(
            isTrusted: { isTrusted },
            storedStatusReader: { persistedStatus },
            writeStatus: { persistedStatus = $0 }
        )

        XCTAssertEqual(controller.step, .authorizedReady)

        isTrusted = false
        controller.checkAgain()

        XCTAssertEqual(controller.step, .permission)

        controller.windowWillClose()

        XCTAssertEqual(persistedStatus, .completedAuthorized)
    }

    func testClosingBeforeReadyPersistsDeferred() {
        var persistedStatus: OnboardingStatus?
        let controller = makeController(
            isTrusted: false,
            writeStatus: { persistedStatus = $0 }
        )

        controller.getStarted()
        controller.windowWillClose()

        XCTAssertEqual(persistedStatus, .deferred)
    }

    func testDeferredUnauthorizedOnboardingPresentsPermissionOnRelaunch() {
        let controller = makeController(isTrusted: false, storedStatus: .deferred)

        XCTAssertTrue(controller.shouldPresentOnFirstLaunch)
        XCTAssertTrue(controller.startFirstLaunchIfNeeded())
        XCTAssertEqual(controller.step, .permission)
        XCTAssertEqual(controller.windowTitle, OnboardingWindowSupport.accessibilityRequiredTitle)
    }

    func testDeferredAuthorizedOnboardingDoesNotAutoPresentOnRelaunch() {
        let controller = makeController(isTrusted: true, storedStatus: .deferred)

        XCTAssertFalse(controller.shouldPresentOnFirstLaunch)
        XCTAssertFalse(controller.startFirstLaunchIfNeeded())
    }

    func testPermissionAutoAdvanceKeepsSuccessReadableBeforeReady() async {
        var isTrusted = false
        let controller = makeController(isTrusted: { isTrusted })

        controller.getStarted()
        isTrusted = true
        controller.checkAgain()

        XCTAssertTrue(controller.showsPermissionSuccess)
        XCTAssertEqual(controller.step, .permission)

        try? await Task.sleep(for: .milliseconds(850))

        XCTAssertFalse(controller.showsPermissionSuccess)
        XCTAssertEqual(controller.step, .ready)
    }

    func testReconcileUnchangedUnauthorizedStateDoesNotPublishControllerChanges() {
        let controller = makeController(isTrusted: false)
        controller.getStarted()
        var publishedChangeCount = 0
        let cancellable = controller.objectWillChange.sink { _ in
            publishedChangeCount += 1
        }

        withExtendedLifetime(cancellable) {
            controller.reconcileCurrentAuthorizationState()
            XCTAssertEqual(publishedChangeCount, 0)
        }
    }

    func testReconcileAuthorizedStateAfterPermissionPresentationBeginsSuccessAdvance() {
        var isTrusted = false
        let permissionCoordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { isTrusted })
        )
        let controller = OnboardingController(
            store: OnboardingStore(readStatus: { nil }, writeStatus: { _ in }),
            permissionCoordinator: permissionCoordinator
        )

        controller.startPermissionRequiredFlow()
        isTrusted = true
        permissionCoordinator.refreshTrust(trigger: .appDidBecomeActive)

        controller.reconcileCurrentAuthorizationState()

        XCTAssertEqual(controller.step, .permission)
        XCTAssertTrue(controller.showsPermissionSuccess)
    }

    func testPermissionRequiredFlowCancelsPendingSuccessAdvance() async {
        var isTrusted = false
        let controller = makeController(isTrusted: { isTrusted })

        controller.getStarted()
        isTrusted = true
        controller.checkAgain()

        XCTAssertTrue(controller.showsPermissionSuccess)

        controller.startPermissionRequiredFlow()

        XCTAssertFalse(controller.showsPermissionSuccess)
        XCTAssertEqual(controller.step, .permission)

        try? await Task.sleep(for: .milliseconds(850))

        XCTAssertFalse(controller.showsPermissionSuccess)
        XCTAssertEqual(controller.step, .permission)
    }

    private func makeController(
        isTrusted: Bool,
        storedStatus: OnboardingStatus? = nil,
        writeStatus: @escaping (OnboardingStatus) -> Void = { _ in },
        accessibilitySettingsOpener: @escaping @MainActor () -> Void = {}
    ) -> OnboardingController {
        makeController(
            isTrusted: { isTrusted },
            storedStatusReader: { storedStatus },
            writeStatus: writeStatus,
            accessibilitySettingsOpener: accessibilitySettingsOpener
        )
    }

    private func makeController(
        isTrusted: @escaping () -> Bool,
        storedStatusReader: @escaping () -> OnboardingStatus? = { nil },
        writeStatus: @escaping (OnboardingStatus) -> Void = { _ in },
        accessibilitySettingsOpener: @escaping @MainActor () -> Void = {}
    ) -> OnboardingController {
        OnboardingController(
            store: OnboardingStore(
                readStatus: storedStatusReader,
                writeStatus: writeStatus
            ),
            permissionCoordinator: PermissionCoordinator(
                trustChecker: AccessibilityTrustChecker(trustCheck: isTrusted),
                accessibilitySettingsOpener: accessibilitySettingsOpener
            )
        )
    }
}
