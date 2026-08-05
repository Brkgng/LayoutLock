import AppKit

enum AppLaunchMode: Equatable {
    static let loginItemArgument = "--layoutlock-login-item"

    case foreground
    case loginItem

    init(arguments: [String]) {
        self = arguments.contains(Self.loginItemArgument) ? .loginItem : .foreground
    }
}

enum AutomaticOnboardingPresentationPolicy {
    static func startIfAllowed(
        for launchMode: AppLaunchMode,
        start: () -> Bool
    ) -> Bool {
        guard launchMode == .foreground else {
            return false
        }

        return start()
    }
}

enum DashboardReopenPolicy {
    static func shouldAllowNormalReopen(focusedExistingWindow: Bool) -> Bool {
        !focusedExistingWindow
    }
}

@MainActor
final class DashboardWindowPresentationCoordinator {
    struct Actions {
        let activateApplication: @MainActor () -> Void
        let showWindow: @MainActor (NSWindow) -> Void
        let hideWindow: @MainActor (NSWindow) -> Void

        static let live = Actions(
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            },
            showWindow: { window in
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            },
            hideWindow: { window in
                window.orderOut(nil)
            }
        )
    }

    private let launchMode: AppLaunchMode
    private let actions: Actions
    private(set) var hasPresentedInitialWindow = false

    init(
        launchMode: AppLaunchMode,
        actions: Actions = .live
    ) {
        self.launchMode = launchMode
        self.actions = actions
    }

    func presentInitialWindow(_ window: NSWindow) {
        guard !hasPresentedInitialWindow else {
            return
        }

        hasPresentedInitialWindow = true
        switch launchMode {
        case .foreground:
            actions.activateApplication()
            actions.showWindow(window)
        case .loginItem:
            actions.hideWindow(window)
        }
    }
}
