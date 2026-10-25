import XCTest
@testable import LayoutLock

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testLaunchCheckRunsExactlyOnce() {
        var launchCheck = AppUpdateLaunchCheck()
        var checkCount = 0

        launchCheck.perform {
            checkCount += 1
        }
        launchCheck.perform {
            checkCount += 1
        }

        XCTAssertEqual(checkCount, 1)
        XCTAssertTrue(launchCheck.hasChecked)
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

    func testAutomaticChecksReenablePersistedDisabledPreference() {
        let defaults = UserDefaults.standard
        let preferenceKey = "SUEnableAutomaticChecks"
        let originalPreference = defaults.object(forKey: preferenceKey)
        defer {
            if let originalPreference {
                defaults.set(originalPreference, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
        defaults.set(false, forKey: preferenceKey)
        let controller = AppUpdateController(startingUpdater: false)
        XCTAssertFalse(controller.updaterAutomaticallyChecksForUpdates)
        XCTAssertFalse(defaults.bool(forKey: preferenceKey))

        controller.enableAutomaticUpdateChecks()

        XCTAssertTrue(controller.updaterAutomaticallyChecksForUpdates)
        XCTAssertTrue(defaults.bool(forKey: preferenceKey))
    }

    private func controllerWithKnownUpdate() -> AppUpdateController {
        let controller = AppUpdateController(startingUpdater: false)
        controller.recordAvailableUpdate(buildVersion: "101", displayVersion: "1.0.1")
        return controller
    }
}
