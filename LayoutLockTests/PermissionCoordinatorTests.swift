import Combine
import XCTest
@testable import LayoutLock

@MainActor
final class PermissionCoordinatorTests: XCTestCase {
    func testRefreshTrustBlocksWithoutOpeningSettingsWhenAccessWasRevoked() {
        var isTrusted = true
        var settingsOpenCount = 0
        let coordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { isTrusted }),
            accessibilitySettingsOpener: {
                settingsOpenCount += 1
            }
        )

        XCTAssertEqual(coordinator.authorizationState, .authorized)

        isTrusted = false

        XCTAssertEqual(coordinator.refreshTrust(trigger: .privilegedAction), .unauthorized)
        XCTAssertEqual(coordinator.authorizationState, .unauthorized)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testRefreshTrustAllowsAuthorizedFlow() {
        var settingsOpenCount = 0
        let coordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { true }),
            accessibilitySettingsOpener: {
                settingsOpenCount += 1
            }
        )

        XCTAssertEqual(coordinator.refreshTrust(trigger: .privilegedAction), .authorized)
        XCTAssertEqual(coordinator.authorizationState, .authorized)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testRefreshTrustDoesNotPublishWhenAuthorizationIsUnchanged() {
        let coordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { false })
        )
        var publishedStates: [AccessibilityAuthorizationState] = []
        let cancellable = coordinator.$authorizationState
            .dropFirst()
            .sink { publishedStates.append($0) }

        withExtendedLifetime(cancellable) {
            XCTAssertEqual(coordinator.refreshTrust(trigger: .manualCheckAgain), .unauthorized)
            XCTAssertTrue(publishedStates.isEmpty)
        }
    }

    func testRefreshTrustAllowsWhenPermissionBecomesGranted() {
        var isTrusted = false
        var settingsOpenCount = 0
        let coordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { isTrusted }),
            accessibilitySettingsOpener: {
                settingsOpenCount += 1
            }
        )

        XCTAssertEqual(coordinator.authorizationState, .unauthorized)

        isTrusted = true

        XCTAssertEqual(coordinator.refreshTrust(trigger: .privilegedAction), .authorized)
        XCTAssertEqual(coordinator.authorizationState, .authorized)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testOpenAccessibilitySettingsIsExplicit() {
        var settingsOpenCount = 0
        let coordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker(trustCheck: { false }),
            accessibilitySettingsOpener: {
                settingsOpenCount += 1
            }
        )

        coordinator.openAccessibilitySettings()

        XCTAssertEqual(settingsOpenCount, 1)
    }
}
