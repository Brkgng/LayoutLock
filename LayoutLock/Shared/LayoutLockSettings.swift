import AppKit
import Foundation

enum LayoutLockSettings {
    static let suggestRestoreOnDisplayChangeKey = "suggestRestoreOnDisplayChange"
    static let appearancePreferenceKey = "appearancePreference"
    static let showsDockIconKey = "showsDockIcon"

    static func browserAutomationEnabledKey(
        for browser: BrowserAutomationBrowser
    ) -> String {
        "browserAutomation.\(browser.rawValue).enabled"
    }

    static func browserAutomationConnectedBeforeKey(
        for browser: BrowserAutomationBrowser
    ) -> String {
        "browserAutomation.\(browser.rawValue).connectedBefore"
    }

    static func browserAutomationPermissionDeniedKey(
        for browser: BrowserAutomationBrowser
    ) -> String {
        "browserAutomation.\(browser.rawValue).permissionDenied"
    }

    static func registerDefaults(in userDefaults: UserDefaults = .standard) {
        var defaults: [String: Any] = [
            suggestRestoreOnDisplayChangeKey: true,
            appearancePreferenceKey: AppearancePreference.default.rawValue,
            showsDockIconKey: false
        ]
        for browser in BrowserAutomationBrowser.allCases {
            defaults[browserAutomationEnabledKey(for: browser)] = false
            defaults[browserAutomationConnectedBeforeKey(for: browser)] = false
            defaults[browserAutomationPermissionDeniedKey(for: browser)] = false
        }
        userDefaults.register(defaults: defaults)
    }

    static func displayChangeSuggestionsAreEnabled(
        preference: Bool,
        isProUnlocked: Bool
    ) -> Bool {
        preference && isProUnlocked
    }

    static func dockActivationPolicy(showsDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showsDockIcon ? .regular : .accessory
    }

    static func resolvedDockActivationPolicy(in userDefaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        dockActivationPolicy(showsDockIcon: userDefaults.bool(forKey: showsDockIconKey))
    }
}

enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let `default` = AppearancePreference.system

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    static func resolved(in userDefaults: UserDefaults = .standard) -> AppearancePreference {
        guard let rawValue = userDefaults.string(forKey: LayoutLockSettings.appearancePreferenceKey),
              let preference = AppearancePreference(rawValue: rawValue) else {
            return .default
        }

        return preference
    }
}
