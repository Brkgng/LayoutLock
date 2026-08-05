import AppKit
import Foundation

struct DisplayRestoreSuggestionOption: Equatable {
    let snapshotID: UUID
    let snapshotName: String
}

@MainActor
protocol DisplayRestoreSuggestionPresenting: AnyObject {
    var isDisplayRestoreSuggestionVisible: Bool { get }

    func showDisplayRestoreSuggestion(
        snapshotName: String,
        restore: @escaping @MainActor () -> Void
    )
    func showDisplayRestoreSuggestionChooser(
        options: [DisplayRestoreSuggestionOption],
        restore: @escaping @MainActor (UUID) -> Void
    )
    func hideDisplayRestoreSuggestion()
}

@MainActor
final class DisplayChangeRestoreController {
    typealias SnapshotProvider = () throws -> [Snapshot]
    typealias DisplayStateProvider = () -> DisplayState

    private let notificationCenter: NotificationCenter
    private let snapshotProvider: SnapshotProvider
    private let displayStateProvider: DisplayStateProvider
    private let isSuggestionEnabled: () -> Bool
    private let isRestoreAuthorized: () -> Bool
    private let isOperating: () -> Bool
    private let restore: (UUID) -> Void
    private weak var suggestionPresenter: DisplayRestoreSuggestionPresenting?
    private let matcher: DisplayConfigurationMatcher
    private let debounceInterval: TimeInterval

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var lastDisplayTopologySignature: DisplayTopologySignature?
    private var suggestedDisplaySignature: DisplayConfigurationSignature?

    init(
        notificationCenter: NotificationCenter = .default,
        snapshotProvider: @escaping SnapshotProvider,
        displayStateProvider: @escaping DisplayStateProvider = DisplayResolver().captureDisplayState,
        isSuggestionEnabled: @escaping () -> Bool,
        isRestoreAuthorized: @escaping () -> Bool,
        isOperating: @escaping () -> Bool,
        suggestionPresenter: DisplayRestoreSuggestionPresenting,
        matcher: DisplayConfigurationMatcher = DisplayConfigurationMatcher(),
        debounceInterval: TimeInterval = 2,
        restore: @escaping (UUID) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.snapshotProvider = snapshotProvider
        self.displayStateProvider = displayStateProvider
        self.isSuggestionEnabled = isSuggestionEnabled
        self.isRestoreAuthorized = isRestoreAuthorized
        self.isOperating = isOperating
        self.suggestionPresenter = suggestionPresenter
        self.matcher = matcher
        self.debounceInterval = debounceInterval
        self.restore = restore
    }

    convenience init(
        snapshotStore: SnapshotStore,
        permissionCoordinator: PermissionCoordinator,
        snapshotMenuController: SnapshotMenuController,
        suggestionPresenter: DisplayRestoreSuggestionPresenting,
        entitlementProvider: EntitlementProviding = StaticEntitlementProvider(isProUnlocked: true),
        restore: @escaping (UUID) -> Void
    ) {
        self.init(
            snapshotProvider: {
                try snapshotStore.listSummaries().map { summary in
                    try snapshotStore.loadSnapshot(id: summary.id)
                }
            },
            isSuggestionEnabled: {
                LayoutLockSettings.displayChangeSuggestionsAreEnabled(
                    preference: UserDefaults.standard.bool(
                        forKey: LayoutLockSettings.suggestRestoreOnDisplayChangeKey
                    ),
                    isProUnlocked: entitlementProvider.isProUnlocked
                )
            },
            isRestoreAuthorized: {
                permissionCoordinator.refreshTrust(trigger: .privilegedAction) == .authorized
            },
            isOperating: {
                snapshotMenuController.isOperating
            },
            suggestionPresenter: suggestionPresenter,
            restore: restore
        )
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        debounceTask?.cancel()
    }

    func start() {
        guard observer == nil else {
            return
        }

        lastDisplayTopologySignature = DisplayTopologySignature(displayState: displayStateProvider())
        observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.displayParametersDidChange()
            }
        }
    }

    func displayParametersDidChange() {
        if suggestionPresenter?.isDisplayRestoreSuggestionVisible == true {
            let currentSignature = DisplayConfigurationSignature(displayState: displayStateProvider())
            if let suggestedDisplaySignature, currentSignature != suggestedDisplaySignature {
                suggestionPresenter?.hideDisplayRestoreSuggestion()
                self.suggestedDisplaySignature = nil
            }
        } else {
            suggestedDisplaySignature = nil
        }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if debounceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            } else {
                await Task.yield()
            }

            guard !Task.isCancelled else {
                return
            }

            evaluateDisplayChange()
        }
    }

    private func evaluateDisplayChange() {
        let currentDisplayState = displayStateProvider()
        let currentSignature = DisplayConfigurationSignature(displayState: currentDisplayState)
        let currentTopologySignature = DisplayTopologySignature(displayState: currentDisplayState)

        guard currentTopologySignature != lastDisplayTopologySignature else {
            AppLogger.displays.debug("Ignoring display-change notification because display topology is unchanged.")
            return
        }
        lastDisplayTopologySignature = currentTopologySignature

        guard isSuggestionEnabled() else {
            AppLogger.displays.debug("Ignoring display-change restore suggestion because the setting is disabled.")
            return
        }

        guard isRestoreAuthorized() else {
            AppLogger.displays.debug("Ignoring display-change restore suggestion because Accessibility access is unavailable.")
            return
        }

        guard !isOperating() else {
            AppLogger.displays.debug("Ignoring display-change restore suggestion because another layout operation is active.")
            return
        }

        let snapshots: [Snapshot]
        do {
            snapshots = try snapshotProvider()
        } catch {
            AppLogger.displays.error("Failed to load snapshots for display-change matching: \(error.localizedDescription)")
            return
        }

        let matches = matcher.matches(
            among: snapshots,
            currentDisplayState: currentDisplayState
        )

        guard !matches.isEmpty else {
            AppLogger.displays.debug("No saved layout matched the current display configuration.")
            return
        }

        suggestedDisplaySignature = currentSignature

        if matches.count == 1,
           let match = matches.first {
            suggestionPresenter?.showDisplayRestoreSuggestion(
                snapshotName: match.snapshotName
            ) { [weak self, restore] in
                self?.suggestedDisplaySignature = nil
                restore(match.snapshotID)
            }
            return
        }

        AppLogger.displays.debug("Multiple saved layouts matched the current display configuration; showing a chooser.")
        suggestionPresenter?.showDisplayRestoreSuggestionChooser(
            options: matches.map {
                DisplayRestoreSuggestionOption(
                    snapshotID: $0.snapshotID,
                    snapshotName: $0.snapshotName
                )
            }
        ) { [weak self, restore] snapshotID in
            self?.suggestedDisplaySignature = nil
            restore(snapshotID)
        }
    }
}

private struct DisplayTopologySignature: Equatable {
    let displays: [DisplayTopologyItem]

    init(displayState: DisplayState) {
        displays = displayState.displays
            .map(DisplayTopologyItem.init(display:))
            .sorted()
    }
}

private enum DisplayTopologyItem: Comparable {
    case hardware(vendorID: UInt32, productID: UInt32, serialNumber: UInt32)
    case name(String)
    case anonymous

    init(display: DisplayRecord) {
        if let vendorID = display.vendorID,
           let productID = display.productID,
           let serialNumber = display.serialNumber {
            self = .hardware(
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber
            )
            return
        }

        if let name = display.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            self = .name(name)
            return
        }

        self = .anonymous
    }
}

private struct DisplayConfigurationSignature: Equatable {
    let displays: [DisplaySignatureItem]

    init(displayState: DisplayState) {
        displays = displayState.displays
            .map(DisplaySignatureItem.init(display:))
            .sorted()
    }
}

private struct DisplaySignatureItem: Comparable, Equatable {
    let id: UInt32
    let localizedName: String?
    let frame: CGRectCodable
    let visibleFrame: CGRectCodable
    let backingScaleFactor: Double
    let isPrimary: Bool
    let vendorID: UInt32?
    let productID: UInt32?
    let serialNumber: UInt32?

    init(display: DisplayRecord) {
        id = display.id
        localizedName = display.localizedName
        frame = display.frame
        visibleFrame = display.visibleFrame
        backingScaleFactor = display.backingScaleFactor
        isPrimary = display.isPrimary
        vendorID = display.vendorID
        productID = display.productID
        serialNumber = display.serialNumber
    }

    static func < (left: DisplaySignatureItem, right: DisplaySignatureItem) -> Bool {
        if left.frame.x != right.frame.x {
            return left.frame.x < right.frame.x
        }

        if left.frame.y != right.frame.y {
            return left.frame.y < right.frame.y
        }

        return left.id < right.id
    }
}
