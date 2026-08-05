import Foundation

enum LayoutLockPlan: String, Codable, Equatable {
    case free
    case pro
}

enum EntitlementValidationStatus: String, Codable, Equatable {
    case free
    case active
    case inactive
}

struct EntitlementState: Codable, Equatable {
    var status: EntitlementValidationStatus
    var lastValidatedAt: Date? = nil
    var customerID: String? = nil
    var productID: String? = nil
    var instanceID: String? = nil
    var statusMessage: String? = nil
    var receipt: String? = nil

    static let free = EntitlementState(
        status: .free,
        lastValidatedAt: nil,
        customerID: nil,
        productID: nil,
        instanceID: nil,
        statusMessage: nil,
        receipt: nil
    )

    var plan: LayoutLockPlan {
        status == .active ? .pro : .free
    }

    var isProUnlocked: Bool {
        plan == .pro
    }
}

struct PlanStatusPresentation: Equatable {
    let title: String
    let detail: String
    let menuTitle: String
    let systemImageName: String
    let isLimitReached: Bool
    let isProUnlocked: Bool

    init(
        isProUnlocked: Bool,
        layoutCount: Int,
        freeLayoutLimit: Int = LayoutLockProConfiguration.freeLayoutLimit
    ) {
        if isProUnlocked {
            title = "Pro active"
            detail = "All Pro features unlocked"
            menuTitle = "Pro active"
            systemImageName = "checkmark.seal.fill"
            self.isLimitReached = false
            self.isProUnlocked = true
            return
        }

        let visibleLayoutCount = max(0, layoutCount)
        systemImageName = "sparkles"
        self.isProUnlocked = false
        if visibleLayoutCount >= freeLayoutLimit {
            title = "Layout limit reached"
            detail = "Upgrade to Pro to save more layouts"
            menuTitle = "Free plan · Limit reached"
            isLimitReached = true
        } else {
            title = "Free plan"
            detail = "\(visibleLayoutCount)/\(freeLayoutLimit) layouts used"
            menuTitle = "Free plan · \(visibleLayoutCount)/\(freeLayoutLimit) layouts"
            isLimitReached = false
        }
    }
}

enum PlanStatusAction: Equatable {
    case purchase(URL)
    case proSettings

    var actionTitle: String {
        switch self {
        case .purchase:
            return LayoutLockProConfiguration.current.purchaseActionTitle
        case .proSettings:
            return "Open Pro Settings"
        }
    }
}

enum PlanStatusActionResolver {
    static func action(
        for presentation: PlanStatusPresentation,
        purchaseURL: URL?
    ) -> PlanStatusAction {
        guard presentation.isLimitReached, let purchaseURL else {
            return .proSettings
        }

        return .purchase(purchaseURL)
    }

    static func upgradeAction(purchaseURL: URL?) -> PlanStatusAction {
        guard let purchaseURL else {
            return .proSettings
        }

        return .purchase(purchaseURL)
    }
}

enum ProFeature: String, CaseIterable, Identifiable {
    case unlimitedLayouts
    case displayChangeSuggestions
    case customRestoreOrder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimitedLayouts:
            return "Unlimited Layouts"
        case .displayChangeSuggestions:
            return "Display-Change Suggestions"
        case .customRestoreOrder:
            return "Custom Restore Order"
        }
    }

    var requiredPlanMessage: String {
        switch self {
        case .unlimitedLayouts:
            return "Saving more than 3 layouts is a Pro feature."
        case .displayChangeSuggestions:
            return "Display-change suggestions are a Pro feature."
        case .customRestoreOrder:
            return "Customizing window restore order is a Pro feature."
        }
    }
}

@MainActor
protocol EntitlementProviding: AnyObject {
    var entitlementState: EntitlementState { get }
    var isProUnlocked: Bool { get }
}

extension EntitlementProviding {
    var isProUnlocked: Bool {
        entitlementState.isProUnlocked
    }
}

final class StaticEntitlementProvider: EntitlementProviding {
    nonisolated let entitlementState: EntitlementState

    nonisolated init(isProUnlocked: Bool) {
        entitlementState = isProUnlocked
            ? EntitlementState(
                status: .active,
                lastValidatedAt: nil,
                customerID: nil,
                productID: nil,
                instanceID: nil,
                statusMessage: nil,
                receipt: nil
            )
            : .free
    }
}

enum LayoutLockPaymentsEnvironment: String, Equatable {
    case test
    case live
}

struct LayoutLockProConfigurationValues: Equatable {
    let purchaseURL: URL?
    let proxyBaseURL: URL?
    let productID: String?
    let environment: LayoutLockPaymentsEnvironment?

    init(infoDictionary: [String: Any]) {
        purchaseURL = Self.configuredURL(
            infoDictionary[LayoutLockProConfiguration.purchaseURLKey]
        )
        proxyBaseURL = Self.configuredURL(
            infoDictionary[LayoutLockProConfiguration.proxyBaseURLKey]
        )
        productID = Self.configuredIdentifier(
            infoDictionary[LayoutLockProConfiguration.productIDKey]
        )
        environment = (infoDictionary[LayoutLockProConfiguration.environmentKey] as? String)
            .flatMap(LayoutLockPaymentsEnvironment.init(rawValue:))
    }

    var purchaseActionTitle: String {
        environment == .test ? "Open Test Checkout" : "Buy LayoutLock Pro"
    }

    var testModeMessage: String? {
        environment == .test
            ? "Test payments are enabled. No real charge will be made."
            : nil
    }

    private static func configuredURL(_ value: Any?) -> URL? {
        guard let rawValue = value as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("example.com"),
              !trimmed.localizedCaseInsensitiveContains("placeholder"),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https" else {
            return nil
        }

        return url
    }

    private static func configuredIdentifier(_ value: Any?) -> String? {
        guard let rawValue = value as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("placeholder") else {
            return nil
        }

        return trimmed
    }
}

enum LayoutLockProConfiguration {
    static let freeLayoutLimit = 3

    static let purchaseURLKey = "LayoutLockProPurchaseURL"
    static let proxyBaseURLKey = "LayoutLockLicenseProxyBaseURL"
    static let productIDKey = "LayoutLockCreemProductID"
    static let environmentKey = "LayoutLockPaymentsEnvironment"

    static var current: LayoutLockProConfigurationValues {
        LayoutLockProConfigurationValues(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var purchaseURL: URL? {
        current.purchaseURL
    }

    static var proxyBaseURL: URL? {
        current.proxyBaseURL
    }

    static var productID: String? {
        current.productID
    }

    static var environment: LayoutLockPaymentsEnvironment? {
        current.environment
    }
}
