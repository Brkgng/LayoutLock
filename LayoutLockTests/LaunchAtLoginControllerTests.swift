import XCTest
@testable import LayoutLock

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testNotRegisteredStatusReportsDisabledByDefault() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertTrue(controller.state.canToggle)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testNotFoundStatusReportsDisabledWithoutWarning() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertNil(controller.state.message)
        XCTAssertTrue(controller.state.canToggle)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testEnablingRegistersOnlyAfterExplicitToggle() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(service.registerCallCount, 0)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state, .enabled)
    }

    func testEnablingFromNotFoundRegistersAndBecomesEnabled() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.state, .enabled)
    }

    func testDisablingUnregistersAfterExplicitToggle() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testRequiresApprovalReportsUserActionState() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.state.requiresApproval)
        XCTAssertFalse(controller.state.canToggle)
        XCTAssertEqual(
            controller.state.message,
            "Allow LayoutLock in Login Items to finish enabling launch at login."
        )
    }

    func testRegisterErrorPreservesDisabledStateAndReportsError() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = makeError("Registration failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Registration failed.")
        XCTAssertTrue(controller.state.isError)
    }

    func testRepeatedRegisterErrorPreservesErrorWhenStatusDoesNotChange() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = makeError("First registration failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        service.registerError = makeError("Second registration failed.")
        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Second registration failed.")
        XCTAssertTrue(controller.state.isError)
    }

    func testRegisterErrorReportsApprovalStateWhenStatusChanges() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = makeError("Registration failed.")
        service.statusAfterRegisterError = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.state.requiresApproval)
        XCTAssertFalse(controller.state.isError)
        XCTAssertEqual(
            controller.state.message,
            "Allow LayoutLock in Login Items to finish enabling launch at login."
        )
    }

    func testRegisterErrorPreservesApprovalStateWhenStatusDoesNotChange() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        service.registerError = makeError("Registration failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.state.requiresApproval)
        XCTAssertFalse(controller.state.isError)
        XCTAssertEqual(
            controller.state.message,
            "Allow LayoutLock in Login Items to finish enabling launch at login."
        )
    }

    func testRegisterErrorFromNotFoundShowsActualErrorAndPermitsRetry() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        service.registerError = makeError("Registration failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.state.requiresApproval)
        XCTAssertTrue(controller.state.isError)
        XCTAssertTrue(controller.state.canToggle)
        XCTAssertEqual(controller.state.message, "Registration failed.")

        service.registerError = nil
        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertEqual(controller.state, .enabled)
    }

    func testRegisterErrorReportsCurrentEnabledStateWhenDisplayedStateIsStale() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)
        service.status = .enabled
        service.registerError = makeError("Already registered.")

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Already registered.")
        XCTAssertTrue(controller.state.isError)
    }

    func testUnregisterErrorPreservesEnabledStateAndReportsError() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = makeError("Unregister failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Unregister failed.")
        XCTAssertTrue(controller.state.isError)
    }

    func testRepeatedUnregisterErrorPreservesErrorWhenStatusDoesNotChange() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = makeError("First unregister failed.")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)
        service.unregisterError = makeError("Second unregister failed.")
        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Second unregister failed.")
        XCTAssertTrue(controller.state.isError)
    }

    func testUnregisterErrorReportsDisabledStateWhenStatusChanges() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = makeError("Unregister failed.")
        service.statusAfterUnregisterError = .notRegistered
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Unregister failed.")
        XCTAssertTrue(controller.state.isError)
    }

    func testUnregisterErrorReportsCurrentDisabledStateWhenDisplayedStateIsStale() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)
        service.status = .notRegistered
        service.unregisterError = makeError("Not registered.")

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Not registered.")
        XCTAssertTrue(controller.state.isError)
    }

    func testOpenLoginItemsSettingsDelegatesToService() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.openLoginItemsSettings()

        XCTAssertEqual(service.openLoginItemsSettingsCallCount, 1)
    }

    func testEnabledLegacyServiceMigratesToHelper() throws {
        let helper = FakeLaunchAtLoginRegistration(status: .notRegistered)
        let legacy = FakeLaunchAtLoginRegistration(status: .enabled)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)

        try service.prepare()

        XCTAssertEqual(helper.registerCallCount, 1)
        XCTAssertEqual(helper.status, .enabled)
        XCTAssertEqual(legacy.unregisterCallCount, 1)
        XCTAssertEqual(legacy.status, .notRegistered)
    }

    func testLegacyServiceRemainsRegisteredWhileHelperAwaitsApproval() throws {
        let helper = FakeLaunchAtLoginRegistration(status: .notRegistered)
        helper.statusAfterRegister = .requiresApproval
        let legacy = FakeLaunchAtLoginRegistration(status: .enabled)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)

        try service.prepare()

        XCTAssertEqual(helper.status, .requiresApproval)
        XCTAssertEqual(legacy.status, .enabled)
        XCTAssertEqual(legacy.unregisterCallCount, 0)
    }

    func testEnabledHelperRemovesLegacyRegistration() throws {
        let helper = FakeLaunchAtLoginRegistration(status: .enabled)
        let legacy = FakeLaunchAtLoginRegistration(status: .enabled)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)

        try service.prepare()

        XCTAssertEqual(helper.registerCallCount, 0)
        XCTAssertEqual(legacy.unregisterCallCount, 1)
    }

    func testPartialEnableFailureReportsErrorAndRefreshRetriesCleanup() {
        let helper = FakeLaunchAtLoginRegistration(status: .notRegistered)
        let legacy = FakeLaunchAtLoginRegistration(status: .notRegistered)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)
        let controller = LaunchAtLoginController(service: service)
        legacy.status = .enabled
        legacy.unregisterError = makeError("Legacy cleanup failed.")

        controller.setEnabled(true)

        XCTAssertEqual(helper.status, .enabled)
        XCTAssertEqual(legacy.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Legacy cleanup failed.")
        XCTAssertTrue(controller.state.isError)

        legacy.unregisterError = nil
        controller.refreshStatus()

        XCTAssertEqual(legacy.unregisterCallCount, 2)
        XCTAssertEqual(legacy.status, .notRegistered)
        XCTAssertEqual(controller.state, .enabled)
    }

    func testPartialDisableFailureReportsEffectiveStateAndRefreshRetriesDisable() {
        let helper = FakeLaunchAtLoginRegistration(status: .enabled)
        let legacy = FakeLaunchAtLoginRegistration(status: .notRegistered)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)
        let controller = LaunchAtLoginController(service: service)
        legacy.status = .enabled
        legacy.unregisterError = makeError("Legacy disable failed.")

        controller.setEnabled(false)

        XCTAssertEqual(helper.status, .notRegistered)
        XCTAssertEqual(legacy.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.message, "Legacy disable failed.")
        XCTAssertTrue(controller.state.isError)

        legacy.unregisterError = nil
        controller.refreshStatus()

        XCTAssertEqual(helper.registerCallCount, 0)
        XCTAssertEqual(legacy.unregisterCallCount, 2)
        XCTAssertEqual(legacy.status, .notRegistered)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testMigrationFailureIsVisibleAndRefreshRetries() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.prepareError = makeError("Migration failed.")
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(controller.state.message, "Migration failed.")
        XCTAssertTrue(controller.state.isError)
        XCTAssertEqual(service.prepareCallCount, 1)

        service.prepareError = nil
        controller.refreshStatus()

        XCTAssertEqual(service.prepareCallCount, 2)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testDisablingRemovesHelperAndLegacyRegistrations() throws {
        let helper = FakeLaunchAtLoginRegistration(status: .enabled)
        let legacy = FakeLaunchAtLoginRegistration(status: .enabled)
        let service = LoginHelperLaunchAtLoginService(helper: helper, legacyMainApp: legacy)

        try service.unregister()

        XCTAssertEqual(helper.unregisterCallCount, 1)
        XCTAssertEqual(legacy.unregisterCallCount, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    private func makeError(_ message: String) -> Error {
        NSError(
            domain: "LayoutLockTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var isEffectivelyEnabled: Bool {
        status == .enabled
    }
    var prepareCallCount = 0
    var registerCallCount = 0
    var unregisterCallCount = 0
    var openLoginItemsSettingsCallCount = 0
    var registerError: Error?
    var unregisterError: Error?
    var prepareError: Error?
    var statusAfterRegisterError: LaunchAtLoginServiceStatus?
    var statusAfterUnregisterError: LaunchAtLoginServiceStatus?

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func prepare() throws {
        prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
    }

    func register() throws {
        registerCallCount += 1

        if let registerError {
            if let statusAfterRegisterError {
                status = statusAfterRegisterError
            }

            throw registerError
        }

        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1

        if let unregisterError {
            if let statusAfterUnregisterError {
                status = statusAfterUnregisterError
            }

            throw unregisterError
        }

        status = .notRegistered
    }

    func openLoginItemsSettings() {
        openLoginItemsSettingsCallCount += 1
    }
}

private final class FakeLaunchAtLoginRegistration: LaunchAtLoginRegistration {
    var status: LaunchAtLoginServiceStatus
    var statusAfterRegister: LaunchAtLoginServiceStatus = .enabled
    var registerCallCount = 0
    var unregisterCallCount = 0
    var registerError: Error?
    var unregisterError: Error?

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}
