import Sparkle
import XCTest
@testable import LayoutLock

@MainActor
final class AppUpdateUserDriverTests: XCTestCase {
    func testManualCheckPresentsCheckingStateAndCanCancelOnlyOnce() {
        let (driver, window) = makeDriver()
        var cancellationCount = 0

        driver.beginChecking {
            cancellationCount += 1
        }

        XCTAssertEqual(driver.presentationModel.phase, .checking)
        XCTAssertEqual(window.showActivations, [true])

        driver.handleWindowClose()
        driver.handleWindowClose()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(window.closeCount, 1)
    }

    func testScheduledUpdateStaysGentleUntilExplicitlyFocused() {
        let (driver, window) = makeDriver()

        driver.presentUpdate(
            details: details(),
            userInitiated: false,
            reply: { _ in }
        )

        XCTAssertEqual(driver.presentationModel.phase, .available(details()))
        XCTAssertTrue(window.showActivations.isEmpty)

        driver.showUpdateInFocus()

        XCTAssertEqual(window.showActivations, [true])
    }

    func testManualUpdatePresentsImmediately() {
        let (driver, window) = makeDriver()

        driver.presentUpdate(
            details: details(),
            userInitiated: true,
            reply: { _ in }
        )

        XCTAssertEqual(window.showActivations, [true])
    }

    func testPreferredFocusUsesPrimaryActionsInsteadOfSkip() {
        let update = details()

        XCTAssertEqual(
            AppUpdatePresentationPhase.available(update).preferredFocusAction,
            .install
        )
        XCTAssertEqual(
            AppUpdatePresentationPhase.available(details(isInformational: true))
                .preferredFocusAction,
            .learnMore
        )
        XCTAssertEqual(
            AppUpdatePresentationPhase.ready(update).preferredFocusAction,
            .installAndRelaunch
        )
        XCTAssertEqual(
            AppUpdatePresentationPhase.error(title: "Failed", message: "Try again.")
                .preferredFocusAction,
            .retry
        )
        XCTAssertNotEqual(
            AppUpdatePresentationPhase.available(update).preferredFocusAction,
            .skip
        )
    }

    func testLifecycleTransitionsThroughDownloadExtractionReadyAndInstall() {
        let (driver, _) = makeDriver()
        let update = details()
        var updateChoices: [SPUUserUpdateChoice] = []
        var readyChoices: [SPUUserUpdateChoice] = []

        driver.presentUpdate(
            details: update,
            userInitiated: true,
            reply: { updateChoices.append($0) }
        )
        driver.handle(.install)
        driver.handle(.install)

        XCTAssertEqual(updateChoices, [.install])

        driver.beginDownloading {}
        XCTAssertEqual(
            driver.presentationModel.phase,
            .downloading(update, AppUpdateProgress())
        )

        driver.updateExpectedContentLength(200)
        driver.receiveDownloadedData(50)
        XCTAssertEqual(
            driver.presentationModel.phase,
            .downloading(
                update,
                AppUpdateProgress(receivedBytes: 50, expectedBytes: 200)
            )
        )

        driver.beginExtracting()
        XCTAssertEqual(
            driver.presentationModel.phase,
            .extracting(update, progress: nil)
        )

        driver.updateExtractionProgress(0.4)
        XCTAssertEqual(
            driver.presentationModel.phase,
            .extracting(update, progress: 0.4)
        )

        driver.presentReadyToInstall {
            readyChoices.append($0)
        }
        XCTAssertEqual(driver.presentationModel.phase, .ready(update))

        driver.handle(.installAndRelaunch)
        driver.handle(.installAndRelaunch)
        XCTAssertEqual(readyChoices, [.install])

        driver.presentInstalling(
            applicationTerminated: true,
            retryTerminatingApplication: {}
        )
        XCTAssertEqual(
            driver.presentationModel.phase,
            .installing(update, applicationTerminated: true)
        )
    }

    func testProgressHandlesUnknownSizeAndClampsInvalidValues() {
        let (driver, _) = makeDriver()
        let update = details()
        driver.presentUpdate(details: update, userInitiated: true, reply: { _ in })
        driver.beginDownloading {}

        driver.updateExpectedContentLength(0)
        driver.receiveDownloadedData(25)

        guard case let .downloading(_, unknownProgress) = driver.presentationModel.phase else {
            return XCTFail("Expected downloading phase")
        }
        XCTAssertNil(unknownProgress.fractionCompleted)

        driver.updateExpectedContentLength(10)
        guard case let .downloading(_, knownProgress) = driver.presentationModel.phase else {
            return XCTFail("Expected downloading phase")
        }
        XCTAssertEqual(knownProgress.fractionCompleted, 1)

        driver.beginExtracting()
        driver.updateExtractionProgress(-1)
        XCTAssertEqual(
            driver.presentationModel.phase,
            .extracting(update, progress: 0)
        )

        driver.updateExtractionProgress(2)
        XCTAssertEqual(
            driver.presentationModel.phase,
            .extracting(update, progress: 1)
        )
    }

    func testProgressTicksDoNotPostRepeatedAccessibilityAnnouncements() {
        var announcements: [String] = []
        let model = AppUpdatePresentationModel {
            announcements.append($0)
        }
        let update = details()

        model.phase = .available(update)
        model.phase = .downloading(update, AppUpdateProgress())
        model.phase = .downloading(
            update,
            AppUpdateProgress(receivedBytes: 50, expectedBytes: 100)
        )
        model.phase = .extracting(update, progress: nil)
        model.phase = .extracting(update, progress: 0.5)

        XCTAssertEqual(
            announcements,
            [
                "LayoutLock 1.1.0 is available.",
                "Downloading update.",
                "Preparing update.",
            ]
        )
    }

    func testLatestVersionNoUpdateUsesUpToDateStateAndRecoverySuggestion() {
        let (driver, window) = makeDriver()
        var acknowledgementCount = 0
        let error = noUpdateError(
            reason: .onLatestVersion,
            description: "You’re up to date!",
            recoverySuggestion: "LayoutLock 1.0.0 is currently the newest version available."
        )

        driver.presentNoUpdate(error: error) {
            acknowledgementCount += 1
        }

        XCTAssertEqual(
            driver.presentationModel.phase,
            .upToDate(
                message: "LayoutLock 1.0.0 is currently the newest version available."
            )
        )
        XCTAssertEqual(window.showActivations, [true])

        driver.handleWindowClose()
        XCTAssertEqual(acknowledgementCount, 1)
    }

    func testIncompatibleNoUpdatePreservesReasonAndDoesNotClaimUpToDate() {
        let (driver, _) = makeDriver()
        var acknowledgementCount = 0
        let error = noUpdateError(
            reason: .systemIsTooOld,
            description: "A newer version of macOS is required.",
            recoverySuggestion: "LayoutLock 2.0 requires macOS 15 or later."
        )

        driver.presentNoUpdate(error: error) {
            acknowledgementCount += 1
        }

        XCTAssertEqual(
            driver.presentationModel.phase,
            .unavailable(
                title: "A newer version of macOS is required.",
                message: "LayoutLock 2.0 requires macOS 15 or later."
            )
        )

        driver.handleWindowClose()
        driver.handleWindowClose()
        XCTAssertEqual(acknowledgementCount, 1)
    }

    func testAvailableAndReadyCloseDismissCallbacksOnlyOnce() {
        let update = details()
        let (availableDriver, availableWindow) = makeDriver()
        var availableChoices: [SPUUserUpdateChoice] = []
        availableDriver.presentUpdate(
            details: update,
            userInitiated: true,
            reply: { availableChoices.append($0) }
        )

        availableDriver.handleWindowClose()
        availableDriver.handleWindowClose()

        XCTAssertEqual(availableChoices, [.dismiss])
        XCTAssertEqual(availableWindow.closeCount, 1)

        let (readyDriver, _) = makeDriver()
        readyDriver.presentUpdate(details: update, userInitiated: true, reply: { _ in })
        var readyChoices: [SPUUserUpdateChoice] = []
        readyDriver.presentReadyToInstall {
            readyChoices.append($0)
        }

        readyDriver.handleWindowClose()
        readyDriver.handleWindowClose()

        XCTAssertEqual(readyChoices, [.dismiss])
    }

    func testDownloadCloseCancelsButExtractionAndInstallCannotClose() {
        let update = details()
        let (driver, window) = makeDriver()
        driver.presentUpdate(details: update, userInitiated: true, reply: { _ in })
        var downloadCancellationCount = 0
        driver.beginDownloading {
            downloadCancellationCount += 1
        }

        driver.handleWindowClose()
        XCTAssertEqual(downloadCancellationCount, 1)

        let closeCountAfterDownload = window.closeCount
        driver.beginExtracting()
        driver.handleWindowClose()
        XCTAssertEqual(window.closeCount, closeCountAfterDownload)

        driver.presentInstalling(
            applicationTerminated: false,
            retryTerminatingApplication: {}
        )
        driver.handleWindowClose()
        XCTAssertEqual(window.closeCount, closeCountAfterDownload)
    }

    func testSkipAndDismissCallbacksAreSingleUse() {
        let update = details()
        let (skipDriver, _) = makeDriver()
        var skipChoices: [SPUUserUpdateChoice] = []
        skipDriver.presentUpdate(
            details: update,
            userInitiated: true,
            reply: { skipChoices.append($0) }
        )

        skipDriver.handle(.skip)
        skipDriver.handle(.skip)
        XCTAssertEqual(skipChoices, [.skip])

        let (dismissDriver, _) = makeDriver()
        var dismissChoices: [SPUUserUpdateChoice] = []
        dismissDriver.presentUpdate(
            details: update,
            userInitiated: true,
            reply: { dismissChoices.append($0) }
        )

        dismissDriver.handle(.dismiss)
        dismissDriver.handle(.dismiss)
        XCTAssertEqual(dismissChoices, [.dismiss])
    }

    func testAcknowledgementAndRetryAreSingleUse() async {
        let (driver, _) = makeDriver()
        var acknowledgementCount = 0
        var retryCount = 0
        let retried = expectation(description: "Retry requested")
        driver.retryHandler = {
            retryCount += 1
            retried.fulfill()
        }

        driver.presentError(
            title: "Unable to Check for Updates",
            message: "Offline",
            acknowledgement: { acknowledgementCount += 1 }
        )
        driver.handle(.retry)
        driver.handle(.retry)

        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(acknowledgementCount, 1)
        XCTAssertEqual(retryCount, 1)
    }

    func testUpToDateAndInstalledStatesAcknowledgeOnClose() {
        let (driver, _) = makeDriver()
        var acknowledgementCount = 0
        driver.presentUpToDate(message: "Already current") {
            acknowledgementCount += 1
        }

        XCTAssertEqual(
            driver.presentationModel.phase,
            .upToDate(message: "Already current")
        )
        driver.handleWindowClose()

        driver.presentInstalled(relaunched: true) {
            acknowledgementCount += 1
        }
        XCTAssertEqual(
            driver.presentationModel.phase,
            .installed(relaunched: true)
        )
        driver.handleWindowClose()

        XCTAssertEqual(acknowledgementCount, 2)
    }

    func testTerminationRetryCanBeInvokedMoreThanOnce() {
        let (driver, _) = makeDriver()
        driver.presentUpdate(details: details(), userInitiated: true, reply: { _ in })
        var retryCount = 0
        driver.presentInstalling(
            applicationTerminated: false,
            retryTerminatingApplication: { retryCount += 1 }
        )

        driver.handle(.retryTermination)
        driver.handle(.retryTermination)

        XCTAssertEqual(retryCount, 2)
    }

    func testCriticalInformationalAndStandardActions() {
        let critical = details(isCritical: true)
        XCTAssertEqual(critical.primaryActionTitle, "Install Update")

        let informational = details(isInformational: true)
        XCTAssertEqual(informational.primaryActionTitle, "Learn More")
        XCTAssertEqual(informational.learnMoreURL, informational.informationURL)

        let standard = details()
        XCTAssertEqual(standard.primaryActionTitle, "Install Update")
    }

    func testMarkdownBlocksPreserveHeadingsListsAndParagraphs() {
        let blocks = AppUpdateMarkdown.blocks(
            from: """
            ## What’s New

            - First **important** change.
            - Second change.

            Final paragraph.
            """
        )

        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .heading(level: 2),
                .unorderedListItem,
                .unorderedListItem,
                .paragraph,
            ]
        )
        XCTAssertEqual(
            blocks.map(\.plainText),
            [
                "What’s New",
                "First important change.",
                "Second change.",
                "Final paragraph.",
            ]
        )
    }

    func testMarkdownFeatureHeadingsGroupTitlesWithTheirDescriptions() {
        let blocks = AppUpdateMarkdown.blocks(
            from: """
            ## LayoutLock 1.2

            ### 📌 Pin Your Favorite Layouts

            Keep favorite layouts at the top.

            ### 🔍 Find Layouts Faster

            Search layouts by name.

            ### 📄 Edit Opening Targets

            Locate missing files and folders.

            Also improved: Dashboard spacing.
            """
        )

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 2),
            .feature(systemImage: "pin.fill", title: "Pin Your Favorite Layouts"),
            .feature(systemImage: "magnifyingglass", title: "Find Layouts Faster"),
            .feature(systemImage: "doc.text", title: "Edit Opening Targets"),
            .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.plainText), [
            "LayoutLock 1.2",
            "Keep favorite layouts at the top.",
            "Search layouts by name.",
            "Locate missing files and folders.",
            "Also improved: Dashboard spacing.",
        ])
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    func testMarkdownFeatureDescriptionsPreserveEmphasisAndLinks() throws {
        let blocks = AppUpdateMarkdown.blocks(
            from: """
            ### 📄 Edit Opening Targets

            Read the **updated** [guide](https://layoutlock.app).
            """
        )

        let feature = try XCTUnwrap(blocks.first)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(feature.kind, .feature(systemImage: "doc.text", title: "Edit Opening Targets"))
        XCTAssertTrue(feature.content.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertEqual(
            feature.content.runs.compactMap(\.link),
            [try XCTUnwrap(URL(string: "https://layoutlock.app"))]
        )
    }

    func testMarkdownOrdinaryOrIncompleteHeadingsRemainReadable() {
        for heading in ["### Other Improvements", "### ✨ Other Improvements", "## 📌 Pinned Layouts"] {
            let blocks = AppUpdateMarkdown.blocks(from: "\(heading)\n\nDescription.")
            XCTAssertEqual(blocks.count, 2)
            XCTAssertEqual(blocks.last?.kind, .paragraph)
            XCTAssertEqual(blocks.last?.plainText, "Description.")
        }

        let blocks = AppUpdateMarkdown.blocks(from: "### 📌 Pinned Layouts")
        XCTAssertEqual(blocks.first?.kind, .heading(level: 3))
        XCTAssertEqual(blocks.first?.plainText, "📌 Pinned Layouts")
    }

    private func makeDriver() -> (AppUpdateUserDriver, UpdateWindowPresenterSpy) {
        let presenter = UpdateWindowPresenterSpy()
        let driver = AppUpdateUserDriver(
            windowPresenter: presenter,
            currentVersion: "1.0.0"
        )
        return (driver, presenter)
    }

    private func details(
        isCritical: Bool = false,
        isInformational: Bool = false
    ) -> AppUpdateDetails {
        AppUpdateDetails(
            currentVersion: "1.0.0",
            buildVersion: "110",
            displayVersion: "1.1.0",
            releaseDate: Date(timeIntervalSince1970: 0),
            releaseNotes: "## Changes",
            releaseNotesFormat: .markdown,
            releaseNotesURL: URL(string: "https://layoutlock.app/releases/1.1.0"),
            informationURL: URL(string: "https://layoutlock.app/releases/1.1.0"),
            isCritical: isCritical,
            isInformational: isInformational
        )
    }

    private func noUpdateError(
        reason: SPUNoUpdateFoundReason,
        description: String,
        recoverySuggestion: String
    ) -> NSError {
        NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [
                SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue),
                NSLocalizedDescriptionKey: description,
                NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion,
            ]
        )
    }
}

@MainActor
private final class UpdateWindowPresenterSpy: AppUpdateWindowPresenting {
    private(set) var showActivations: [Bool] = []
    private(set) var closeCount = 0

    func configure(
        model _: AppUpdatePresentationModel,
        actionHandler _: @escaping (AppUpdateAction) -> Void
    ) {}

    func show(activatingApplication: Bool) {
        showActivations.append(activatingApplication)
    }

    func close() {
        closeCount += 1
    }
}
