import AppKit
import Combine
import Foundation
import Sparkle

struct AppUpdateDetails: Equatable {
    enum ReleaseNotesFormat: Equatable {
        case markdown
        case plainText
        case unavailable
    }

    let currentVersion: String
    let buildVersion: String
    let displayVersion: String
    let releaseDate: Date?
    var releaseNotes: String
    var releaseNotesFormat: ReleaseNotesFormat
    let releaseNotesURL: URL?
    let informationURL: URL?
    let isCritical: Bool
    let isInformational: Bool

    var formattedReleaseDate: String? {
        releaseDate?.formatted(date: .abbreviated, time: .omitted)
    }

    var shouldOfferExternalReleaseNotes: Bool {
        releaseNotesFormat == .unavailable && releaseNotesURL != nil
    }

    var primaryActionTitle: String {
        isInformational ? "Learn More" : "Install Update"
    }

    var learnMoreURL: URL? {
        informationURL ?? releaseNotesURL
    }
}

struct AppUpdateProgress: Equatable {
    var receivedBytes: UInt64 = 0
    var expectedBytes: UInt64?

    var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else {
            return nil
        }

        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    mutating func receive(_ byteCount: UInt64) {
        let result = receivedBytes.addingReportingOverflow(byteCount)
        receivedBytes = result.overflow ? .max : result.partialValue
    }
}

enum AppUpdatePresentationPhase: Equatable {
    case checking
    case available(AppUpdateDetails)
    case downloading(AppUpdateDetails, AppUpdateProgress)
    case extracting(AppUpdateDetails, progress: Double?)
    case ready(AppUpdateDetails)
    case installing(AppUpdateDetails, applicationTerminated: Bool)
    case upToDate(message: String)
    case unavailable(title: String, message: String)
    case error(title: String, message: String)
    case installed(relaunched: Bool)

    var details: AppUpdateDetails? {
        switch self {
        case let .available(details),
             let .downloading(details, _),
             let .extracting(details, _),
             let .ready(details),
             let .installing(details, _):
            details
        case .checking, .upToDate, .unavailable, .error, .installed:
            nil
        }
    }

    var allowsWindowClose: Bool {
        closeAction != nil
    }

    private enum AccessibilityIdentity: Equatable {
        case checking
        case available(version: String)
        case downloading
        case extracting
        case ready
        case installing(applicationTerminated: Bool)
        case upToDate(message: String)
        case unavailable(title: String, message: String)
        case error(title: String, message: String)
        case installed(relaunched: Bool)
    }

    private var accessibilityIdentity: AccessibilityIdentity {
        switch self {
        case .checking:
            .checking
        case let .available(details):
            .available(version: details.displayVersion)
        case .downloading:
            .downloading
        case .extracting:
            .extracting
        case .ready:
            .ready
        case let .installing(_, applicationTerminated):
            .installing(applicationTerminated: applicationTerminated)
        case let .upToDate(message):
            .upToDate(message: message)
        case let .unavailable(title, message):
            .unavailable(title: title, message: message)
        case let .error(title, message):
            .error(title: title, message: message)
        case let .installed(relaunched):
            .installed(relaunched: relaunched)
        }
    }

    func shouldAnnounceTransition(from previousPhase: AppUpdatePresentationPhase) -> Bool {
        accessibilityIdentity != previousPhase.accessibilityIdentity
    }

    var accessibilityAnnouncement: String {
        switch self {
        case .checking:
            "Checking for updates."
        case let .available(details):
            "LayoutLock \(details.displayVersion) is available."
        case .downloading:
            "Downloading update."
        case .extracting:
            "Preparing update."
        case .ready:
            "Update is ready to install and relaunch."
        case let .installing(_, applicationTerminated):
            applicationTerminated ? "Installing update." : "Waiting for LayoutLock to quit."
        case let .upToDate(message):
            message
        case let .unavailable(title, _):
            title
        case let .error(title, _):
            title
        case let .installed(relaunched):
            relaunched ? "Update installed and LayoutLock relaunched." : "Update installed."
        }
    }
}

enum AppUpdateAction: Hashable {
    case cancel
    case install
    case dismiss
    case skip
    case openReleaseNotes
    case learnMore
    case installAndRelaunch
    case retry
    case retryTermination
    case acknowledge
}

extension AppUpdatePresentationPhase {
    var preferredFocusAction: AppUpdateAction? {
        switch self {
        case .checking:
            .cancel
        case let .available(details):
            details.isInformational
                ? details.learnMoreURL.map { _ in .learnMore }
                : .install
        case .downloading:
            .cancel
        case .extracting:
            nil
        case .ready:
            .installAndRelaunch
        case let .installing(_, applicationTerminated):
            applicationTerminated ? nil : .retryTermination
        case .upToDate, .unavailable, .installed:
            .acknowledge
        case .error:
            .retry
        }
    }

    var closeAction: AppUpdateAction? {
        switch self {
        case .checking, .downloading:
            .cancel
        case .available, .ready:
            .dismiss
        case .upToDate, .unavailable, .error, .installed:
            .acknowledge
        case .extracting, .installing:
            nil
        }
    }
}

@MainActor
final class AppUpdatePresentationModel: ObservableObject {
    @Published var phase: AppUpdatePresentationPhase = .checking {
        didSet {
            guard phase.shouldAnnounceTransition(from: oldValue) else {
                return
            }

            announcementHandler(phase.accessibilityAnnouncement)
        }
    }

    private let announcementHandler: (String) -> Void

    init(announcementHandler: ((String) -> Void)? = nil) {
        self.announcementHandler = announcementHandler ?? Self.postAnnouncement
    }

    private static func postAnnouncement(_ message: String) {
        guard NSApp != nil else {
            return
        }

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

@MainActor
protocol AppUpdateWindowPresenting: AnyObject {
    func configure(
        model: AppUpdatePresentationModel,
        actionHandler: @escaping (AppUpdateAction) -> Void
    )
    func show(activatingApplication: Bool)
    func close()
}

private final class AppUpdateOneShot<Value> {
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    @discardableResult
    func call(_ value: Value) -> Bool {
        guard let callback else {
            return false
        }

        self.callback = nil
        callback(value)
        return true
    }
}

@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    let presentationModel: AppUpdatePresentationModel
    var retryHandler: (() -> Void)?

    private let windowPresenter: AppUpdateWindowPresenting
    private let currentVersion: String
    private var activeDetails: AppUpdateDetails?
    private var shouldPresentCurrentState = false

    private var checkCancellation: AppUpdateOneShot<Void>?
    private var downloadCancellation: AppUpdateOneShot<Void>?
    private var updateReply: AppUpdateOneShot<SPUUserUpdateChoice>?
    private var readyReply: AppUpdateOneShot<SPUUserUpdateChoice>?
    private var acknowledgement: AppUpdateOneShot<Void>?
    private var retryTerminatingApplication: (() -> Void)?

    init(
        presentationModel: AppUpdatePresentationModel? = nil,
        windowPresenter: AppUpdateWindowPresenting? = nil,
        currentVersion: String? = nil
    ) {
        let presentationModel = presentationModel ?? AppUpdatePresentationModel()
        let windowPresenter = windowPresenter ?? AppUpdateWindowController.shared
        self.presentationModel = presentationModel
        self.windowPresenter = windowPresenter
        self.currentVersion = currentVersion ?? AppUpdateUserDriver.applicationVersion
        super.init()

        windowPresenter.configure(model: presentationModel) { [weak self] action in
            self?.handle(action)
        }
    }

    func show(
        _: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        AppUpdateOneShot(reply).call(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: true,
                automaticUpdateDownloading: false,
                sendSystemProfile: false
            )
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        beginChecking(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        presentUpdate(
            details: makeDetails(from: appcastItem),
            userInitiated: state.userInitiated,
            reply: reply
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard var details = activeDetails else {
            return
        }

        let releaseNotesURL = downloadData.url
        if Self.isMarkdown(downloadData) {
            details.releaseNotes = Self.decodeText(downloadData) ?? Self.releaseNotesUnavailableMessage
            details.releaseNotesFormat = .markdown
        } else if Self.isPlainText(downloadData) {
            details.releaseNotes = Self.decodeText(downloadData) ?? Self.releaseNotesUnavailableMessage
            details.releaseNotesFormat = .plainText
        } else {
            details.releaseNotes = Self.unsupportedReleaseNotesMessage
            details.releaseNotesFormat = .unavailable
        }

        replaceActiveDetails(details, externalURL: releaseNotesURL)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        guard var details = activeDetails else {
            return
        }

        details.releaseNotes = Self.releaseNotesUnavailableMessage
        details.releaseNotesFormat = .unavailable
        activeDetails = details
        presentationModel.phase = replacingDetails(in: presentationModel.phase, with: details)
        AppLogger.updates.error("Release notes download failed: \(error.localizedDescription)")
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        presentNoUpdate(error: error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        presentError(
            title: "Unable to Check for Updates",
            message: (error as NSError).localizedRecoverySuggestion ?? error.localizedDescription,
            acknowledgement: acknowledgement
        )
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        beginDownloading(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        updateExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receiveDownloadedData(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        beginExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updateExtractionProgress(progress)
    }

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        presentReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        presentInstalling(
            applicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        presentInstalled(relaunched: relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        windowPresenter.close()
        clearCallbacks()
        activeDetails = nil
        shouldPresentCurrentState = false
    }

    func showUpdateInFocus() {
        shouldPresentCurrentState = true
        windowPresenter.show(activatingApplication: true)
    }

    func beginChecking(cancellation: @escaping () -> Void) {
        checkCancellation = AppUpdateOneShot(cancellation)
        shouldPresentCurrentState = true
        presentationModel.phase = .checking
        windowPresenter.show(activatingApplication: true)
    }

    func presentUpdate(
        details: AppUpdateDetails,
        userInitiated: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        checkCancellation = nil
        activeDetails = details
        updateReply = AppUpdateOneShot(reply)
        shouldPresentCurrentState = userInitiated
        presentationModel.phase = .available(details)

        if userInitiated {
            windowPresenter.show(activatingApplication: true)
        }
    }

    func beginDownloading(cancellation: @escaping () -> Void) {
        guard let details = activeDetails else {
            return
        }

        downloadCancellation = AppUpdateOneShot(cancellation)
        presentationModel.phase = .downloading(details, AppUpdateProgress())
        presentIfNeeded()
    }

    func updateExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(details, progress) = presentationModel.phase else {
            return
        }

        var updatedProgress = progress
        updatedProgress.expectedBytes = expectedContentLength > 0 ? expectedContentLength : nil
        presentationModel.phase = .downloading(details, updatedProgress)
    }

    func receiveDownloadedData(_ length: UInt64) {
        guard case let .downloading(details, progress) = presentationModel.phase else {
            return
        }

        var updatedProgress = progress
        updatedProgress.receive(length)
        presentationModel.phase = .downloading(details, updatedProgress)
    }

    func beginExtracting() {
        guard let details = activeDetails else {
            return
        }

        downloadCancellation = nil
        presentationModel.phase = .extracting(details, progress: nil)
        presentIfNeeded()
    }

    func updateExtractionProgress(_ progress: Double) {
        guard let details = activeDetails else {
            return
        }

        presentationModel.phase = .extracting(
            details,
            progress: min(max(progress, 0), 1)
        )
    }

    func presentReadyToInstall(
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let details = activeDetails else {
            return
        }

        readyReply = AppUpdateOneShot(reply)
        presentationModel.phase = .ready(details)
        presentIfNeeded()
    }

    func presentInstalling(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard let details = activeDetails else {
            return
        }

        self.retryTerminatingApplication = applicationTerminated
            ? nil
            : retryTerminatingApplication
        presentationModel.phase = .installing(
            details,
            applicationTerminated: applicationTerminated
        )
        presentIfNeeded()
    }

    func presentUpToDate(message: String, acknowledgement: @escaping () -> Void) {
        checkCancellation = nil
        self.acknowledgement = AppUpdateOneShot(acknowledgement)
        shouldPresentCurrentState = true
        presentationModel.phase = .upToDate(message: message)
        windowPresenter.show(activatingApplication: true)
    }

    func presentNoUpdate(error: Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let message = nsError.localizedRecoverySuggestion ?? nsError.localizedDescription

        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion:
            presentUpToDate(message: message, acknowledgement: acknowledgement)
        case .unknown, .systemIsTooOld, .systemIsTooNew,
             .hardwareDoesNotSupportARM64, nil:
            presentUnavailable(
                title: nsError.localizedDescription,
                message: message,
                acknowledgement: acknowledgement
            )
        @unknown default:
            presentUnavailable(
                title: nsError.localizedDescription,
                message: message,
                acknowledgement: acknowledgement
            )
        }
    }

    private func presentUnavailable(
        title: String,
        message: String,
        acknowledgement: @escaping () -> Void
    ) {
        checkCancellation = nil
        self.acknowledgement = AppUpdateOneShot(acknowledgement)
        shouldPresentCurrentState = true
        presentationModel.phase = .unavailable(title: title, message: message)
        windowPresenter.show(activatingApplication: true)
    }

    func presentError(
        title: String,
        message: String,
        acknowledgement: @escaping () -> Void
    ) {
        checkCancellation = nil
        downloadCancellation = nil
        self.acknowledgement = AppUpdateOneShot(acknowledgement)
        shouldPresentCurrentState = true
        presentationModel.phase = .error(title: title, message: message)
        windowPresenter.show(activatingApplication: true)
    }

    func presentInstalled(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = AppUpdateOneShot(acknowledgement)
        shouldPresentCurrentState = true
        presentationModel.phase = .installed(relaunched: relaunched)
        windowPresenter.show(activatingApplication: true)
    }

    func handle(_ action: AppUpdateAction) {
        switch action {
        case .cancel:
            let didCancel = checkCancellation?.call(()) == true
                || downloadCancellation?.call(()) == true
            if didCancel {
                closeAndResetPresentation()
            }
        case .install:
            updateReply?.call(.install)
        case .dismiss:
            let didReply = readyReply?.call(.dismiss) == true
                || updateReply?.call(.dismiss) == true
            if didReply {
                closeAndResetPresentation()
            }
        case .skip:
            if updateReply?.call(.skip) == true {
                closeAndResetPresentation()
            }
        case .openReleaseNotes:
            openHTTPSURL(activeDetails?.releaseNotesURL)
        case .learnMore:
            if updateReply?.call(.dismiss) == true {
                openHTTPSURL(activeDetails?.learnMoreURL)
                closeAndResetPresentation()
            }
        case .installAndRelaunch:
            readyReply?.call(.install)
        case .retry:
            if acknowledgement?.call(()) == true {
                closeAndResetPresentation()
                DispatchQueue.main.async { [weak self] in
                    self?.retryHandler?()
                }
            }
        case .retryTermination:
            retryTerminatingApplication?()
        case .acknowledge:
            if acknowledgement?.call(()) == true {
                closeAndResetPresentation()
            }
        }
    }

    func handleWindowClose() {
        guard let closeAction = presentationModel.phase.closeAction else {
            return
        }

        handle(closeAction)
    }

    private func makeDetails(from item: SUAppcastItem) -> AppUpdateDetails {
        let format = item.itemDescriptionFormat?.lowercased()
        let embeddedNotes: String
        let notesFormat: AppUpdateDetails.ReleaseNotesFormat

        switch format {
        case "markdown":
            embeddedNotes = item.itemDescription ?? Self.releaseNotesUnavailableMessage
            notesFormat = .markdown
        case "plain-text":
            embeddedNotes = item.itemDescription ?? Self.releaseNotesUnavailableMessage
            notesFormat = .plainText
        default:
            embeddedNotes = item.itemDescription == nil
                ? Self.releaseNotesUnavailableMessage
                : Self.unsupportedReleaseNotesMessage
            notesFormat = .unavailable
        }

        return AppUpdateDetails(
            currentVersion: currentVersion,
            buildVersion: item.versionString,
            displayVersion: item.displayVersionString,
            releaseDate: item.date,
            releaseNotes: embeddedNotes,
            releaseNotesFormat: notesFormat,
            releaseNotesURL: Self.validHTTPSURL(item.releaseNotesURL ?? item.fullReleaseNotesURL),
            informationURL: Self.validHTTPSURL(item.infoURL),
            isCritical: item.isCriticalUpdate,
            isInformational: item.isInformationOnlyUpdate
        )
    }

    private func replaceActiveDetails(_ details: AppUpdateDetails, externalURL: URL) {
        let safeURL = Self.validHTTPSURL(externalURL)
        let updatedDetails = AppUpdateDetails(
            currentVersion: details.currentVersion,
            buildVersion: details.buildVersion,
            displayVersion: details.displayVersion,
            releaseDate: details.releaseDate,
            releaseNotes: details.releaseNotes,
            releaseNotesFormat: details.releaseNotesFormat,
            releaseNotesURL: safeURL ?? details.releaseNotesURL,
            informationURL: details.informationURL,
            isCritical: details.isCritical,
            isInformational: details.isInformational
        )

        activeDetails = updatedDetails
        presentationModel.phase = replacingDetails(
            in: presentationModel.phase,
            with: updatedDetails
        )
    }

    private func replacingDetails(
        in phase: AppUpdatePresentationPhase,
        with details: AppUpdateDetails
    ) -> AppUpdatePresentationPhase {
        switch phase {
        case .available:
            .available(details)
        case let .downloading(_, progress):
            .downloading(details, progress)
        case let .extracting(_, progress):
            .extracting(details, progress: progress)
        case .ready:
            .ready(details)
        case let .installing(_, applicationTerminated):
            .installing(details, applicationTerminated: applicationTerminated)
        case .checking, .upToDate, .unavailable, .error, .installed:
            phase
        }
    }

    private func presentIfNeeded() {
        guard shouldPresentCurrentState else {
            return
        }

        windowPresenter.show(activatingApplication: false)
    }

    private func closeAndResetPresentation() {
        windowPresenter.close()
        shouldPresentCurrentState = false
    }

    private func clearCallbacks() {
        checkCancellation = nil
        downloadCancellation = nil
        updateReply = nil
        readyReply = nil
        acknowledgement = nil
        retryTerminatingApplication = nil
    }

    private func openHTTPSURL(_ url: URL?) {
        guard let url = Self.validHTTPSURL(url) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private static func validHTTPSURL(_ url: URL?) -> URL? {
        guard url?.scheme?.lowercased() == "https" else {
            return nil
        }

        return url
    }

    private static func isMarkdown(_ downloadData: SPUDownloadData) -> Bool {
        let mimeType = downloadData.mimeType?.lowercased()
        let pathExtension = downloadData.url.pathExtension.lowercased()
        return mimeType == "text/markdown"
            || mimeType == "text/x-markdown"
            || pathExtension == "md"
            || pathExtension == "markdown"
    }

    private static func isPlainText(_ downloadData: SPUDownloadData) -> Bool {
        downloadData.mimeType?.lowercased() == "text/plain"
            || downloadData.url.pathExtension.lowercased() == "txt"
    }

    private static func decodeText(_ downloadData: SPUDownloadData) -> String? {
        if downloadData.textEncodingName?.lowercased() == "iso-8859-1" {
            return String(data: downloadData.data, encoding: .isoLatin1)
        }

        return String(data: downloadData.data, encoding: .utf8)
    }

    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
            ?? "Unknown"
    }

    private static let releaseNotesUnavailableMessage =
        "Release notes are unavailable. You can view them in your browser when a link is provided."

    private static let unsupportedReleaseNotesMessage =
        "These release notes use an unsupported format. Open the release notes in your browser to view them safely."
}
