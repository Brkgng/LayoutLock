import XCTest
@testable import LayoutLock

@MainActor
final class ExternalCommandIntegrationTests: XCTestCase {
    func testParsesRestoreAndCaptureCommands() throws {
        let id = UUID()

        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://restore?id=\(id.uuidString)")),
                expectedScheme: "layoutlock"
            ),
            .restore(id)
        )
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture")),
                expectedScheme: "layoutlock"
            ),
            .capture(name: nil)
        )
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture?name=Deep%20Work%20%26%20Notes")),
                expectedScheme: "layoutlock"
            ),
            .capture(name: "Deep Work & Notes")
        )
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture?name=C%2B%2B%20Focus")),
                expectedScheme: "layoutlock"
            ),
            .capture(name: "C++ Focus")
        )
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture?name=%C4%B0stanbul%20%C3%87al%C4%B1%C5%9Fma")),
                expectedScheme: "layoutlock"
            ),
            .capture(name: "İstanbul Çalışma")
        )
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture?name=%24%28touch%20%2Ftmp%2Fnope%29")),
                expectedScheme: "layoutlock"
            ),
            .capture(name: "$(touch /tmp/nope)")
        )
    }

    func testConfiguredDevelopmentSchemeIsSeparateFromProduction() throws {
        XCTAssertEqual(LayoutLockExternalCommandParser.configuredScheme, "layoutlock-dev")
        XCTAssertEqual(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock-dev://capture"))
            ),
            .capture(name: nil)
        )
        XCTAssertNil(
            LayoutLockExternalCommandParser.parse(
                try XCTUnwrap(URL(string: "layoutlock://capture"))
            )
        )
    }

    func testRejectsMalformedOrUnknownCommands() throws {
        let id = UUID().uuidString
        let rejectedURLs = [
            "other://capture",
            "layoutlock://restore",
            "layoutlock://restore?id=invalid",
            "layoutlock://restore?id=\(id)&id=\(id)",
            "layoutlock://restore?id=\(id)&extra=value",
            "layoutlock://capture?name=",
            "layoutlock://capture?name=%20%20",
            "layoutlock://capture?name=One&name=Two",
            "layoutlock://capture?extra=value",
            "layoutlock://unknown",
            "layoutlock://capture/path",
            "layoutlock://capture#fragment"
        ]

        for value in rejectedURLs {
            XCTAssertNil(
                LayoutLockExternalCommandParser.parse(
                    try XCTUnwrap(URL(string: value)),
                    expectedScheme: "layoutlock"
                ),
                value
            )
        }
    }

    func testInvalidCommandDoesNotSuppressInitialPresentation() throws {
        var externalUseCount = 0
        let presentationState = AppLaunchPresentationState()
        let coordinator = makeCoordinator(
            isTrusted: true,
            presentationState: presentationState,
            externalIntegrationWasUsed: { externalUseCount += 1 }
        )

        coordinator.handle(try XCTUnwrap(URL(string: "layoutlock-dev://unknown")))

        XCTAssertFalse(presentationState.suppressesInitialPresentation)
        XCTAssertEqual(externalUseCount, 0)
    }

    func testStaleRestoreIsRejectedAfterValidExternalLaunch() throws {
        var externalUseCount = 0
        let presenter = ExternalCommandNoticeRecorder()
        let presentationState = AppLaunchPresentationState()
        let coordinator = makeCoordinator(
            isTrusted: true,
            presentationState: presentationState,
            presenter: presenter,
            externalIntegrationWasUsed: { externalUseCount += 1 }
        )

        coordinator.handle(
            try XCTUnwrap(URL(string: "layoutlock-dev://restore?id=\(UUID().uuidString)"))
        )

        XCTAssertTrue(presentationState.suppressesInitialPresentation)
        XCTAssertEqual(externalUseCount, 1)
        XCTAssertEqual(
            presenter.messages,
            ["That layout is no longer available. Refresh Raycast and try again."]
        )
    }

    func testRaycastRecommendationIsNotShownOnFirstInstall() {
        let controller = RaycastRecommendationController(
            userDefaults: makeUserDefaults(),
            currentBuild: "1",
            hadPriorInstallation: false,
            isRaycastInstalled: { true }
        )

        XCTAssertFalse(controller.shouldShow)
    }

    func testRaycastRecommendationIsShownOnceToExistingInstallations() {
        let userDefaults = makeUserDefaults()
        let controller = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "1",
            hadPriorInstallation: true,
            isRaycastInstalled: { true }
        )

        XCTAssertTrue(controller.shouldShow)

        controller.dismiss()

        let nextUpdateController = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "2",
            hadPriorInstallation: true,
            isRaycastInstalled: { true }
        )
        XCTAssertFalse(nextUpdateController.shouldShow)
    }

    func testRaycastRecommendationIsScheduledAfterAnUpdate() {
        let userDefaults = makeUserDefaults()
        _ = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "1",
            hadPriorInstallation: false,
            isRaycastInstalled: { true }
        )

        let updatedController = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "2",
            hadPriorInstallation: false,
            isRaycastInstalled: { true }
        )

        XCTAssertTrue(updatedController.shouldShow)
    }

    func testRaycastRecommendationWaitsUntilRaycastIsInstalled() {
        var isInstalled = false
        let controller = RaycastRecommendationController(
            userDefaults: makeUserDefaults(),
            currentBuild: "1",
            hadPriorInstallation: true,
            isRaycastInstalled: { isInstalled }
        )

        XCTAssertFalse(controller.shouldShow)

        isInstalled = true
        controller.refreshAvailability()

        XCTAssertTrue(controller.shouldShow)
    }

    func testExternalIntegrationUseClearsRaycastRecommendation() {
        let userDefaults = makeUserDefaults()
        let controller = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "1",
            hadPriorInstallation: true,
            isRaycastInstalled: { true }
        )

        controller.externalIntegrationWasUsed()

        let nextUpdateController = RaycastRecommendationController(
            userDefaults: userDefaults,
            currentBuild: "2",
            hadPriorInstallation: true,
            isRaycastInstalled: { true }
        )
        XCTAssertFalse(nextUpdateController.shouldShow)
    }

    func testMissingPermissionShowsNoticeAndOpensRecoverySettings() throws {
        var settingsOpenCount = 0
        let presenter = ExternalCommandNoticeRecorder()
        let presentationState = AppLaunchPresentationState()
        let permissionCoordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker { false },
            accessibilitySettingsOpener: { settingsOpenCount += 1 }
        )
        let permissionRouter = PermissionInterventionRouter(
            permissionCoordinator: permissionCoordinator,
            statusNoticePresenter: presenter
        )
        let coordinator = ExternalCommandCoordinator(
            permissionRouter: permissionRouter,
            snapshotMenuController: SnapshotMenuController(),
            presentationState: presentationState,
            statusNoticePresenter: presenter
        )

        coordinator.handle(try XCTUnwrap(URL(string: "layoutlock-dev://capture")))

        XCTAssertTrue(presentationState.suppressesInitialPresentation)
        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(
            presenter.messages,
            ["Accessibility access is required to save layouts. Open LayoutLock to enable access."]
        )
    }

    private func makeCoordinator(
        isTrusted: Bool,
        presentationState: AppLaunchPresentationState,
        presenter: StatusNoticePresenting? = nil,
        externalIntegrationWasUsed: @escaping () -> Void = {}
    ) -> ExternalCommandCoordinator {
        let permissionCoordinator = PermissionCoordinator(
            trustChecker: AccessibilityTrustChecker { isTrusted },
            accessibilitySettingsOpener: {}
        )
        return ExternalCommandCoordinator(
            permissionRouter: PermissionInterventionRouter(
                permissionCoordinator: permissionCoordinator,
                statusNoticePresenter: presenter
            ),
            snapshotMenuController: SnapshotMenuController(),
            presentationState: presentationState,
            statusNoticePresenter: presenter,
            externalIntegrationWasUsed: externalIntegrationWasUsed
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ExternalCommandIntegrationTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}

@MainActor
private final class ExternalCommandNoticeRecorder: StatusNoticePresenting {
    private(set) var messages: [String] = []

    func showStatusNotice(message: String, duration _: TimeInterval) {
        messages.append(message)
    }

    func hideStatusNotice() {}
}
