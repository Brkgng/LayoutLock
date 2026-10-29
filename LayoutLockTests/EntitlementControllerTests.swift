import CryptoKit
import Foundation
import XCTest
@testable import LayoutLock

@MainActor
final class EntitlementControllerTests: XCTestCase {
    private static let fixtureSigningKey = SigningPublicKey(
        keyId: "test-fixture-1",
        rawRepresentationHex: "04d775fc5fe6e6c0e1043bffcb3c84e26972fec3754002872dee6a8e4cd1844d08ad1bd21e66bbd9ffd82d7c014f2abfeda5e1c493557188f26e7003b8a777b80c",
        environment: "test"
    )

    override func setUp() {
        super.setUp()
        EntitlementSigningKey.trustedKeys.append(Self.fixtureSigningKey)
    }

    override func tearDown() {
        EntitlementSigningKey.trustedKeys.removeAll { $0.keyId == "test-fixture-1" }
        super.tearDown()
    }

    func testPlanStatusPresentationShowsFreeLayoutsBelowLimit() {
        let presentation = PlanStatusPresentation(isProUnlocked: false, layoutCount: 2)

        XCTAssertEqual(presentation.title, "Free plan")
        XCTAssertEqual(presentation.detail, "2/3 layouts used")
        XCTAssertEqual(presentation.menuTitle, "Free plan · 2/3 layouts")
        XCTAssertEqual(presentation.systemImageName, "sparkles")
        XCTAssertFalse(presentation.isLimitReached)
        XCTAssertFalse(presentation.isProUnlocked)
    }

    func testPlanStatusPresentationShowsFreeZeroLayouts() {
        let presentation = PlanStatusPresentation(isProUnlocked: false, layoutCount: 0)

        XCTAssertEqual(presentation.title, "Free plan")
        XCTAssertEqual(presentation.detail, "0/3 layouts used")
        XCTAssertEqual(presentation.menuTitle, "Free plan · 0/3 layouts")
        XCTAssertFalse(presentation.isLimitReached)
    }

    func testPlanStatusPresentationShowsFreeLimitReachedAtLimit() {
        let presentation = PlanStatusPresentation(isProUnlocked: false, layoutCount: 3)

        XCTAssertEqual(presentation.title, "Layout limit reached")
        XCTAssertEqual(presentation.detail, "Upgrade to Pro to save more layouts")
        XCTAssertEqual(presentation.menuTitle, "Free plan · Limit reached")
        XCTAssertTrue(presentation.isLimitReached)
    }

    func testPlanStatusPresentationShowsProForAnyLayoutCount() {
        let presentation = PlanStatusPresentation(isProUnlocked: true, layoutCount: 12)

        XCTAssertEqual(presentation.title, "Pro active")
        XCTAssertEqual(presentation.detail, "All Pro features unlocked")
        XCTAssertEqual(presentation.menuTitle, "Pro active")
        XCTAssertEqual(presentation.systemImageName, "checkmark.seal.fill")
        XCTAssertFalse(presentation.isLimitReached)
        XCTAssertTrue(presentation.isProUnlocked)
    }

    func testLimitReachedPlanStatusRoutesToPurchase() {
        let purchaseURL = URL(string: "https://www.creem.io/test/payment/prod_test")!

        XCTAssertEqual(
            PlanStatusActionResolver.action(
                for: PlanStatusPresentation(isProUnlocked: false, layoutCount: 3),
                purchaseURL: purchaseURL
            ),
            .purchase(purchaseURL)
        )
    }

    func testLimitReachedPlanStatusFallsBackToProSettingsWithoutPurchaseURL() {
        XCTAssertEqual(
            PlanStatusActionResolver.action(
                for: PlanStatusPresentation(isProUnlocked: false, layoutCount: 3),
                purchaseURL: nil
            ),
            .proSettings
        )
    }

    func testOtherPlanStatesRouteToProSettings() {
        let purchaseURL = URL(string: "https://www.creem.io/test/payment/prod_test")!

        XCTAssertEqual(
            PlanStatusActionResolver.action(
                for: PlanStatusPresentation(isProUnlocked: false, layoutCount: 2),
                purchaseURL: purchaseURL
            ),
            .proSettings
        )
        XCTAssertEqual(
            PlanStatusActionResolver.action(
                for: PlanStatusPresentation(isProUnlocked: true, layoutCount: 12),
                purchaseURL: purchaseURL
            ),
            .proSettings
        )
    }

    func testUpgradeActionRoutesToPurchaseWhenPurchaseURLConfigured() {
        let purchaseURL = URL(string: "https://www.creem.io/test/payment/prod_test")!

        XCTAssertEqual(
            PlanStatusActionResolver.upgradeAction(purchaseURL: purchaseURL),
            .purchase(purchaseURL)
        )
    }

    func testUpgradeActionFallsBackToProSettingsWithoutPurchaseURL() {
        XCTAssertEqual(
            PlanStatusActionResolver.upgradeAction(purchaseURL: nil),
            .proSettings
        )
    }

    func testProConfigurationParsesTestValues() {
        let values = LayoutLockProConfigurationValues(infoDictionary: [
            LayoutLockProConfiguration.purchaseURLKey: "https://www.creem.io/test/payment/prod_test",
            LayoutLockProConfiguration.proxyBaseURLKey: "https://proxy.example.workers.dev",
            LayoutLockProConfiguration.productIDKey: "prod_test",
            LayoutLockProConfiguration.environmentKey: "test"
        ])

        XCTAssertEqual(values.purchaseURL?.absoluteString, "https://www.creem.io/test/payment/prod_test")
        XCTAssertEqual(values.proxyBaseURL?.absoluteString, "https://proxy.example.workers.dev")
        XCTAssertEqual(values.productID, "prod_test")
        XCTAssertEqual(values.environment, .test)
        XCTAssertEqual(values.purchaseActionTitle, "Open Test Checkout")
        XCTAssertEqual(values.testModeMessage, "Test payments are enabled. No real charge will be made.")
    }

    func testProConfigurationRejectsReleasePlaceholders() {
        let values = LayoutLockProConfigurationValues(infoDictionary: [
            LayoutLockProConfiguration.purchaseURLKey: "https://example.com/layoutlock-pro-checkout",
            LayoutLockProConfiguration.proxyBaseURLKey: "https://example.com/layoutlock-license-proxy",
            LayoutLockProConfiguration.productIDKey: "prod_live_placeholder",
            LayoutLockProConfiguration.environmentKey: "live"
        ])

        XCTAssertNil(values.purchaseURL)
        XCTAssertNil(values.proxyBaseURL)
        XCTAssertNil(values.productID)
        XCTAssertEqual(values.environment, .live)
        XCTAssertEqual(values.purchaseActionTitle, "Buy LayoutLock Pro")
        XCTAssertNil(values.testModeMessage)
    }

    func testProConfigurationRejectsHttpUrls() {
        let values = LayoutLockProConfigurationValues(infoDictionary: [
            LayoutLockProConfiguration.purchaseURLKey: "http://www.creem.io/test/payment/prod_test",
            LayoutLockProConfiguration.proxyBaseURLKey: "http://proxy.example.workers.dev"
        ])

        XCTAssertNil(values.purchaseURL)
        XCTAssertNil(values.proxyBaseURL)
    }

    func testSettingsNavigationSelectsProTab() {
        let controller = SettingsNavigationController()

        XCTAssertEqual(controller.selectedTab, .general)

        controller.showPro()

        XCTAssertEqual(controller.selectedTab, .pro)
    }

    func testActiveValidationResultRequiresExpectedProduct() throws {
        let result = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: nil,
            productID: "prod_expected",
            instanceID: "inst_123",
            message: nil,
            receipt: nil
        )

        XCTAssertEqual(try result.validatingProductID("prod_expected"), result)
        XCTAssertThrowsError(try result.validatingProductID("prod_other")) { error in
            XCTAssertEqual(error as? LicenseActivationClientError, .invalidProduct)
        }
    }

    func testInactiveValidationResultDoesNotRequireProduct() throws {
        let result = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: nil,
            productID: nil,
            instanceID: nil,
            message: "License inactive.",
            receipt: nil
        )

        XCTAssertEqual(try result.validatingProductID("prod_expected"), result)
    }

    func testActivateStoresActiveEntitlementAndLicenseKey() async throws {
        let credential = "test-device-credential"
        let validatedAt = Date(timeIntervalSince1970: 1_000)
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: validatedAt,
            instanceID: "inst_123"
        )
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .active,
            validatedAt: validatedAt,
            customerID: "cust_123",
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: "Pro active.",
            receipt: receipt
        )
        let licenseKeyStore = InMemoryLicenseKeyStore()
        let controller = makeController(client: client, licenseKeyStore: licenseKeyStore, deviceCredential: credential)

        await controller.activate(licenseKey: " KEY-123 ")

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.lastValidatedAt, validatedAt)
        XCTAssertEqual(controller.entitlementState.instanceID, "inst_123")
        XCTAssertEqual(controller.entitlementState.receipt, receipt)
        XCTAssertNil(controller.entitlementState.statusMessage)
        XCTAssertFalse(controller.requiresLicenseKeyEntry)
        XCTAssertEqual(try licenseKeyStore.loadLicenseKey(), "KEY-123")
    }

    func testDeviceCredentialRetryAllowsActivationWithoutRestart() async throws {
        let credential = "recovered-device-credential"
        let deviceStore = RecoveringDeviceCredentialStore(
            credential: credential,
            initialError: EntitlementStoreError.keychainStatus(errSecMissingEntitlement)
        )
        let store = EntitlementStore(
            userDefaults: makeUserDefaults(),
            licenseKeyStore: InMemoryLicenseKeyStore(),
            deviceCredentialStore: deviceStore,
            stateKey: "state"
        )
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: nil,
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 1_000),
                instanceID: "inst_123"
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Secure license storage is unavailable in this build. Run a properly signed LayoutLock build."
        )
        XCTAssertEqual(client.activateCallCount, 0)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(client.activateCallCount, 1)
        XCTAssertEqual(deviceStore.loadCallCount, 2)
    }

    func testActivationUnlocksProEvenWhenKeychainSaveFails() async throws {
        let credential = "test-device-credential"
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: "Pro active.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        let licenseKeyStore = FailingLicenseKeyStore()
        let store = makeStore(licenseKeyStore: licenseKeyStore, deviceCredential: credential)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertTrue(controller.requiresLicenseKeyEntry)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Pro is active, but the license key couldn't be saved. Re-enter it below to finish setup."
        )

        let freshController = EntitlementController(
            store: store,
            client: FakeLicenseActivationClient(),
            appVersionProvider: { "1.0" },
            deviceLabelProvider: { "Test Mac" },
            productIDProvider: { "prod_4kKRRbopJu2qSEXsnnFJ79" }
        )
        XCTAssertTrue(freshController.isProUnlocked, "Receipt should persist across restart even when license key save failed")
        XCTAssertTrue(freshController.requiresLicenseKeyEntry)
    }

    func testDeactivationClearsLicenseAndPreservesDeviceCredential() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        try licenseKeyStore.saveLicenseKey("KEY-123")
        let deviceStore = TrackingDeviceCredentialStore(credential: credential)
        let store = EntitlementStore(
            userDefaults: makeUserDefaults(),
            licenseKeyStore: licenseKeyStore,
            deviceCredentialStore: deviceStore,
            stateKey: "state"
        )
        store.saveState(EntitlementState(
            status: .active,
            lastValidatedAt: Date(timeIntervalSince1970: 100),
            instanceID: "inst_123",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 100)
            )
        ))
        let client = FakeLicenseActivationClient()
        client.deactivateResult = try inactiveResult(deviceCredential: credential)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.status, .inactive)
        XCTAssertNil(controller.entitlementState.instanceID)
        XCTAssertNil(try licenseKeyStore.loadLicenseKey())
        XCTAssertEqual(deviceStore.deleteCallCount, 0)
        XCTAssertEqual(client.lastDeactivateRequest?.instanceID, "inst_123")
        XCTAssertEqual(client.lastDeactivateRequest?.licenseKey, "KEY-123")

        let freshController = makeController(store: store, deviceCredential: credential)
        XCTAssertFalse(freshController.isProUnlocked)
        XCTAssertEqual(freshController.entitlementState.status, .inactive)
    }

    func testDeactivationPrefersStoredKeyOverEnteredKey() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123"
        )
        let client = FakeLicenseActivationClient()
        client.deactivateResult = try inactiveResult(deviceCredential: credential)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense(licenseKey: "STALE-KEY")

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(client.lastDeactivateRequest?.licenseKey, "KEY-123")
    }

    func testDeactivationAcceptsReenteredKeyWhenStoredKeyIsMissing() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(deviceCredential: credential, licenseKey: nil)
        let client = FakeLicenseActivationClient()
        client.deactivateResult = try inactiveResult(deviceCredential: credential)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense(licenseKey: " REENTERED-KEY ")

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(client.lastDeactivateRequest?.licenseKey, "REENTERED-KEY")
    }

    func testDeactivationWithoutLicenseKeyPreservesPro() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(deviceCredential: credential, licenseKey: nil)
        let client = FakeLicenseActivationClient()
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertTrue(controller.requiresLicenseKeyEntry)
        XCTAssertEqual(client.deactivateCallCount, 0)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Enter your license key before deactivating Pro on this Mac."
        )
    }

    func testDeactivationFailurePreservesVerifiedProAndLicenseKey() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        try licenseKeyStore.saveLicenseKey("KEY-123")
        let store = makeStore(licenseKeyStore: licenseKeyStore, deviceCredential: credential)
        store.saveState(EntitlementState(
            status: .active,
            instanceID: "inst_123",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 100)
            )
        ))
        let client = FakeLicenseActivationClient()
        client.deactivateError = URLError(.notConnectedToInternet)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(try licenseKeyStore.loadLicenseKey(), "KEY-123")
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Could not deactivate Pro on this Mac. Pro stays active; try again later."
        )
    }

    func testUnverifiedDeactivationResponsePreservesProAndLicenseKey() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        try licenseKeyStore.saveLicenseKey("KEY-123")
        let store = makeStore(licenseKeyStore: licenseKeyStore, deviceCredential: credential)
        store.saveState(EntitlementState(
            status: .active,
            instanceID: "inst_123",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 100)
            )
        ))
        let client = FakeLicenseActivationClient()
        client.deactivateResult = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "Pro was deactivated on this Mac.",
            receipt: nil
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(try licenseKeyStore.loadLicenseKey(), "KEY-123")
    }

    func testSignedActiveDeactivationResponsePreservesProAndLicenseKey() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        try licenseKeyStore.saveLicenseKey("KEY-123")
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            licenseKeyStore: licenseKeyStore
        )
        let client = FakeLicenseActivationClient()
        client.deactivateResult = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "Pro was deactivated on this Mac.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: "inst_123"
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(try licenseKeyStore.loadLicenseKey(), "KEY-123")
    }

    func testDeactivationRemainsFreeWhenLicenseKeyDeletionFails() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = DeleteFailingLicenseKeyStore(licenseKey: "KEY-123")
        let store = makeStore(licenseKeyStore: licenseKeyStore, deviceCredential: credential)
        store.saveState(EntitlementState(
            status: .active,
            instanceID: "inst_123",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 100)
            )
        ))
        let client = FakeLicenseActivationClient()
        client.deactivateResult = try inactiveResult(deviceCredential: credential)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.deactivateLicense()

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Pro was deactivated, but the stored license key could not be removed."
        )
    }

    func testValidationFailureKeepsCachedActiveEntitlement() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(deviceCredential: credential, licenseKey: "KEY-123")
        let client = FakeLicenseActivationClient()
        client.validateError = URLError(.notConnectedToInternet)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Could not validate the license. Pro stays active on this Mac and will retry later."
        )
    }

    func testManualValidationWithoutAnyLicenseKeyShowsMessage() async {
        let client = FakeLicenseActivationClient()
        let controller = makeController(client: client)

        await controller.validateLicense()

        XCTAssertEqual(controller.entitlementState.statusMessage, "Enter your license key to validate Pro.")
        XCTAssertEqual(client.validateCallCount, 0)
    }

    func testManualValidationUsesEnteredKeyWhenStoredKeyIsMissing() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: nil,
            licenseKeyStore: licenseKeyStore
        )
        let client = FakeLicenseActivationClient()
        client.validateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: nil,
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: "inst_123"
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        XCTAssertTrue(controller.requiresLicenseKeyEntry)

        await controller.validateLicense(licenseKey: " ENTERED-KEY ")

        XCTAssertEqual(client.lastValidateRequest?.licenseKey, "ENTERED-KEY")
        XCTAssertEqual(try licenseKeyStore.loadLicenseKey(), "ENTERED-KEY")
        XCTAssertNil(controller.entitlementState.statusMessage)
        XCTAssertFalse(controller.requiresLicenseKeyEntry)
    }

    func testManualValidationPrefersStoredKeyOverEnteredKey() async throws {
        let credential = "aabbccdd"
        let licenseKeyStore = InMemoryLicenseKeyStore()
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "STORED-KEY",
            licenseKeyStore: licenseKeyStore
        )
        let client = FakeLicenseActivationClient()
        client.validateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: "Validated.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: "inst_123"
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateLicense(licenseKey: "ENTERED-KEY")

        XCTAssertEqual(client.lastValidateRequest?.licenseKey, "STORED-KEY")
    }

    func testCredentialRecoveryRestoresCachedProBeforeValidationFailure() async throws {
        let credential = "recovered-device-credential"
        let userDefaults = makeUserDefaults()
        let licenseKeyStore = InMemoryLicenseKeyStore()
        try licenseKeyStore.saveLicenseKey("KEY-123")
        let deviceStore = RecoveringDeviceCredentialStore(
            credential: credential,
            initialError: EntitlementStoreError.keychainStatus(errSecInteractionNotAllowed)
        )
        let store = EntitlementStore(
            userDefaults: userDefaults,
            licenseKeyStore: licenseKeyStore,
            deviceCredentialStore: deviceStore,
            stateKey: "state"
        )
        store.saveState(EntitlementState(
            status: .active,
            instanceID: "inst_123",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 100),
                instanceID: "inst_123"
            )
        ))
        let client = FakeLicenseActivationClient()
        client.validateError = URLError(.notConnectedToInternet)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Secure license storage is locked. Unlock your Mac and try again."
        )

        await controller.validateLicense()

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 1)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Could not validate the license. Pro stays active on this Mac and will retry later."
        )
    }

    func testInactiveValidationFallsBackToFree() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(deviceCredential: credential, licenseKey: "KEY-123")
        let client = FakeLicenseActivationClient()
        client.validateResult = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "This license is not active.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "inactive",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: nil
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateLicense()

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.status, .inactive)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "This license key is invalid. Check the key and try again."
        )
    }

    func testActivationLimitUsesSpecificAnotherMacMessage() async throws {
        let credential = "aabbccdd"
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "This license is already active on another Mac.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "inactive",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: nil
            )
        )
        let controller = makeController(client: client, deviceCredential: credential)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "This license is already active on another Mac. Deactivate it there before activating it here."
        )
    }

    func testInactiveMessagesUseAllowlistedCopy() async throws {
        let credential = "aabbccdd"
        let cases = [
            ("This license is expired.", "This license has expired."),
            (
                "This license is inactive.",
                "This license has been disabled. Contact support if you think this is a mistake."
            ),
            (
                "Open https://unexpected.example to fix this license.",
                "This license could not be activated. Check the key and try again."
            )
        ]

        for (proxyMessage, expectedMessage) in cases {
            let client = FakeLicenseActivationClient()
            client.activateResult = LicenseValidationResult(
                status: .inactive,
                validatedAt: Date(timeIntervalSince1970: 200),
                customerID: nil,
                productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
                instanceID: nil,
                message: proxyMessage,
                receipt: try TestReceiptFactory.makeReceipt(
                    status: "inactive",
                    deviceCredential: credential,
                    validatedAt: Date(timeIntervalSince1970: 200),
                    instanceID: nil
                )
            )
            let controller = makeController(client: client, deviceCredential: credential)

            await controller.activate(licenseKey: "KEY-123")

            XCTAssertEqual(controller.entitlementState.statusMessage, expectedMessage)
        }
    }

    func testEmptyActivationKeyReportsMessage() async {
        let controller = makeController()

        await controller.activate(licenseKey: " ")

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.statusMessage, "Enter a license key to activate Pro.")
    }

    func testProductMismatchDoesNotUnlockPro() async {
        let client = FakeLicenseActivationClient()
        client.activateError = LicenseActivationClientError.invalidProduct
        let controller = makeController(client: client)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.statusMessage, "This license is not for LayoutLock Pro.")
    }

    func testCachedValidationSkipsWhenNoLicenseKeyIsStored() async {
        let client = FakeLicenseActivationClient()
        let controller = makeController(client: client)

        await controller.validateCachedLicenseIfNeeded(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 0)
    }

    func testCachedValidationSkipsWhenLastValidationIsRecent() async throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            lastValidatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let client = FakeLicenseActivationClient()
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateCachedLicenseIfNeeded(
            now: Date(timeIntervalSince1970: 1_000 + 60),
            minimumInterval: 24 * 60 * 60
        )

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 0)
        XCTAssertEqual(controller.entitlementState.lastValidatedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testCachedValidationRefreshesStaleActiveLicense() async throws {
        let staleCheckDate = Date(timeIntervalSince1970: 100 + 24 * 60 * 60 + 1)
        let validatedAt = Date(timeIntervalSince1970: 90_000)
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            lastValidatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = FakeLicenseActivationClient()
        client.validateResult = LicenseValidationResult(
            status: .active,
            validatedAt: validatedAt,
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: "Pro active.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "active",
                deviceCredential: credential,
                validatedAt: validatedAt,
                instanceID: "inst_123"
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateCachedLicenseIfNeeded(
            now: staleCheckDate,
            minimumInterval: 24 * 60 * 60
        )

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 1)
        XCTAssertEqual(controller.entitlementState.lastValidatedAt, validatedAt)
        XCTAssertEqual(controller.entitlementState.instanceID, "inst_123")
    }

    func testCachedValidationFallsBackToFreeWhenProxyReturnsInactive() async throws {
        let staleCheckDate = Date(timeIntervalSince1970: 100 + 24 * 60 * 60 + 1)
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            lastValidatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = FakeLicenseActivationClient()
        client.validateResult = LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 2_000),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "This license is not active.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "inactive",
                deviceCredential: credential,
                validatedAt: Date(timeIntervalSince1970: 2_000),
                instanceID: nil
            )
        )
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateCachedLicenseIfNeeded(
            now: staleCheckDate,
            minimumInterval: 24 * 60 * 60
        )

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 1)
        XCTAssertEqual(controller.entitlementState.status, .inactive)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "This license key is invalid. Check the key and try again."
        )
    }

    func testCachedValidationFailureKeepsCachedActiveEntitlement() async throws {
        let staleCheckDate = Date(timeIntervalSince1970: 100 + 24 * 60 * 60 + 1)
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            lastValidatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = FakeLicenseActivationClient()
        client.validateError = URLError(.cannotConnectToHost)
        let controller = makeController(store: store, client: client, deviceCredential: credential)

        await controller.validateCachedLicenseIfNeeded(
            now: staleCheckDate,
            minimumInterval: 24 * 60 * 60
        )

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(client.validateCallCount, 1)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Could not validate the license. Pro stays active on this Mac and will retry later."
        )
    }

    // MARK: - Receipt verification tests

    func testUnsignedStateIsRejectedOnLoad() throws {
        let userDefaults = makeUserDefaults()
        let store = EntitlementStore(
            userDefaults: userDefaults,
            licenseKeyStore: InMemoryLicenseKeyStore(),
            deviceCredentialStore: StubDeviceCredentialStore(credential: "test-credential"),
            stateKey: "state"
        )
        store.saveState(EntitlementState(status: .active, lastValidatedAt: Date()))

        let controller = makeController(store: store, deviceCredential: "test-credential")

        XCTAssertFalse(controller.isProUnlocked)
    }

    func testTamperedReceiptIsRejected() throws {
        let credential = "aabbccdd"
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: Date(timeIntervalSince1970: 100)
        )
        let verifiedPayload = try EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: credential,
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        ).get()
        XCTAssertEqual(verifiedPayload.status, "active")

        var parts = receipt.split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(Data(base64Encoded: parts[2]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=="))
        signature[signature.startIndex] ^= 0x01
        XCTAssertNoThrow(try P256.Signing.ECDSASignature(rawRepresentation: signature))
        parts[2] = signature.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let tampered = parts.joined(separator: ".")
        XCTAssertEqual(tampered.count, receipt.count)
        XCTAssertEqual(EntitlementReceipt.verify(
            receipt: tampered,
            deviceCredential: credential,
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        ), .failure(.invalidSignature))

        let userDefaults = makeUserDefaults()
        let store = EntitlementStore(
            userDefaults: userDefaults,
            licenseKeyStore: InMemoryLicenseKeyStore(),
            deviceCredentialStore: StubDeviceCredentialStore(credential: credential),
            stateKey: "state"
        )
        store.saveState(EntitlementState(status: .active, lastValidatedAt: Date(timeIntervalSince1970: 100), receipt: tampered))

        let controller = makeController(store: store, deviceCredential: credential)

        XCTAssertFalse(controller.isProUnlocked)
    }

    func testWrongDeviceBindingIsRejected() throws {
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "original-device",
            validatedAt: Date(timeIntervalSince1970: 100)
        )

        let userDefaults = makeUserDefaults()
        let store = EntitlementStore(
            userDefaults: userDefaults,
            licenseKeyStore: InMemoryLicenseKeyStore(),
            deviceCredentialStore: StubDeviceCredentialStore(credential: "different-device"),
            stateKey: "state"
        )
        store.saveState(EntitlementState(status: .active, lastValidatedAt: Date(timeIntervalSince1970: 100), receipt: receipt))

        let controller = makeController(store: store, deviceCredential: "different-device")

        XCTAssertFalse(controller.isProUnlocked)
    }

    func testValidReceiptUnlocksProOnLoad() throws {
        let credential = "aabbccdd"
        let store = try makeStoreWithActiveReceipt(
            deviceCredential: credential,
            licenseKey: "KEY-123",
            lastValidatedAt: Date(timeIntervalSince1970: 100),
            statusMessage: "Pro license validated."
        )
        let controller = makeController(store: store, deviceCredential: credential)

        XCTAssertTrue(controller.isProUnlocked)
        XCTAssertEqual(controller.entitlementState.instanceID, "inst_123")
        XCTAssertNil(controller.entitlementState.statusMessage)
        XCTAssertFalse(controller.requiresLicenseKeyEntry)
    }

    func testMissingDeviceCredentialStartsFree() throws {
        let credential = "aabbccdd"
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: Date(timeIntervalSince1970: 100)
        )

        let userDefaults = makeUserDefaults()
        let store = EntitlementStore(
            userDefaults: userDefaults,
            licenseKeyStore: InMemoryLicenseKeyStore(),
            deviceCredentialStore: FailingDeviceCredentialStore(),
            stateKey: "state"
        )
        store.saveState(EntitlementState(status: .active, lastValidatedAt: Date(timeIntervalSince1970: 100), receipt: receipt))

        let controller = EntitlementController(
            store: store,
            client: FakeLicenseActivationClient(),
            appVersionProvider: { "1.0" },
            deviceLabelProvider: { "Test Mac" },
            productIDProvider: { "prod_4kKRRbopJu2qSEXsnnFJ79" }
        )

        XCTAssertFalse(controller.isProUnlocked)
        XCTAssertEqual(
            controller.entitlementState.statusMessage,
            "Secure license storage is temporarily unavailable. Try again."
        )
    }

    // MARK: - Online response verification (P1 fix)

    func testUnsignedOnlineResponseDoesNotUnlockPro() async {
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: "cust_123",
            productID: "prod_123",
            instanceID: "inst_123",
            message: "Pro active.",
            receipt: nil
        )
        let controller = makeController(client: client)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertFalse(controller.isProUnlocked)
    }

    func testActiveOnlineResponseWithInvalidReceiptDoesNotUnlockPro() async throws {
        let credential = "aabbccdd"
        let wrongDeviceReceipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "wrong-device",
            validatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let client = FakeLicenseActivationClient()
        client.activateResult = LicenseValidationResult(
            status: .active,
            validatedAt: Date(timeIntervalSince1970: 1_000),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: "inst_123",
            message: "Pro active.",
            receipt: wrongDeviceReceipt
        )
        let controller = makeController(client: client, deviceCredential: credential)

        await controller.activate(licenseKey: "KEY-123")

        XCTAssertFalse(controller.isProUnlocked)
    }

    // MARK: - Product/environment enforcement (P2 fix)

    func testProductMismatchReceiptIsRejected() throws {
        let credential = "aabbccdd"
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: Date(timeIntervalSince1970: 100),
            productID: "prod_wrong"
        )

        let result = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: credential,
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        XCTAssertEqual(result, .failure(.productMismatch))
    }

    func testCorrectProductReceiptIsAccepted() throws {
        let credential = "aabbccdd"
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: Date(timeIntervalSince1970: 100),
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        let result = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: credential,
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        if case .success(let payload) = result {
            XCTAssertEqual(payload.status, "active")
        } else {
            XCTFail("Expected success")
        }
    }

    func testMalformedReceiptIsRejected() {
        let result = EntitlementReceipt.verify(
            receipt: "not-a-jws",
            deviceCredential: "aabbccdd",
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        XCTAssertEqual(result, .failure(.malformed))
    }

    func testUnknownSigningKeyIsRejected() throws {
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "aabbccdd",
            validatedAt: Date(timeIntervalSince1970: 100),
            keyId: "unknown-test-key"
        )

        let result = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: "aabbccdd",
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        XCTAssertEqual(result, .failure(.unknownKeyId))
    }

    func testWrongEnvironmentReceiptIsRejected() throws {
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "aabbccdd",
            validatedAt: Date(timeIntervalSince1970: 100),
            environment: "live"
        )

        let result = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: "aabbccdd",
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        XCTAssertEqual(result, .failure(.environmentMismatch))
    }

    func testMissingProductConfigurationStartsFree() throws {
        let credential = "aabbccdd"
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: credential,
            validatedAt: Date(timeIntervalSince1970: 100)
        )
        let store = makeStore(licenseKeyStore: InMemoryLicenseKeyStore(), deviceCredential: credential)
        store.saveState(EntitlementState(status: .active, receipt: receipt))

        let controller = EntitlementController(
            store: store,
            client: FakeLicenseActivationClient(),
            appVersionProvider: { "1.0" },
            deviceLabelProvider: { "Test Mac" },
            productIDProvider: { nil }
        )

        XCTAssertFalse(controller.isProUnlocked)
    }

    func testSigningKeyRotationAcceptsCurrentAndPreviousKeys() throws {
        let currentPrivateKey = P256.Signing.PrivateKey()
        let currentKeyID = "test-rotation-current"
        let currentPublicKey = SigningPublicKey(
            keyId: currentKeyID,
            rawRepresentationHex: currentPrivateKey.publicKey.x963Representation.hexString,
            environment: "test"
        )
        EntitlementSigningKey.trustedKeys.append(currentPublicKey)
        defer {
            EntitlementSigningKey.trustedKeys.removeAll { $0.keyId == currentKeyID }
        }

        let previousReceipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "aabbccdd",
            validatedAt: Date(timeIntervalSince1970: 100)
        )
        let currentReceipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: "aabbccdd",
            validatedAt: Date(timeIntervalSince1970: 200),
            keyId: currentKeyID,
            signingKey: currentPrivateKey
        )

        for receipt in [previousReceipt, currentReceipt] {
            let result = EntitlementReceipt.verify(
                receipt: receipt,
                deviceCredential: "aabbccdd",
                expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
            )
            guard case .success = result else {
                return XCTFail("Both trusted rotation keys should verify")
            }
        }
    }

    // MARK: - Shared cross-language test vector (P2)

    func testSharedVectorVerifiesInCryptoKit() {
        let jws = "eyJhbGciOiJFUzI1NiIsImtpZCI6InRlc3QtZml4dHVyZS0xIiwidHlwIjoibGF5b3V0bG9jay1lbnRpdGxlbWVudCtqd3MifQ.eyJ2ZXJzaW9uIjoxLCJpc3N1ZXIiOiJsYXlvdXRsb2NrLXByb3h5IiwiYXVkaWVuY2UiOiJsYXlvdXRsb2NrIiwic3RhdHVzIjoiYWN0aXZlIiwidmFsaWRhdGVkQXQiOiIyMDI2LTAxLTE1VDEwOjMwOjAwLjAwMFoiLCJwcm9kdWN0SUQiOiJwcm9kXzRrS1JSYm9wSnUycVNFWHNubkZKNzkiLCJlbnZpcm9ubWVudCI6InRlc3QiLCJpbnN0YW5jZUlEIjoiaW5zdF9maXh0dXJlXzAwMSIsImRldmljZUJpbmRpbmciOiJiNjg5ZDg5YmU0ZWM2OTMzNjMxMWY4N2Y3YzBmNjk3OWVhOTJjOWEwNmIyMjg2M2VlYjJlMjJmOGY0YzBjMWZlIn0.0cb5bTrgm14M-tXCvkdaklqqJdKkjBKHFD7bcOdGKGkS5lQs-yfkkYHcnpmWwKpWjH_a4Jgm6-tllxXf3iF6zQ"

        let result = EntitlementReceipt.verify(
            receipt: jws,
            deviceCredential: "shared-vector-credential",
            expectedProductID: "prod_4kKRRbopJu2qSEXsnnFJ79"
        )

        if case .success(let payload) = result {
            XCTAssertEqual(payload.status, "active")
            XCTAssertEqual(payload.instanceID, "inst_fixture_001")
            XCTAssertEqual(payload.productID, "prod_4kKRRbopJu2qSEXsnnFJ79")
        } else {
            XCTFail("Shared vector must verify in CryptoKit")
        }
    }

    // MARK: - Helpers

    private func makeController(
        store: EntitlementStore? = nil,
        client: FakeLicenseActivationClient = FakeLicenseActivationClient(),
        licenseKeyStore: LicenseKeyStoring = InMemoryLicenseKeyStore(),
        deviceCredential: String = "test-device-credential"
    ) -> EntitlementController {
        EntitlementController(
            store: store ?? makeStore(licenseKeyStore: licenseKeyStore, deviceCredential: deviceCredential),
            client: client,
            appVersionProvider: { "1.0" },
            deviceLabelProvider: { "Test Mac" },
            productIDProvider: { "prod_4kKRRbopJu2qSEXsnnFJ79" }
        )
    }

    private func inactiveResult(deviceCredential: String) throws -> LicenseValidationResult {
        LicenseValidationResult(
            status: .inactive,
            validatedAt: Date(timeIntervalSince1970: 200),
            customerID: nil,
            productID: "prod_4kKRRbopJu2qSEXsnnFJ79",
            instanceID: nil,
            message: "Pro was deactivated on this Mac.",
            receipt: try TestReceiptFactory.makeReceipt(
                status: "inactive",
                deviceCredential: deviceCredential,
                validatedAt: Date(timeIntervalSince1970: 200),
                instanceID: nil
            )
        )
    }

    private func makeStore(
        licenseKeyStore: LicenseKeyStoring,
        deviceCredential: String = "test-device-credential"
    ) -> EntitlementStore {
        EntitlementStore(
            userDefaults: makeUserDefaults(),
            licenseKeyStore: licenseKeyStore,
            deviceCredentialStore: StubDeviceCredentialStore(credential: deviceCredential),
            stateKey: "state"
        )
    }

    private func makeStoreWithActiveReceipt(
        deviceCredential: String,
        licenseKey: String?,
        lastValidatedAt: Date = Date(timeIntervalSince1970: 100),
        licenseKeyStore: LicenseKeyStoring = InMemoryLicenseKeyStore(),
        statusMessage: String? = nil
    ) throws -> EntitlementStore {
        let receipt = try TestReceiptFactory.makeReceipt(
            status: "active",
            deviceCredential: deviceCredential,
            validatedAt: lastValidatedAt
        )
        if let licenseKey {
            try licenseKeyStore.saveLicenseKey(licenseKey)
        }
        let store = EntitlementStore(
            userDefaults: makeUserDefaults(),
            licenseKeyStore: licenseKeyStore,
            deviceCredentialStore: StubDeviceCredentialStore(credential: deviceCredential),
            stateKey: "state"
        )
        store.saveState(EntitlementState(
            status: .active,
            lastValidatedAt: lastValidatedAt,
            instanceID: "inst_123",
            statusMessage: statusMessage,
            receipt: receipt
        ))
        return store
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "EntitlementControllerTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}

// MARK: - Test receipt factory

enum TestReceiptFactory {
    private static let privateKeyRawHex = "de88b60b9b84cb4548888bd3023b3900f4704cb712232bbc0bb4fd7ef9e45f98"

    static func makeReceipt(
        status: String,
        deviceCredential: String,
        validatedAt: Date,
        productID: String = "prod_4kKRRbopJu2qSEXsnnFJ79",
        environment: String = "test",
        instanceID: String? = "inst_123",
        keyId: String = "test-fixture-1",
        signingKey: P256.Signing.PrivateKey? = nil
    ) throws -> String {
        let privateKey: P256.Signing.PrivateKey
        if let signingKey {
            privateKey = signingKey
        } else {
            privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: Data(hexString: TestReceiptFactory.privateKeyRawHex)
            )
        }

        let header: [String: String] = ["alg": "ES256", "kid": keyId, "typ": "layoutlock-entitlement+jws"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let deviceBinding = SHA256.hash(data: Data(deviceCredential.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var payload: [String: Any] = [
            "version": 1,
            "issuer": "layoutlock-proxy",
            "audience": "layoutlock",
            "status": status,
            "validatedAt": formatter.string(from: validatedAt),
            "productID": productID,
            "environment": environment,
            "deviceBinding": deviceBinding
        ]
        if let instanceID {
            payload["instanceID"] = instanceID
        } else {
            payload["instanceID"] = NSNull()
        }

        let headerB64 = base64urlEncode(JSONSerialization.dataWithSortedKeys(header))
        let payloadB64 = base64urlEncode(JSONSerialization.dataWithSortedKeys(payload))
        let signingInput = "\(headerB64).\(payloadB64)"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let sigB64 = base64urlEncode(signature.rawRepresentation)

        return "\(headerB64).\(payloadB64).\(sigB64)"
    }

    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexString: String) throws {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw NSError(domain: "HexDecode", code: 1)
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private extension JSONSerialization {
    static func dataWithSortedKeys(_ object: Any) -> Data {
        try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

// MARK: - License activation client

@MainActor
final class LicenseActivationClientTests: XCTestCase {
    private let productID = "prod_4kKRRbopJu2qSEXsnnFJ79"

    override func tearDown() {
        LicenseActivationURLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testActivationDecodesFractionalSecondsTimestamp() async throws {
        let client = makeClient(
            responseBody: responseBody(validatedAt: "2026-08-11T17:55:43.224Z")
        )

        let result = try await client.activate(makeRequest())

        XCTAssertEqual(result.status, .inactive)
        XCTAssertEqual(result.message, "This license is already active on another Mac.")
        XCTAssertEqual(result.validatedAt, makeDate("2026-08-11T17:55:43.224Z", fractionalSeconds: true))
    }

    func testActivationDecodesWholeSecondsTimestamp() async throws {
        let client = makeClient(
            responseBody: responseBody(validatedAt: "2026-08-11T17:55:43Z")
        )

        let result = try await client.activate(makeRequest())

        XCTAssertEqual(result.validatedAt, makeDate("2026-08-11T17:55:43Z", fractionalSeconds: false))
    }

    func testMalformedTimestampReturnsControlledInvalidResponseError() async {
        let client = makeClient(responseBody: responseBody(validatedAt: "not-a-date"))

        do {
            _ = try await client.activate(makeRequest())
            XCTFail("Expected activation to fail")
        } catch {
            XCTAssertEqual(error as? LicenseActivationClientError, .invalidResponse)
        }
    }

    func testServerMessageResponseRemainsUnchanged() async {
        let message = "This license is already active on another Mac."
        let client = makeClient(
            statusCode: 409,
            responseBody: #"{"message":"This license is already active on another Mac."}"#
        )

        do {
            _ = try await client.activate(makeRequest())
            XCTFail("Expected activation to fail")
        } catch {
            XCTAssertEqual(error as? LicenseActivationClientError, .serverMessage(message))
        }
    }

    private func makeClient(
        statusCode: Int = 200,
        responseBody: String
    ) -> LicenseActivationClient {
        LicenseActivationURLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseBody.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenseActivationURLProtocolStub.self]
        return LicenseActivationClient(
            baseURLProvider: { URL(string: "https://license.example.com") },
            expectedProductIDProvider: { self.productID },
            session: URLSession(configuration: configuration)
        )
    }

    private func makeRequest() -> LicenseValidationRequest {
        LicenseValidationRequest(
            licenseKey: "KEY-123",
            appVersion: "1.0",
            deviceLabel: "Test Mac",
            deviceIdentifier: "device-123",
            instanceID: nil
        )
    }

    private func responseBody(validatedAt: String) -> String {
        """
        {
          "status": "inactive",
          "validatedAt": "\(validatedAt)",
          "customerID": null,
          "productID": "\(productID)",
          "instanceID": null,
          "message": "This license is already active on another Mac.",
          "receipt": null
        }
        """
    }

    private func makeDate(_ value: String, fractionalSeconds: Bool) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}

private final class LicenseActivationURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: LicenseActivationClientError.invalidResponse)
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test doubles

final class FakeLicenseActivationClient: LicenseActivationClienting {
    var activateResult = LicenseValidationResult(
        status: .active,
        validatedAt: Date(timeIntervalSince1970: 10),
        customerID: nil,
        productID: nil,
        instanceID: nil,
        message: nil,
        receipt: nil
    )
    var validateResult = LicenseValidationResult(
        status: .active,
        validatedAt: Date(timeIntervalSince1970: 20),
        customerID: nil,
        productID: nil,
        instanceID: nil,
        message: nil,
        receipt: nil
    )
    var deactivateResult = LicenseValidationResult(
        status: .inactive,
        validatedAt: Date(timeIntervalSince1970: 30),
        customerID: nil,
        productID: nil,
        instanceID: nil,
        message: nil,
        receipt: nil
    )
    var activateError: Error?
    var validateError: Error?
    var deactivateError: Error?
    private(set) var activateCallCount = 0
    private(set) var validateCallCount = 0
    private(set) var deactivateCallCount = 0
    private(set) var lastValidateRequest: LicenseValidationRequest?
    private(set) var lastDeactivateRequest: LicenseValidationRequest?

    func activate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        activateCallCount += 1
        if let activateError {
            throw activateError
        }

        return activateResult
    }

    func validate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        validateCallCount += 1
        lastValidateRequest = request
        if let validateError {
            throw validateError
        }

        return validateResult
    }

    func deactivate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        deactivateCallCount += 1
        lastDeactivateRequest = request
        if let deactivateError {
            throw deactivateError
        }

        return deactivateResult
    }
}

final class InMemoryLicenseKeyStore: LicenseKeyStoring {
    private var licenseKey: String?

    func loadLicenseKey() throws -> String? {
        licenseKey
    }

    func saveLicenseKey(_ licenseKey: String) throws {
        self.licenseKey = licenseKey
    }

    func deleteLicenseKey() throws {
        licenseKey = nil
    }
}

final class FailingLicenseKeyStore: LicenseKeyStoring {
    func loadLicenseKey() throws -> String? { nil }

    func saveLicenseKey(_ licenseKey: String) throws {
        throw NSError(
            domain: "FailingLicenseKeyStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not save license key."]
        )
    }

    func deleteLicenseKey() throws {}
}

final class DeleteFailingLicenseKeyStore: LicenseKeyStoring {
    private let licenseKey: String

    init(licenseKey: String) {
        self.licenseKey = licenseKey
    }

    func loadLicenseKey() throws -> String? { licenseKey }
    func saveLicenseKey(_ licenseKey: String) throws {}

    func deleteLicenseKey() throws {
        throw NSError(
            domain: "DeleteFailingLicenseKeyStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not delete license key."]
        )
    }
}

final class StubDeviceCredentialStore: DeviceCredentialStoring {
    private let credential: String

    init(credential: String) {
        self.credential = credential
    }

    func loadOrCreateCredential() throws -> String {
        credential
    }

    func deleteCredential() throws {}
}

final class TrackingDeviceCredentialStore: DeviceCredentialStoring {
    private let credential: String
    private(set) var deleteCallCount = 0

    init(credential: String) {
        self.credential = credential
    }

    func loadOrCreateCredential() throws -> String { credential }

    func deleteCredential() throws {
        deleteCallCount += 1
    }
}

final class FailingDeviceCredentialStore: DeviceCredentialStoring {
    func loadOrCreateCredential() throws -> String {
        throw EntitlementStoreError.keychainStatus(errSecNotAvailable)
    }

    func deleteCredential() throws {}
}

final class RecoveringDeviceCredentialStore: DeviceCredentialStoring {
    private let credential: String
    private let initialError: Error
    private(set) var loadCallCount = 0

    init(credential: String, initialError: Error) {
        self.credential = credential
        self.initialError = initialError
    }

    func loadOrCreateCredential() throws -> String {
        loadCallCount += 1
        if loadCallCount == 1 {
            throw initialError
        }
        return credential
    }

    func deleteCredential() throws {}
}
