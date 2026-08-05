import Foundation

enum OnboardingStatus: String, Equatable {
    case deferred
    case completedAuthorized
}

struct OnboardingStore {
    private static let statusKey = "LayoutLock.Onboarding.status"

    var readStatus: () -> OnboardingStatus?
    var writeStatus: (OnboardingStatus) -> Void

    init(userDefaults: UserDefaults = .standard) {
        readStatus = {
            guard let rawValue = userDefaults.string(forKey: Self.statusKey) else {
                return nil
            }

            return OnboardingStatus(rawValue: rawValue)
        }
        writeStatus = { status in
            userDefaults.set(status.rawValue, forKey: Self.statusKey)
        }
    }

    init(
        readStatus: @escaping () -> OnboardingStatus?,
        writeStatus: @escaping (OnboardingStatus) -> Void
    ) {
        self.readStatus = readStatus
        self.writeStatus = writeStatus
    }
}
