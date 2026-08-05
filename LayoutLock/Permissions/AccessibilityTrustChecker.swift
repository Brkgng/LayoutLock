import ApplicationServices

struct AccessibilityTrustChecker {
    private let trustCheck: () -> Bool

    init(trustCheck: @escaping () -> Bool = AccessibilityTrustChecker.defaultTrustCheck) {
        self.trustCheck = trustCheck
    }

    func isTrusted() -> Bool {
        trustCheck()
    }

    private static func defaultTrustCheck() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
