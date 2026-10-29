import Combine
import Foundation
import Sparkle

struct AvailableAppUpdate: Equatable {
    let buildVersion: String
    let displayVersion: String

    var actionTitle: String {
        "Update Available"
    }
}

enum AppUpdateUserChoice {
    case install
    case dismiss
    case skip
}

struct AppUpdateLaunchCheck {
    private(set) var hasChecked = false

    mutating func perform(check: () -> Void) {
        guard !hasChecked else {
            return
        }

        hasChecked = true
        check()
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var availableUpdate: AvailableAppUpdate?
    @Published private(set) var canCheckForUpdates = false

    let presentationModel: AppUpdatePresentationModel

    private let userDriver: AppUpdateUserDriver
    private var updater: SPUUpdater!
    private var launchCheck = AppUpdateLaunchCheck()

    init(startingUpdater: Bool = true) {
        let presentationModel = AppUpdatePresentationModel()
        let userDriver = AppUpdateUserDriver(presentationModel: presentationModel)
        self.presentationModel = presentationModel
        self.userDriver = userDriver
        super.init()

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )
        self.updater = updater

        userDriver.retryHandler = { [weak self] in
            self?.retryUpdateCheck()
        }

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        guard startingUpdater else {
            return
        }

        enableAutomaticUpdateChecks()

        do {
            try updater.start()
            launchCheck.perform {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            recordFailure(error)
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            return
        }

        updater.checkForUpdates()
    }

    func enableAutomaticUpdateChecks() {
        updater.automaticallyChecksForUpdates = true
    }

    var updaterAutomaticallyChecksForUpdates: Bool {
        updater.automaticallyChecksForUpdates
    }

    var actionTitle: String {
        availableUpdate?.actionTitle ?? "Check for Updates"
    }

#if DEBUG
    func feedURLString(for _: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["LAYOUTLOCK_UPDATE_FEED_URL"].nonEmptyValue
    }
#endif

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        recordAvailableUpdate(
            buildVersion: item.versionString,
            displayVersion: item.displayVersionString
        )
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        recordNoAvailableUpdate()
    }

    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        switch choice {
        case .install:
            recordUserChoice(.install)
        case .dismiss:
            recordUserChoice(.dismiss)
        case .skip:
            recordUserChoice(.skip)
        @unknown default:
            break
        }
    }

    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != SUSparkleErrorDomain
                || (nsError.code != SUError.noUpdateError.rawValue
                    && nsError.code != SUError.installationCanceledError.rawValue) else {
            return
        }

        recordFailure(error)
    }

    func recordAvailableUpdate(buildVersion: String, displayVersion: String) {
        availableUpdate = AvailableAppUpdate(
            buildVersion: buildVersion,
            displayVersion: displayVersion
        )
    }

    func recordNoAvailableUpdate() {
        availableUpdate = nil
    }

    func recordUserChoice(_ choice: AppUpdateUserChoice) {
        if choice == .skip {
            availableUpdate = nil
        }
    }

    func recordFailure(_ error: Error) {
        AppLogger.updates.error("Sparkle update failed: \(error.localizedDescription)")
    }

    private func retryUpdateCheck() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<10 {
                if updater.canCheckForUpdates {
                    updater.checkForUpdates()
                    return
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
