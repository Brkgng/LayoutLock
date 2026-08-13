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
        presentationState: AppLaunchPresentationState? = nil,
        start: () -> Bool
    ) -> Bool {
        guard launchMode == .foreground,
              presentationState?.suppressesInitialPresentation != true else {
            return false
        }

        return start()
    }
}

final class AppLaunchPresentationState {
    private(set) var suppressesInitialPresentation = false

    func suppressInitialPresentation() {
        suppressesInitialPresentation = true
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
    private let presentationState: AppLaunchPresentationState
    private let actions: Actions
    private(set) var hasPresentedInitialWindow = false

    init(
        launchMode: AppLaunchMode,
        presentationState: AppLaunchPresentationState = AppLaunchPresentationState(),
        actions: Actions = .live
    ) {
        self.launchMode = launchMode
        self.presentationState = presentationState
        self.actions = actions
    }

    func presentInitialWindow(_ window: NSWindow) {
        guard !hasPresentedInitialWindow else {
            return
        }

        hasPresentedInitialWindow = true
        switch (launchMode, presentationState.suppressesInitialPresentation) {
        case (.foreground, false):
            actions.activateApplication()
            actions.showWindow(window)
        case (.foreground, true), (.loginItem, _):
            actions.hideWindow(window)
        }
    }
}
