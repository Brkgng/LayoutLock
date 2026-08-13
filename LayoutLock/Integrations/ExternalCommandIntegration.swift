import AppKit
import Foundation

enum LayoutLockExternalCommand: Equatable {
    case restore(UUID)
    case capture(name: String?)
}

enum LayoutLockExternalCommandParser {
    static func parse(_ url: URL) -> LayoutLockExternalCommand? {
        parse(url, expectedScheme: configuredScheme)
    }

    static func parse(_ url: URL, expectedScheme: String) -> LayoutLockExternalCommand? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == expectedScheme.lowercased(),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty,
              let command = components.host?.lowercased(),
              let queryItems = validatedQueryItems(from: components) else {
            return nil
        }

        switch command {
        case "restore":
            guard queryItems.count == 1,
                  queryItems[0].name == "id",
                  let value = queryItems[0].value,
                  let id = UUID(uuidString: value) else {
                return nil
            }
            return .restore(id)
        case "capture":
            guard queryItems.count <= 1 else {
                return nil
            }
            guard let queryItem = queryItems.first else {
                return .capture(name: nil)
            }
            guard queryItem.name == "name",
                  let value = queryItem.value else {
                return nil
            }
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.count <= 200,
                  name.rangeOfCharacter(from: .controlCharacters) == nil else {
                return nil
            }
            return .capture(name: name)
        default:
            return nil
        }
    }

    static var configuredScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "LayoutLockURLScheme") as? String ?? "layoutlock"
    }

    private static func validatedQueryItems(from components: URLComponents) -> [URLQueryItem]? {
        guard components.percentEncodedQuery == nil || components.queryItems != nil else {
            return nil
        }
        return components.queryItems ?? []
    }
}

@MainActor
final class ExternalCommandCoordinator {
    private let permissionRouter: PermissionInterventionRouter
    private let snapshotMenuController: SnapshotMenuController
    private let presentationState: AppLaunchPresentationState
    private let externalIntegrationWasUsed: () -> Void
    private weak var statusNoticePresenter: StatusNoticePresenting?

    init(
        permissionRouter: PermissionInterventionRouter,
        snapshotMenuController: SnapshotMenuController,
        presentationState: AppLaunchPresentationState,
        statusNoticePresenter: StatusNoticePresenting? = nil,
        externalIntegrationWasUsed: @escaping () -> Void = {}
    ) {
        self.permissionRouter = permissionRouter
        self.snapshotMenuController = snapshotMenuController
        self.presentationState = presentationState
        self.statusNoticePresenter = statusNoticePresenter
        self.externalIntegrationWasUsed = externalIntegrationWasUsed
    }

    func handle(_ url: URL) {
        guard let command = LayoutLockExternalCommandParser.parse(url) else {
            AppLogger.app.warning("Rejected malformed external command URL")
            return
        }

        presentationState.suppressInitialPresentation()
        externalIntegrationWasUsed()
        let actionKind: PrivilegedActionKind
        switch command {
        case .restore:
            actionKind = .restoreLayout
        case .capture:
            actionKind = .saveLayout
        }

        guard permissionRouter.requestAuthorization(
            kind: actionKind,
            source: .externalIntegration
        ) else {
            return
        }

        guard !snapshotMenuController.isOperating else {
            showNotice("LayoutLock is already saving or restoring a layout.")
            return
        }

        switch command {
        case let .restore(id):
            guard snapshotMenuController.snapshotSummaries.contains(where: { $0.id == id }) else {
                showNotice("That layout is no longer available. Refresh Raycast and try again.")
                return
            }
            guard snapshotMenuController.restoreSnapshot(id: id) != nil else {
                showCurrentStatus(fallback: "LayoutLock could not start the restore.")
                return
            }
        case let .capture(name):
            let resolvedName = name ?? snapshotMenuController.suggestedSnapshotNameForCapture()
            guard let resolvedName else {
                showCurrentStatus(fallback: "LayoutLock could not start the save.")
                return
            }
            guard snapshotMenuController.captureCurrentSnapshot(named: resolvedName) != nil else {
                showCurrentStatus(fallback: "LayoutLock could not start the save.")
                return
            }
        }
    }

    private func showCurrentStatus(fallback: String) {
        showNotice(snapshotMenuController.status?.message ?? fallback)
    }

    private func showNotice(_ message: String) {
        statusNoticePresenter?.showStatusNotice(message: message, duration: 6)
    }
}

@MainActor
final class RaycastRecommendationController: ObservableObject {
    @Published private(set) var shouldShow = false

    private enum Key {
        static let lastLaunchedBuild = "integrations.raycast.lastLaunchedBuild"
        static let recommendationPending = "integrations.raycast.recommendationV1.pending"
        static let recommendationHandled = "integrations.raycast.recommendationV1.handled"
    }

    private let userDefaults: UserDefaults
    private let isRaycastInstalled: () -> Bool

    init(
        userDefaults: UserDefaults = .standard,
        currentBuild: String? = nil,
        hadPriorInstallation: Bool = OnboardingStore().readStatus() != nil,
        isRaycastInstalled: @escaping () -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos") != nil
        }
    ) {
        self.userDefaults = userDefaults
        self.isRaycastInstalled = isRaycastInstalled
        let currentBuild = currentBuild ?? Self.currentBuild

        let previousBuild = userDefaults.string(forKey: Key.lastLaunchedBuild)
        let isExistingInstallation = previousBuild.map { $0 != currentBuild } ?? hadPriorInstallation
        if isExistingInstallation,
           !userDefaults.bool(forKey: Key.recommendationHandled) {
            userDefaults.set(true, forKey: Key.recommendationPending)
        }
        userDefaults.set(currentBuild, forKey: Key.lastLaunchedBuild)

        refreshAvailability()
    }

    func refreshAvailability() {
        shouldShow = userDefaults.bool(forKey: Key.recommendationPending)
            && !userDefaults.bool(forKey: Key.recommendationHandled)
            && isRaycastInstalled()
    }

    func extensionSetupRequested() {
        markHandled()
    }

    func dismiss() {
        markHandled()
    }

    func externalIntegrationWasUsed() {
        markHandled()
    }

    private func markHandled() {
        userDefaults.set(true, forKey: Key.recommendationHandled)
        userDefaults.set(false, forKey: Key.recommendationPending)
        shouldShow = false
    }

    private static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
    }
}
