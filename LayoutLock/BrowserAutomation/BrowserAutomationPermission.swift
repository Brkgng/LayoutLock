import AppKit
import Carbon
import Foundation

enum BrowserAutomationPermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
    case targetNotRunning
    case failed
}

protocol BrowserAutomationPermissionChecking {
    func status(
        for browser: BrowserAutomationBrowser,
        askUserIfNeeded: Bool
    ) -> BrowserAutomationPermissionStatus
}

struct BrowserAutomationPermissionChecker: BrowserAutomationPermissionChecking {
    func status(
        for browser: BrowserAutomationBrowser,
        askUserIfNeeded: Bool
    ) -> BrowserAutomationPermissionStatus {
        let bundleIdentifierData = Data(browser.bundleIdentifier.utf8)
        var targetDescriptor = AEAddressDesc()
        let createStatus = bundleIdentifierData.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bytes.baseAddress,
                bundleIdentifierData.count,
                &targetDescriptor
            )
        }
        guard createStatus == noErr else {
            return .failed
        }
        defer {
            AEDisposeDesc(&targetDescriptor)
        }

        let permissionStatus = AEDeterminePermissionToAutomateTarget(
            &targetDescriptor,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )

        switch permissionStatus {
        case noErr:
            return .authorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .failed
        }
    }
}

@MainActor
final class BrowserAutomationController: ObservableObject {
    typealias ApplicationURLProvider = (String) -> URL?
    typealias RunningBundleIdentifiersProvider = () -> Set<String>

    @Published private(set) var statuses: [BrowserAutomationBrowser: BrowserAutomationStatus] = [:]

    private let userDefaults: UserDefaults
    private let permissionChecker: BrowserAutomationPermissionChecking
    private let applicationURLProvider: ApplicationURLProvider
    private let runningBundleIdentifiersProvider: RunningBundleIdentifiersProvider
    private let automationSettingsOpener: @MainActor () -> Void
    private let telemetryLogger: TelemetryLogging
    private var activationObserver: NSObjectProtocol?
    private var refreshGeneration = 0

    init(
        userDefaults: UserDefaults = .standard,
        permissionChecker: BrowserAutomationPermissionChecking = BrowserAutomationPermissionChecker(),
        workspace: NSWorkspace = .shared,
        applicationURLProvider: ApplicationURLProvider? = nil,
        runningBundleIdentifiersProvider: RunningBundleIdentifiersProvider? = nil,
        automationSettingsOpener: @escaping @MainActor () -> Void =
            BrowserAutomationController.openSystemAutomationSettings,
        telemetryLogger: TelemetryLogging = NoOpTelemetryLogger()
    ) {
        self.userDefaults = userDefaults
        self.permissionChecker = permissionChecker
        self.applicationURLProvider = applicationURLProvider ?? {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        self.runningBundleIdentifiersProvider = runningBundleIdentifiersProvider ?? {
            Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        }
        self.automationSettingsOpener = automationSettingsOpener
        self.telemetryLogger = telemetryLogger
        refresh()
        startObservingAppActivation()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func status(for browser: BrowserAutomationBrowser) -> BrowserAutomationStatus {
        statuses[browser] ?? makeStatus(for: browser, isWorking: false, message: nil)
    }

    func connect(_ browser: BrowserAutomationBrowser) {
        guard status(for: browser).canConnect else {
            return
        }

        setStatus(for: browser, isWorking: true, message: nil)
        let permissionChecker = permissionChecker
        Task { @MainActor [weak self] in
            let permissionStatus = await Self.checkPermissionOffMain {
                permissionChecker.status(for: browser, askUserIfNeeded: true)
            }
            guard let self else {
                return
            }

            switch permissionStatus {
            case .authorized:
                userDefaults.set(true, forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser))
                userDefaults.set(true, forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser))
                userDefaults.set(false, forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser))
                telemetryLogger.log(.browserAutomation(browser: browser, outcome: "authorized"))
            case .denied:
                userDefaults.set(true, forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser))
                userDefaults.set(true, forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser))
                telemetryLogger.log(.browserAutomation(browser: browser, outcome: "denied"))
            case .notDetermined, .targetNotRunning, .failed:
                telemetryLogger.log(.browserAutomation(browser: browser, outcome: "failed"))
            }

            refresh()
        }
    }

    func disconnect(_ browser: BrowserAutomationBrowser) {
        userDefaults.set(false, forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser))
        userDefaults.set(false, forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser))
        telemetryLogger.log(.browserAutomation(browser: browser, outcome: "disconnected"))
        refresh()
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let runningBundleIdentifiers = runningBundleIdentifiersProvider()

        for browser in BrowserAutomationBrowser.allCases {
            setStatus(for: browser, isWorking: false, message: nil)

            guard userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
            ),
            applicationURLProvider(browser.bundleIdentifier) != nil,
            runningBundleIdentifiers.contains(browser.bundleIdentifier) else {
                continue
            }

            let permissionChecker = permissionChecker
            Task { @MainActor [weak self] in
                let permissionStatus = await Self.checkPermissionOffMain {
                    permissionChecker.status(for: browser, askUserIfNeeded: false)
                }
                guard let self, refreshGeneration == generation else {
                    return
                }
                applyPermissionStatus(permissionStatus, for: browser)
            }
        }
    }

    func openAutomationSettings() {
        automationSettingsOpener()
    }

    private func setStatus(
        for browser: BrowserAutomationBrowser,
        isWorking: Bool,
        message: String?
    ) {
        statuses[browser] = makeStatus(
            for: browser,
            isWorking: isWorking,
            message: message
        )
    }

    private func makeStatus(
        for browser: BrowserAutomationBrowser,
        isWorking: Bool,
        message: String?
    ) -> BrowserAutomationStatus {
        let isInstalled = applicationURLProvider(browser.bundleIdentifier) != nil
        let runningBundleIdentifiers = runningBundleIdentifiersProvider()
        let isRunning = runningBundleIdentifiers.contains(browser.bundleIdentifier)

        guard isInstalled else {
            return BrowserAutomationStatus(
                browser: browser,
                connectionState: .notInstalled,
                isRunning: false,
                isWorking: isWorking,
                message: message
            )
        }

        let isEnabled = userDefaults.bool(
            forKey: LayoutLockSettings.browserAutomationEnabledKey(for: browser)
        )
        let permissionWasDenied = userDefaults.bool(
            forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
        )
        guard isEnabled else {
            return BrowserAutomationStatus(
                browser: browser,
                connectionState: permissionWasDenied ? .permissionDenied : .notConnected,
                isRunning: isRunning,
                isWorking: isWorking,
                message: message
            )
        }

        let connectedBefore = userDefaults.bool(
            forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
        )
        let connectionState: BrowserAutomationConnectionState
        if permissionWasDenied {
            connectionState = connectedBefore ? .revoked : .permissionDenied
        } else {
            connectionState = .connected
        }

        return BrowserAutomationStatus(
            browser: browser,
            connectionState: connectionState,
            isRunning: isRunning,
            isWorking: isWorking,
            message: message
        )
    }

    private func applyPermissionStatus(
        _ permissionStatus: BrowserAutomationPermissionStatus,
        for browser: BrowserAutomationBrowser
    ) {
        let connectionState: BrowserAutomationConnectionState
        switch permissionStatus {
        case .authorized:
            userDefaults.set(
                false,
                forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
            )
            connectionState = .connected
        case .denied:
            userDefaults.set(
                true,
                forKey: LayoutLockSettings.browserAutomationPermissionDeniedKey(for: browser)
            )
            let connectedBefore = userDefaults.bool(
                forKey: LayoutLockSettings.browserAutomationConnectedBeforeKey(for: browser)
            )
            connectionState = connectedBefore ? .revoked : .permissionDenied
        case .notDetermined:
            connectionState = .notConnected
        case .targetNotRunning, .failed:
            return
        }

        statuses[browser] = BrowserAutomationStatus(
            browser: browser,
            connectionState: connectionState,
            isRunning: true,
            isWorking: false,
            message: nil
        )
    }

    private static func checkPermissionOffMain(
        _ operation: @escaping () -> BrowserAutomationPermissionStatus
    ) async -> BrowserAutomationPermissionStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    static func openSystemAutomationSettings() {
        if let privacyPaneURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ),
        NSWorkspace.shared.open(privacyPaneURL) {
            return
        }

        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )
    }

    private func startObservingAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
