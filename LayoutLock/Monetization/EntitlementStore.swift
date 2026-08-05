import Foundation
import Security

enum EntitlementStoreError: LocalizedError {
    case licenseKeyEncodingFailed
    case licenseKeyDecodingFailed
    case deviceCredentialDecodingFailed
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .licenseKeyEncodingFailed:
            return "The license key could not be prepared for secure storage."
        case .licenseKeyDecodingFailed:
            return "The stored license key could not be read."
        case .deviceCredentialDecodingFailed:
            return "The stored device credential could not be read."
        case let .keychainStatus(status):
            return "The license key could not be stored securely. Keychain status: \(status)."
        }
    }
}

protocol LicenseKeyStoring {
    func loadLicenseKey() throws -> String?
    func saveLicenseKey(_ licenseKey: String) throws
    func deleteLicenseKey() throws
}

protocol DeviceCredentialStoring {
    func loadOrCreateCredential() throws -> String
    func deleteCredential() throws
}

struct KeychainLicenseKeyStore: LicenseKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.berkergungor.layoutlock.license",
        account: String = "layoutlock-pro-license"
    ) {
        self.service = service
        self.account = account
    }

    func loadLicenseKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EntitlementStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let licenseKey = String(data: data, encoding: .utf8) else {
            throw EntitlementStoreError.licenseKeyDecodingFailed
        }

        return licenseKey
    }

    func saveLicenseKey(_ licenseKey: String) throws {
        guard let data = licenseKey.data(using: .utf8) else {
            throw EntitlementStoreError.licenseKeyEncodingFailed
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw EntitlementStoreError.keychainStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw EntitlementStoreError.keychainStatus(status)
        }
    }

    func deleteLicenseKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EntitlementStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

struct KeychainDeviceCredentialStore: DeviceCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.berkergungor.layoutlock.device",
        account: String = "layoutlock-device-credential"
    ) {
        self.service = service
        self.account = account
    }

    func loadOrCreateCredential() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let loadStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if loadStatus == errSecSuccess,
           let data = item as? Data,
           let credential = String(data: data, encoding: .utf8) {
            return credential
        }

        guard loadStatus == errSecItemNotFound else {
            throw EntitlementStoreError.keychainStatus(loadStatus)
        }

        let credential = generateCredential()
        try save(credential)
        return credential
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EntitlementStoreError.keychainStatus(status)
        }
    }

    private func save(_ credential: String) throws {
        guard let data = credential.data(using: .utf8) else {
            throw EntitlementStoreError.deviceCredentialDecodingFailed
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EntitlementStoreError.keychainStatus(status)
        }
    }

    private func generateCredential() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard result == errSecSuccess else {
            return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

struct EntitlementStore {
    private let userDefaults: UserDefaults
    private let licenseKeyStore: LicenseKeyStoring
    private let deviceCredentialStore: DeviceCredentialStoring
    private let stateKey: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        userDefaults: UserDefaults = .standard,
        licenseKeyStore: LicenseKeyStoring = KeychainLicenseKeyStore(),
        deviceCredentialStore: DeviceCredentialStoring = KeychainDeviceCredentialStore(),
        stateKey: String = "LayoutLockProEntitlementState"
    ) {
        self.userDefaults = userDefaults
        self.licenseKeyStore = licenseKeyStore
        self.deviceCredentialStore = deviceCredentialStore
        self.stateKey = stateKey
    }

    func loadState() -> EntitlementState {
        guard let data = userDefaults.data(forKey: stateKey),
              let state = try? decoder.decode(EntitlementState.self, from: data) else {
            return .free
        }

        return state
    }

    func saveState(_ state: EntitlementState) {
        guard let data = try? encoder.encode(state) else {
            return
        }

        userDefaults.set(data, forKey: stateKey)
    }

    func loadLicenseKey() throws -> String? {
        try licenseKeyStore.loadLicenseKey()
    }

    func saveLicenseKey(_ licenseKey: String) throws {
        try licenseKeyStore.saveLicenseKey(licenseKey)
    }

    func deleteLicenseKey() throws {
        try licenseKeyStore.deleteLicenseKey()
    }

    func loadDeviceCredential() throws -> String {
        try deviceCredentialStore.loadOrCreateCredential()
    }

    func reset() {
        userDefaults.removeObject(forKey: stateKey)
        try? deleteLicenseKey()
    }
}
