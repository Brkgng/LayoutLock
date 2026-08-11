import Foundation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus { get }
    var isEffectivelyEnabled: Bool { get }

    func prepare() throws
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

protocol LaunchAtLoginRegistration {
    var status: LaunchAtLoginServiceStatus { get }

    func register() throws
    func unregister() throws
}

struct SystemLaunchAtLoginRegistration: LaunchAtLoginRegistration {
    let service: SMAppService

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

struct LoginHelperLaunchAtLoginService: LaunchAtLoginServicing {
    static var helperBundleIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "LayoutLockLoginHelperBundleIdentifier") as? String
            ?? "com.berkergungor.layoutlock.login-helper"
    }

    private let helper: LaunchAtLoginRegistration
    private let legacyMainApp: LaunchAtLoginRegistration

    init(
        helper: LaunchAtLoginRegistration = SystemLaunchAtLoginRegistration(
            service: SMAppService.loginItem(identifier: Self.helperBundleIdentifier)
        ),
        legacyMainApp: LaunchAtLoginRegistration = SystemLaunchAtLoginRegistration(
            service: SMAppService.mainApp
        )
    ) {
        self.helper = helper
        self.legacyMainApp = legacyMainApp
    }

    var status: LaunchAtLoginServiceStatus {
        helper.status
    }

    var isEffectivelyEnabled: Bool {
        helper.status == .enabled || legacyMainApp.status == .enabled
    }

    func prepare() throws {
        if helper.status == .enabled {
            try unregisterLegacyIfNeeded()
            return
        }

        guard legacyMainApp.status == .enabled || legacyMainApp.status == .requiresApproval else {
            return
        }

        if helper.status == .notRegistered || helper.status == .notFound {
            try helper.register()
        }

        if helper.status == .enabled {
            try unregisterLegacyIfNeeded()
        }
    }

    func register() throws {
        if helper.status != .enabled {
            try helper.register()
        }

        if helper.status == .enabled {
            try unregisterLegacyIfNeeded()
        }
    }

    func unregister() throws {
        if helper.status == .enabled || helper.status == .requiresApproval {
            try helper.unregister()
        }

        try unregisterLegacyIfNeeded()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func unregisterLegacyIfNeeded() throws {
        if legacyMainApp.status == .enabled || legacyMainApp.status == .requiresApproval {
            try legacyMainApp.unregister()
        }
    }
}

struct LaunchAtLoginState: Equatable {
    let isEnabled: Bool
    let message: String?
    let requiresApproval: Bool
    let isError: Bool

    var canToggle: Bool {
        !requiresApproval
    }

    static let enabled = LaunchAtLoginState(
        isEnabled: true,
        message: nil,
        requiresApproval: false,
        isError: false
    )

    static let disabled = LaunchAtLoginState(
        isEnabled: false,
        message: nil,
        requiresApproval: false,
        isError: false
    )

    static let requiresApproval = LaunchAtLoginState(
        isEnabled: false,
        message: "Allow LayoutLock in Login Items to finish enabling launch at login.",
        requiresApproval: true,
        isError: false
    )

    static func error(_ message: String, wasEnabled: Bool) -> LaunchAtLoginState {
        LaunchAtLoginState(
            isEnabled: wasEnabled,
            message: message,
            requiresApproval: false,
            isError: true
        )
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState

    private let service: LaunchAtLoginServicing
    private var failedRequestedState: Bool?

    init(service: LaunchAtLoginServicing = LoginHelperLaunchAtLoginService()) {
        self.service = service
        do {
            try service.prepare()
            state = Self.state(for: service.status)
        } catch {
            state = .error(error.userFacingDescription, wasEnabled: service.isEffectivelyEnabled)
        }
    }

    var isEnabled: Bool {
        state.isEnabled
    }

    func refreshStatus() {
        let requestedState = failedRequestedState

        do {
            if let requestedState {
                if requestedState {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } else {
                try service.prepare()
            }

            failedRequestedState = nil
            state = Self.state(for: service.status)
        } catch {
            handleFailure(error, retrying: requestedState)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }

            failedRequestedState = nil
            try service.prepare()
            state = Self.state(for: service.status)
        } catch {
            handleFailure(error, retrying: isEnabled)
        }
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }

    private func handleFailure(_ error: Error, retrying requestedState: Bool?) {
        let refreshedState = Self.state(for: service.status)
        guard !refreshedState.requiresApproval else {
            failedRequestedState = nil
            state = refreshedState
            return
        }

        failedRequestedState = requestedState
        state = .error(
            error.userFacingDescription,
            wasEnabled: service.isEffectivelyEnabled
        )
    }

    private static func state(for serviceStatus: LaunchAtLoginServiceStatus) -> LaunchAtLoginState {
        switch serviceStatus {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .disabled
        }
    }
}
