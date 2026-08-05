import XCTest
@testable import LayoutLock

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testLaunchCheckRunsExactlyOnceWhenEnabled() {
        var launchCheck = AppUpdateLaunchCheck()
        var checkCount = 0

        launchCheck.performIfEnabled(true) {
            checkCount += 1
        }
        launchCheck.performIfEnabled(true) {
            checkCount += 1
        }

        XCTAssertEqual(checkCount, 1)
        XCTAssertTrue(launchCheck.hasChecked)
    }

    func testLaunchCheckDoesNotRunWhenDisabled() {
        var launchCheck = AppUpdateLaunchCheck()
        var checkCount = 0

        launchCheck.performIfEnabled(false) {
            checkCount += 1
        }

        XCTAssertEqual(checkCount, 0)
        XCTAssertFalse(launchCheck.hasChecked)
    }

    func testFindingUpdatePublishesVersionsAndActionTitle() {
        let controller = AppUpdateController(startingUpdater: false)

        XCTAssertEqual(controller.actionTitle, "Check for Updates")

        controller.recordAvailableUpdate(buildVersion: "101", displayVersion: "1.0.1")

        XCTAssertEqual(
            controller.availableUpdate,
            AvailableAppUpdate(buildVersion: "101", displayVersion: "1.0.1")
        )
        XCTAssertEqual(controller.availableUpdate?.actionTitle, "Update Available")
        XCTAssertEqual(controller.actionTitle, "Update Available")
    }

    func testRemindMeLaterRetainsKnownUpdate() {
        let controller = controllerWithKnownUpdate()

        controller.recordUserChoice(.dismiss)

        XCTAssertNotNil(controller.availableUpdate)
    }

    func testSkippingClearsKnownUpdate() {
        let controller = controllerWithKnownUpdate()

        controller.recordUserChoice(.skip)

        XCTAssertNil(controller.availableUpdate)
    }

    func testNoUpdateResultClearsKnownUpdate() {
        let controller = controllerWithKnownUpdate()

        controller.recordNoAvailableUpdate()

        XCTAssertNil(controller.availableUpdate)
        XCTAssertEqual(controller.actionTitle, "Check for Updates")
    }

    func testFailureRetainsKnownUpdate() {
        let controller = controllerWithKnownUpdate()

        controller.recordFailure(NSError(domain: "AppUpdateControllerTests", code: 1))

        XCTAssertNotNil(controller.availableUpdate)
    }

    func testAutomaticCheckPreferenceChangesRemainSynchronized() {
        let controller = AppUpdateController(startingUpdater: false)

        controller.setAutomaticallyChecksForUpdates(true)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
        XCTAssertEqual(
            controller.automaticallyChecksForUpdates,
            controller.updaterAutomaticallyChecksForUpdates
        )

        controller.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertEqual(
            controller.automaticallyChecksForUpdates,
            controller.updaterAutomaticallyChecksForUpdates
        )
    }

    private func controllerWithKnownUpdate() -> AppUpdateController {
        let controller = AppUpdateController(startingUpdater: false)
        controller.recordAvailableUpdate(buildVersion: "101", displayVersion: "1.0.1")
        return controller
    }
}
