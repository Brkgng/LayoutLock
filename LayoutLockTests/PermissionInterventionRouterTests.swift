import Combine
import XCTest
@testable import LayoutLock

@MainActor
final class PermissionInterventionRouterTests: XCTestCase {
    func testAuthorizedRequestReturnsTrueAndClearsStaleInterventions() {
        let presenter = RecordingStatusNoticePresenter()
        let router = makeRouter(isTrusted: false, presenter: presenter)

        XCTAssertFalse(router.requestAuthorization(kind: .restoreLayout, source: .hotkey))
        XCTAssertNotNil(router.lastPassivePermissionNotice)

        let authorizedRouter = makeRouter(isTrusted: true, presenter: presenter)
        authorizedRouter.updateDashboardWindowVisibility(.visibleOnActiveSpace)
        _ = authorizedRouter.requestAuthorization(kind: .saveLayout, source: .dashboard)

        XCTAssertTrue(authorizedRouter.requestAuthorization(kind: .saveLayout, source: .dashboard))
        XCTAssertFalse(authorizedRouter.showsDashboardPermissionEducation)
        XCTAssertNil(authorizedRouter.lastPassivePermissionNotice)
    }

    func testUnauthorizedDashboardRequestShowsInlineEducation() {
        let router = makeRouter(isTrusted: false)

        XCTAssertFalse(router.requestAuthorization(kind: .saveLayout, source: .dashboard))

        XCTAssertTrue(router.showsDashboardPermissionEducation)
        XCTAssertNil(router.onboardingPresentationRequestID)
        XCTAssertNil(router.lastPassivePermissionNotice)
    }

    func testUnauthorizedMenuBarRequestAsksForOnboardingPermissionStep() {
        let router = makeRouter(isTrusted: false)

        XCTAssertFalse(router.requestAuthorization(kind: .restoreLayout, source: .menuBar))

        XCTAssertFalse(router.showsDashboardPermissionEducation)
        XCTAssertNotNil(router.onboardingPresentationRequestID)
        XCTAssertNil(router.lastPassivePermissionNotice)
    }

    func testUnauthorizedHotkeyRequestShowsPassiveNoticeWithoutOnboarding() {
        let presenter = RecordingStatusNoticePresenter()
        let router = makeRouter(isTrusted: false, presenter: presenter)

        XCTAssertFalse(router.requestAuthorization(kind: .restoreLayout, source: .hotkey))

        XCTAssertNil(router.onboardingPresentationRequestID)
        XCTAssertEqual(router.lastPassivePermissionNotice?.duration, 6)
        XCTAssertEqual(
            router.lastPassivePermissionNotice?.message,
            "Accessibility access is required to restore layouts. Open LayoutLock to enable access."
        )
        XCTAssertEqual(presenter.messages.last, router.lastPassivePermissionNotice?.message)
        XCTAssertEqual(presenter.durations.last, 6)
    }

    func testHotkeyPassiveNoticeIsSuppressedWhenDashboardEducationIsVisibleOnActiveSpace() {
        let presenter = RecordingStatusNoticePresenter()
        let router = makeRouter(isTrusted: false, presenter: presenter)

        _ = router.requestAuthorization(kind: .saveLayout, source: .dashboard)
        router.updateDashboardWindowVisibility(.visibleOnActiveSpace)

        XCTAssertFalse(router.requestAuthorization(kind: .restoreLayout, source: .hotkey))

        XCTAssertNil(router.lastPassivePermissionNotice)
        XCTAssertTrue(presenter.messages.isEmpty)
    }

    func testHotkeyPassiveNoticeStillShowsWhenDashboardEducationIsNotVisible() {
        let presenter = RecordingStatusNoticePresenter()
        let router = makeRouter(isTrusted: false, presenter: presenter)

        _ = router.requestAuthorization(kind: .saveLayout, source: .dashboard)
        router.updateDashboardWindowVisibility(.notVisible)

        XCTAssertFalse(router.requestAuthorization(kind: .restoreLayout, source: .hotkey))

        XCTAssertNotNil(router.lastPassivePermissionNotice)
        XCTAssertEqual(presenter.messages.count, 1)
    }

    func testDashboardVisibilityMappingRequiresVisibleNotMinimizedAndActiveSpace() {
        XCTAssertEqual(
            DashboardWindowVisibility.from(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: true
            ),
            .visibleOnActiveSpace
        )
        XCTAssertEqual(
            DashboardWindowVisibility.from(
                isVisible: false,
                isMiniaturized: false,
                isOnActiveSpace: true
            ),
            .notVisible
        )
        XCTAssertEqual(
            DashboardWindowVisibility.from(
                isVisible: true,
                isMiniaturized: true,
                isOnActiveSpace: true
            ),
            .notVisible
        )
        XCTAssertEqual(
            DashboardWindowVisibility.from(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: false
            ),
            .notVisible
        )
    }

    func testUnchangedDashboardVisibilityDoesNotPublish() {
        let router = makeRouter(isTrusted: false)
        var publishedVisibilities: [DashboardWindowVisibility] = []
        let cancellable = router.$dashboardWindowVisibility
            .dropFirst()
            .sink { publishedVisibilities.append($0) }

        withExtendedLifetime(cancellable) {
            router.updateDashboardWindowVisibility(.notVisible)
            XCTAssertTrue(publishedVisibilities.isEmpty)

            router.updateDashboardWindowVisibility(.visibleOnActiveSpace)
            XCTAssertEqual(publishedVisibilities, [.visibleOnActiveSpace])
        }
    }

    private func makeRouter(
        isTrusted: Bool,
        presenter: StatusNoticePresenting? = nil
    ) -> PermissionInterventionRouter {
        PermissionInterventionRouter(
            permissionCoordinator: PermissionCoordinator(
                trustChecker: AccessibilityTrustChecker { isTrusted }
            ),
            statusNoticePresenter: presenter
        )
    }
}

@MainActor
private final class RecordingStatusNoticePresenter: StatusNoticePresenting {
    private(set) var messages: [String] = []
    private(set) var durations: [TimeInterval] = []
    private(set) var hideCount = 0

    func showStatusNotice(message: String, duration: TimeInterval) {
        messages.append(message)
        durations.append(duration)
    }

    func hideStatusNotice() {
        hideCount += 1
    }
}
