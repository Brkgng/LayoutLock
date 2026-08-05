import AppKit
import Foundation

@MainActor
final class EntitlementController: ObservableObject, EntitlementProviding {
    @Published private(set) var entitlementState: EntitlementState
    @Published private(set) var isWorking = false
    @Published private(set) var requiresLicenseKeyEntry = false

    var onEntitlementDidChange: (() -> Void)?

    private let store: EntitlementStore
    private let client: LicenseActivationClienting
    private let appVersionProvider: () -> String
    private let deviceLabelProvider: () -> String
    private let productIDProvider: () -> String?
    private var deviceCredential: String?

    init(
        store: EntitlementStore = EntitlementStore(),
        client: LicenseActivationClienting = LicenseActivationClient(),
        appVersionProvider: @escaping () -> String = EntitlementController.defaultAppVersion,
        deviceLabelProvider: @escaping () -> String = EntitlementController.defaultDeviceLabel,
        productIDProvider: @escaping () -> String? = { LayoutLockProConfiguration.productID }
    ) {
        self.store = store
        self.client = client
        self.appVersionProvider = appVersionProvider
        self.deviceLabelProvider = deviceLabelProvider
        self.productIDProvider = productIDProvider

        let rawState = store.loadState()
        do {
            let deviceCredential = try store.loadDeviceCredential()
            self.deviceCredential = deviceCredential
            self.entitlementState = Self.verifyLoadedState(
                rawState,
                deviceCredential: deviceCredential,
                expectedProductID: productIDProvider()
            )
        } catch {
            self.deviceCredential = nil
            var state = EntitlementState.free
            state.statusMessage = Self.deviceSecurityMessage(for: error)
            self.entitlementState = state
            Self.logDeviceSecurityFailure(error)
        }

        if entitlementState.isProUnlocked {
            requiresLicenseKeyEntry = ((try? store.loadLicenseKey())?.nonEmptyValue == nil)
            if requiresLicenseKeyEntry, entitlementState.statusMessage == nil {
                entitlementState.statusMessage = "Re-enter your license key to validate or deactivate Pro on this Mac."
            }
        }
    }

    func activate(licenseKey: String) async {
        let normalizedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            updateTransientMessage("Enter a license key to activate Pro.")
            return
        }

        guard let request = makeRequest(licenseKey: normalizedKey, instanceID: entitlementState.instanceID) else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await client.activate(request)
            apply(result: result, licenseKey: normalizedKey)
        } catch {
            updateTransientMessage(error.userFacingDescription)
        }
    }

    func validateLicense(licenseKey enteredLicenseKey: String = "") async {
        let normalizedKey = enteredLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedKey: String?
        do {
            storedKey = try store.loadLicenseKey()
        } catch {
            guard !normalizedKey.isEmpty else {
                requiresLicenseKeyEntry = entitlementState.isProUnlocked
                updateTransientMessage(error.userFacingDescription)
                return
            }
            storedKey = nil
        }

        guard let licenseKey = storedKey.nonEmptyValue ?? normalizedKey.nonEmptyValue else {
            requiresLicenseKeyEntry = entitlementState.isProUnlocked
            updateTransientMessage("Enter your license key to validate Pro.")
            return
        }

        guard let request = makeRequest(licenseKey: licenseKey, instanceID: entitlementState.instanceID) else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await client.validate(request)
            apply(result: result, licenseKey: licenseKey)
        } catch {
            handleValidationFailure(error)
        }
    }

    func validateCachedLicenseIfNeeded(
        now: Date = .now,
        minimumInterval: TimeInterval = 24 * 60 * 60
    ) async {
        let licenseKey: String?
        do {
            licenseKey = try store.loadLicenseKey()
        } catch {
            requiresLicenseKeyEntry = entitlementState.isProUnlocked
            updateTransientMessage(error.userFacingDescription)
            return
        }

        guard let licenseKey, !licenseKey.isEmpty else {
            if entitlementState.isProUnlocked {
                requiresLicenseKeyEntry = true
                updateTransientMessage("Re-enter your license key to validate or deactivate Pro on this Mac.")
            }
            return
        }

        if let lastValidatedAt = entitlementState.lastValidatedAt,
           now.timeIntervalSince(lastValidatedAt) < minimumInterval {
            return
        }

        guard let request = makeRequest(licenseKey: licenseKey, instanceID: entitlementState.instanceID) else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await client.validate(request)
            apply(result: result, licenseKey: licenseKey)
        } catch {
            handleValidationFailure(error)
        }
    }

    func deactivateLicense(licenseKey enteredLicenseKey: String = "") async {
        let normalizedKey = enteredLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedKey: String?
        do {
            storedKey = try store.loadLicenseKey()
        } catch {
            guard !normalizedKey.isEmpty else {
                requiresLicenseKeyEntry = entitlementState.isProUnlocked
                updateTransientMessage(error.userFacingDescription)
                return
            }
            storedKey = nil
        }

        guard let licenseKey = storedKey.nonEmptyValue ?? normalizedKey.nonEmptyValue else {
            requiresLicenseKeyEntry = entitlementState.isProUnlocked
            updateTransientMessage("Enter your license key before deactivating Pro on this Mac.")
            return
        }

        guard let instanceID = entitlementState.instanceID else {
            updateTransientMessage("The active license instance is unavailable. Validate the license and try again.")
            return
        }

        guard let request = makeRequest(licenseKey: licenseKey, instanceID: instanceID) else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await client.deactivate(request)
            applyDeactivation(result: result)
        } catch {
            handleDeactivationFailure(error)
        }
    }

    private static func verifyLoadedState(
        _ state: EntitlementState,
        deviceCredential: String?,
        expectedProductID: String?
    ) -> EntitlementState {
        guard let deviceCredential,
              let receipt = state.receipt,
              let expectedProductID else {
            return .free
        }

        switch EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: deviceCredential,
            expectedProductID: expectedProductID
        ) {
        case .success(let payload):
            return EntitlementState(
                status: EntitlementValidationStatus(rawValue: payload.status) ?? .inactive,
                lastValidatedAt: payload.validatedAt,
                customerID: nil,
                productID: payload.productID,
                instanceID: payload.instanceID,
                statusMessage: nil,
                receipt: receipt
            )
        case .failure:
            return .free
        }
    }

    private func makeRequest(
        licenseKey: String,
        instanceID: String?
    ) -> LicenseValidationRequest? {
        guard let deviceCredential = ensureDeviceCredential() else { return nil }
        return LicenseValidationRequest(
            licenseKey: licenseKey,
            appVersion: appVersionProvider(),
            deviceLabel: deviceLabelProvider(),
            deviceIdentifier: deviceCredential,
            instanceID: instanceID
        )
    }

    private func apply(
        result: LicenseValidationResult,
        licenseKey: String
    ) {
        guard let deviceCredential else {
            updateTransientMessage("Secure license storage is temporarily unavailable. Try again.")
            return
        }

        guard let receipt = result.receipt,
              let expectedProductID = productIDProvider() else {
            handleUnverifiedResponse()
            return
        }

        let verification = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: deviceCredential,
            expectedProductID: expectedProductID
        )

        guard case .success(let payload) = verification else {
            handleUnverifiedResponse()
            return
        }

        let status = EntitlementValidationStatus(rawValue: payload.status) ?? .inactive
        let state = EntitlementState(
            status: status,
            lastValidatedAt: payload.validatedAt,
            customerID: nil,
            productID: payload.productID,
            instanceID: payload.instanceID,
            statusMessage: status == .inactive
                ? Self.inactiveMessage(for: result.message)
                : nil,
            receipt: receipt
        )

        if status == .active {
            do {
                try store.saveLicenseKey(licenseKey)
                requiresLicenseKeyEntry = false
            } catch {
                AppLogger.entitlements.error("Failed to save license key to Keychain: \(error.localizedDescription)")
                requiresLicenseKeyEntry = true
                var msgState = state
                msgState.statusMessage = "Pro is active, but the license key couldn't be saved. Re-enter it below to finish setup."
                applyState(msgState)
                return
            }
        }

        applyState(state)
    }

    private func ensureDeviceCredential() -> String? {
        if let deviceCredential {
            return deviceCredential
        }

        do {
            let recoveredCredential = try store.loadDeviceCredential()
            deviceCredential = recoveredCredential

            let recoveredState = Self.verifyLoadedState(
                store.loadState(),
                deviceCredential: recoveredCredential,
                expectedProductID: productIDProvider()
            )
            if recoveredState.isProUnlocked {
                applyState(recoveredState, shouldPersist: false)
            }
            return recoveredCredential
        } catch {
            Self.logDeviceSecurityFailure(error)
            updateTransientMessage(Self.deviceSecurityMessage(for: error))
            return nil
        }
    }

    private func applyDeactivation(result: LicenseValidationResult) {
        guard let deviceCredential,
              let receipt = result.receipt,
              let expectedProductID = productIDProvider() else {
            handleUnverifiedDeactivation()
            return
        }

        let verification = EntitlementReceipt.verify(
            receipt: receipt,
            deviceCredential: deviceCredential,
            expectedProductID: expectedProductID
        )
        guard case .success(let payload) = verification,
              payload.status == EntitlementValidationStatus.inactive.rawValue,
              payload.instanceID == nil else {
            handleUnverifiedDeactivation()
            return
        }

        var state = EntitlementState(
            status: .inactive,
            lastValidatedAt: payload.validatedAt,
            customerID: nil,
            productID: payload.productID,
            instanceID: nil,
            statusMessage: result.message,
            receipt: receipt
        )

        do {
            try store.deleteLicenseKey()
        } catch {
            AppLogger.entitlements.error("Failed to delete license key from Keychain: \(error.localizedDescription)")
            state.statusMessage = "Pro was deactivated, but the stored license key could not be removed."
        }

        requiresLicenseKeyEntry = false
        applyState(state)
    }

    private func handleUnverifiedResponse() {
        if entitlementState.isProUnlocked {
            updateTransientMessage(
                "Could not validate the license. Pro stays active on this Mac and will retry later."
            )
        } else {
            updateTransientMessage("The license response could not be verified.")
        }
    }

    private func handleValidationFailure(_ error: Error) {
        if entitlementState.isProUnlocked {
            updateTransientMessage(
                "Could not validate the license. Pro stays active on this Mac and will retry later."
            )
            return
        }

        updateTransientMessage(error.userFacingDescription)
    }

    private func handleUnverifiedDeactivation() {
        updateTransientMessage(
            "Could not verify deactivation. Pro stays active on this Mac; try again later."
        )
    }

    private func handleDeactivationFailure(_ error: Error) {
        if entitlementState.isProUnlocked {
            updateTransientMessage(
                "Could not deactivate Pro on this Mac. Pro stays active; try again later."
            )
            return
        }

        updateTransientMessage(error.userFacingDescription)
    }

    private func updateTransientMessage(_ message: String) {
        var nextState = entitlementState
        nextState.statusMessage = message
        applyState(nextState, shouldPersist: false)
    }

    private func applyState(_ state: EntitlementState, shouldPersist: Bool = true) {
        let oldPlan = entitlementState.plan
        entitlementState = state

        if shouldPersist {
            store.saveState(state)
        }

        if oldPlan != state.plan {
            onEntitlementDidChange?()
        }
    }

    private static func deviceSecurityMessage(for error: Error) -> String {
        guard let storeError = error as? EntitlementStoreError,
              case let .keychainStatus(status) = storeError else {
            return "Secure license storage is temporarily unavailable. Try again."
        }

        switch status {
        case errSecMissingEntitlement:
            return "Secure license storage is unavailable in this build. Run a properly signed LayoutLock build."
        case errSecInteractionNotAllowed:
            return "Secure license storage is locked. Unlock your Mac and try again."
        default:
            return "Secure license storage is temporarily unavailable. Try again."
        }
    }

    private static func inactiveMessage(for proxyMessage: String?) -> String {
        // Inactive status is receipt-signed; only known proxy copy is shown verbatim.
        switch proxyMessage?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "This license is already active on another Mac.":
            return "This license is already active on another Mac. Deactivate it there before activating it here."
        case "This license is expired.":
            return "This license has expired."
        case "This license is inactive.":
            return "This license has been disabled. Contact support if you think this is a mistake."
        case "This license is not active.":
            return "This license key is invalid. Check the key and try again."
        default:
            return "This license could not be activated. Check the key and try again."
        }
    }

    private static func logDeviceSecurityFailure(_ error: Error) {
        if let storeError = error as? EntitlementStoreError,
           case let .keychainStatus(status) = storeError {
            AppLogger.entitlements.error("Device credential Keychain access failed with status \(status)")
        } else {
            AppLogger.entitlements.error("Device credential Keychain access failed")
        }
    }

    nonisolated private static func defaultAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    nonisolated private static func defaultDeviceLabel() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
