import Foundation
import AppKit

@MainActor
final class PermissionCoordinator: ObservableObject {
    enum RefreshTrigger {
        case launch
        case manualCheckAgain
        case appDidBecomeActive
        case privilegedAction
    }

    @Published private(set) var authorizationState: AccessibilityAuthorizationState

    private let trustChecker: AccessibilityTrustChecker
    private let accessibilitySettingsOpener: @MainActor () -> Void
    private var activationObserver: NSObjectProtocol?

    init(
        trustChecker: AccessibilityTrustChecker = AccessibilityTrustChecker(),
        accessibilitySettingsOpener: @escaping @MainActor () -> Void = PermissionCoordinator.openSystemAccessibilitySettings
    ) {
        self.trustChecker = trustChecker
        self.accessibilitySettingsOpener = accessibilitySettingsOpener
        authorizationState = trustChecker.isTrusted() ? .authorized : .unauthorized
        startObservingAppActivation()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    var shouldShowLimitedMode: Bool {
        authorizationState == .unauthorized
    }

    @discardableResult
    func refreshTrust(trigger _: RefreshTrigger) -> AccessibilityAuthorizationState {
        let refreshedState: AccessibilityAuthorizationState = trustChecker.isTrusted() ? .authorized : .unauthorized
        if refreshedState != authorizationState {
            authorizationState = refreshedState
        }

        return authorizationState
    }

    func prepareForPrivilegedAction() -> Bool {
        let authorizationState = refreshTrust(trigger: .privilegedAction)
        guard authorizationState == .authorized else {
            openAccessibilitySettings()
            return false
        }

        return true
    }

    func openAccessibilitySettings() {
        accessibilitySettingsOpener()
    }

    static func openSystemAccessibilitySettings() {
        if let privacyPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           NSWorkspace.shared.open(privacyPaneURL) {
            return
        }

        let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(systemSettingsURL)
    }

    private func startObservingAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTrust(trigger: .appDidBecomeActive)
            }
        }
    }
}
