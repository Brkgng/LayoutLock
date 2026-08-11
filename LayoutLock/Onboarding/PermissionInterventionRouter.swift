import Foundation

enum PrivilegedActionKind: Equatable {
    case saveLayout
    case restoreLayout
}

enum PrivilegedActionSource: Equatable {
    case dashboard
    case displayChange
    case menuBar
    case hotkey
    case settings
    case externalIntegration
}

enum DashboardWindowVisibility: Equatable {
    case visibleOnActiveSpace
    case notVisible

    static func from(
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool
    ) -> DashboardWindowVisibility {
        isVisible && !isMiniaturized && isOnActiveSpace ? .visibleOnActiveSpace : .notVisible
    }
}

struct PassivePermissionNotice: Equatable {
    let message: String
    let duration: TimeInterval
}

@MainActor
protocol StatusNoticePresenting: AnyObject {
    func showStatusNotice(message: String, duration: TimeInterval)
    func hideStatusNotice()
}

@MainActor
final class PermissionInterventionRouter: ObservableObject {
    private static let restorePermissionMessage = "Accessibility access is required to restore layouts. Open LayoutLock to enable access."
    private static let savePermissionMessage = "Accessibility access is required to save layouts. Open LayoutLock to enable access."
    private static let passivePermissionDuration: TimeInterval = 6

    @Published private(set) var showsDashboardPermissionEducation = false
    @Published private(set) var onboardingPresentationRequestID: UUID?
    @Published private(set) var dashboardWindowVisibility: DashboardWindowVisibility = .notVisible
    @Published private(set) var lastPassivePermissionNotice: PassivePermissionNotice?

    private let permissionCoordinator: PermissionCoordinator
    private weak var statusNoticePresenter: StatusNoticePresenting?

    init(
        permissionCoordinator: PermissionCoordinator,
        statusNoticePresenter: StatusNoticePresenting? = nil
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.statusNoticePresenter = statusNoticePresenter
    }

    @discardableResult
    func requestAuthorization(
        kind: PrivilegedActionKind,
        source: PrivilegedActionSource
    ) -> Bool {
        let state = permissionCoordinator.refreshTrust(trigger: .privilegedAction)
        guard state != .authorized else {
            clearDashboardPermissionEducation()
            clearPassivePermissionNotice()
            return true
        }

        switch source {
        case .dashboard:
            showsDashboardPermissionEducation = true
            onboardingPresentationRequestID = nil
            clearPassivePermissionNotice()
        case .menuBar:
            showsDashboardPermissionEducation = false
            clearPassivePermissionNotice()
            onboardingPresentationRequestID = UUID()
        case .displayChange, .hotkey:
            showPassivePermissionNoticeIfNeeded(kind: kind)
        case .settings:
            permissionCoordinator.openAccessibilitySettings()
        case .externalIntegration:
            showPassivePermissionNoticeIfNeeded(kind: kind)
            permissionCoordinator.openAccessibilitySettings()
        }

        return false
    }

    func openAccessibilitySettings() {
        permissionCoordinator.openAccessibilitySettings()
    }

    func dismissDashboardPermissionEducation() {
        clearDashboardPermissionEducation()
    }

    func clearDashboardPermissionEducation() {
        guard showsDashboardPermissionEducation else {
            return
        }

        showsDashboardPermissionEducation = false
    }

    func clearDashboardPermissionEducationForContextChange() {
        clearDashboardPermissionEducation()
    }

    func updateDashboardWindowVisibility(_ visibility: DashboardWindowVisibility) {
        guard visibility != dashboardWindowVisibility else {
            return
        }

        dashboardWindowVisibility = visibility
    }

    private func showPassivePermissionNoticeIfNeeded(kind: PrivilegedActionKind) {
        guard !(showsDashboardPermissionEducation && dashboardWindowVisibility == .visibleOnActiveSpace) else {
            clearPassivePermissionNotice()
            return
        }

        let notice = PassivePermissionNotice(
            message: kind == .restoreLayout ? Self.restorePermissionMessage : Self.savePermissionMessage,
            duration: Self.passivePermissionDuration
        )
        lastPassivePermissionNotice = notice
        statusNoticePresenter?.showStatusNotice(message: notice.message, duration: notice.duration)
    }

    private func clearPassivePermissionNotice() {
        guard lastPassivePermissionNotice != nil else {
            return
        }

        lastPassivePermissionNotice = nil
        statusNoticePresenter?.hideStatusNotice()
    }
}
