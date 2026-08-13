import AppKit
import Foundation
import XCTest
@testable import LayoutLock

final class LayoutLockSettingsTests: XCTestCase {
    func testRegisterDefaultsEnablesDisplaySuggestionsWhenPreferenceIsAbsent() {
        let userDefaults = makeUserDefaults()

        LayoutLockSettings.registerDefaults(in: userDefaults)

        XCTAssertTrue(userDefaults.bool(forKey: LayoutLockSettings.suggestRestoreOnDisplayChangeKey))
    }

    func testRegisterDefaultsPreservesExplicitlyDisabledDisplaySuggestions() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(false, forKey: LayoutLockSettings.suggestRestoreOnDisplayChangeKey)

        LayoutLockSettings.registerDefaults(in: userDefaults)

        XCTAssertFalse(userDefaults.bool(forKey: LayoutLockSettings.suggestRestoreOnDisplayChangeKey))
    }

    func testDisplayChangeSuggestionsAppearOffWithoutPro() {
        XCTAssertFalse(LayoutLockSettings.displayChangeSuggestionsAreEnabled(
            preference: true,
            isProUnlocked: false
        ))
        XCTAssertTrue(LayoutLockSettings.displayChangeSuggestionsAreEnabled(
            preference: true,
            isProUnlocked: true
        ))
        XCTAssertFalse(LayoutLockSettings.displayChangeSuggestionsAreEnabled(
            preference: false,
            isProUnlocked: true
        ))
    }

    func testRegisterDefaultsUsesSystemAppearanceWhenPreferenceIsAbsent() {
        let userDefaults = makeUserDefaults()

        LayoutLockSettings.registerDefaults(in: userDefaults)

        XCTAssertEqual(
            userDefaults.string(forKey: LayoutLockSettings.appearancePreferenceKey),
            AppearancePreference.system.rawValue
        )
    }

    func testAppearancePreferenceDefaultIsSystem() {
        XCTAssertEqual(AppearancePreference.default, .system)
    }

    func testAppearancePreferenceRawValuesAreStable() {
        XCTAssertEqual(AppearancePreference.system.rawValue, "system")
        XCTAssertEqual(AppearancePreference.light.rawValue, "light")
        XCTAssertEqual(AppearancePreference.dark.rawValue, "dark")
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
    }

    func testResolvedAppearanceFallsBackToSystemWhenPreferenceIsAbsent() {
        let userDefaults = makeUserDefaults()

        XCTAssertEqual(AppearancePreference.resolved(in: userDefaults), .system)
    }

    func testResolvedAppearanceReadsExplicitlyStoredValue() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(AppearancePreference.dark.rawValue, forKey: LayoutLockSettings.appearancePreferenceKey)

        XCTAssertEqual(AppearancePreference.resolved(in: userDefaults), .dark)
    }

    func testResolvedAppearanceFallsBackToSystemForUnknownValue() {
        let userDefaults = makeUserDefaults()
        userDefaults.set("neon", forKey: LayoutLockSettings.appearancePreferenceKey)

        XCTAssertEqual(AppearancePreference.resolved(in: userDefaults), .system)
    }

    func testAppearancePreferenceMapsToNSAppearanceName() {
        XCTAssertNil(AppearancePreference.system.nsAppearance)
        XCTAssertEqual(AppearancePreference.light.nsAppearance?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(AppearancePreference.dark.nsAppearance?.name, NSAppearance.Name.darkAqua)
    }

    func testRegisterDefaultsHidesDockIconWhenPreferenceIsAbsent() {
        let userDefaults = makeUserDefaults()

        LayoutLockSettings.registerDefaults(in: userDefaults)

        XCTAssertFalse(userDefaults.bool(forKey: LayoutLockSettings.showsDockIconKey))
    }

    func testDockActivationPolicyReflectsDockIconPreference() {
        XCTAssertEqual(LayoutLockSettings.dockActivationPolicy(showsDockIcon: false), .accessory)
        XCTAssertEqual(LayoutLockSettings.dockActivationPolicy(showsDockIcon: true), .regular)
    }

    func testResolvedDockActivationPolicyIsAccessoryByDefault() {
        let userDefaults = makeUserDefaults()
        LayoutLockSettings.registerDefaults(in: userDefaults)

        XCTAssertEqual(LayoutLockSettings.resolvedDockActivationPolicy(in: userDefaults), .accessory)
    }

    func testResolvedDockActivationPolicyIsRegularWhenEnabled() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(true, forKey: LayoutLockSettings.showsDockIconKey)

        XCTAssertEqual(LayoutLockSettings.resolvedDockActivationPolicy(in: userDefaults), .regular)
    }

    func testRegisterDefaultsLeavesBrowserAutomationDisconnected() {
        let userDefaults = makeUserDefaults()

        LayoutLockSettings.registerDefaults(in: userDefaults)

        for browser in BrowserAutomationBrowser.allCases {
            XCTAssertFalse(
                userDefaults.bool(
                    forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
                )
            )
            XCTAssertFalse(
                userDefaults.bool(
                    forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
                )
            )
            XCTAssertFalse(
                userDefaults.bool(
                    forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
                )
            )
        }
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "LayoutLockSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}

final class LayoutLockSupportTests: XCTestCase {
    func testLegalURLsUsePublishedLayoutLockPages() {
        XCTAssertEqual(LayoutLockSupport.privacyPolicyURL.absoluteString, "https://layoutlock.app/privacy")
        XCTAssertEqual(LayoutLockSupport.termsOfServiceURL.absoluteString, "https://layoutlock.app/terms")
        XCTAssertEqual(LayoutLockSupport.raycastURL.absoluteString, "https://layoutlock.app/raycast")
    }

    func testRefundEmailURLTargetsBrandedSupportAddress() throws {
        let url = try XCTUnwrap(
            LayoutLockSupport.mailtoURL(
                subject: LayoutLockSupport.refundEmailSubject,
                body: LayoutLockSupport.refundEmailBody
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "support@layoutlock.app")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "subject", value: "LayoutLock Refund Request"),
                URLQueryItem(name: "body", value: "Purchase email or Creem order ID:\n\n")
            ]
        )
    }
}
