import AppKit
import XCTest
@testable import LayoutLock

@MainActor
final class DisplayChangeRestoreControllerTests: XCTestCase {
    func testDoesNotSuggestWhenSettingIsOff() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState },
            isSuggestionEnabled: { false }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
    }

    func testDebouncesNoisyScreenParameterNotifications() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testDoesNotCaptureImmediatelyWhenSuggestionIsNotVisible() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var displayStateProviderCallCount = 0
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: {
                displayStateProviderCallCount += 1
                return currentDisplayState
            }
        )
        controller.start()
        XCTAssertEqual(displayStateProviderCallCount, 1)

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        XCTAssertEqual(displayStateProviderCallCount, 1)

        await waitForDebounce()
        XCTAssertEqual(displayStateProviderCallCount, 2)
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testDoesNotSuggestForGeometryOnlyDisplayChange() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = deskDisplayState(currentDisplayID: 20)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(
            currentDisplayID: 20,
            frame: CGRect(x: 100, y: 0, width: 1200, height: 900)
        )
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
        XCTAssertTrue(presenter.choosers.isEmpty)
    }

    func testCapturesImmediatelyToInvalidateVisibleSuggestion() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var displayStateProviderCallCount = 0
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: {
                displayStateProviderCallCount += 1
                return currentDisplayState
            }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(displayStateProviderCallCount, 2)
        XCTAssertTrue(presenter.isDisplayRestoreSuggestionVisible)

        currentDisplayState = unmatchedDisplayState(id: 30)
        controller.displayParametersDidChange()

        XCTAssertEqual(displayStateProviderCallCount, 3)
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertFalse(presenter.isDisplayRestoreSuggestionVisible)
    }

    func testPresenterReportedClosedSuggestionAvoidsImmediateCapture() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var displayStateProviderCallCount = 0
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: {
                displayStateProviderCallCount += 1
                return currentDisplayState
            }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(displayStateProviderCallCount, 2)

        presenter.simulateDismissal()
        currentDisplayState = unmatchedDisplayState(id: 30)
        controller.displayParametersDidChange()

        XCTAssertEqual(displayStateProviderCallCount, 2)
        XCTAssertEqual(presenter.hideCount, 0)

        await waitForDebounce()
        XCTAssertEqual(displayStateProviderCallCount, 3)
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testDoesNotSuggestForDisplayIDChurnAlone() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = deskDisplayState(currentDisplayID: 20)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 21)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
        XCTAssertTrue(presenter.choosers.isEmpty)
    }

    func testSuggestsOnlyOneStrongMatch() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let matchingSnapshot = deskSnapshot()
        let nonMatchingSnapshot = makeSnapshot(
            name: "Travel",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 30, localizedName: "Built-in", vendorID: 9, productID: 9, serialNumber: 9)
            ]
        )
        let controller = makeController(
            presenter: presenter,
            snapshots: [matchingSnapshot, nonMatchingSnapshot],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testHidesVisibleSuggestionForGeometryChangeWithoutPublishingReplacement() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])

        currentDisplayState = deskDisplayState(
            currentDisplayID: 20,
            frame: CGRect(x: 100, y: 0, width: 1200, height: 900)
        )
        controller.displayParametersDidChange()
        XCTAssertEqual(presenter.hideCount, 1)

        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
        XCTAssertTrue(presenter.choosers.isEmpty)
    }

    func testShowsChooserWhenMultipleLayoutsMatch() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot(name: "Desk"), deskSnapshot(name: "Focus")],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
        XCTAssertEqual(presenter.choosers.map { $0.options.map(\.snapshotName) }, [["Desk", "Focus"]])
    }

    func testChooserSelectionInvokesInjectedRestorePath() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var restoredIDs: [UUID] = []
        var currentDisplayState = singleDisplayState(id: 1)
        let deskLayout = deskSnapshot(name: "Desk")
        let focusLayout = deskSnapshot(name: "Focus")
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskLayout, focusLayout],
            displayStateProvider: { currentDisplayState },
            restore: { restoredIDs.append($0) }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        presenter.choosers.first?.restore(focusLayout.id)

        XCTAssertEqual(restoredIDs, [focusLayout.id])
    }

    func testDoesNotSuggestWhenNoLayoutMatches() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = unmatchedDisplayState(id: 30)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
        XCTAssertTrue(presenter.choosers.isEmpty)
    }

    func testDoesNotSuggestWhileOperationIsActive() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState },
            isOperating: { true }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()

        XCTAssertTrue(presenter.suggestions.isEmpty)
    }

    func testRestoreActionInvokesInjectedRestorePath() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var restoredIDs: [UUID] = []
        var currentDisplayState = singleDisplayState(id: 1)
        let snapshot = deskSnapshot()
        let controller = makeController(
            presenter: presenter,
            snapshots: [snapshot],
            displayStateProvider: { currentDisplayState },
            restore: { restoredIDs.append($0) }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        presenter.suggestions.first?.restore()

        XCTAssertEqual(restoredIDs, [snapshot.id])
    }

    func testHidesVisibleSuggestionWhenDisplaySignatureChanges() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])

        currentDisplayState = unmatchedDisplayState(id: 30)
        controller.displayParametersDidChange()

        XCTAssertEqual(presenter.hideCount, 1)

        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testDoesNotHideVisibleSuggestionForUnchangedDisplaySignature() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot()],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])

        controller.displayParametersDidChange()

        XCTAssertEqual(presenter.hideCount, 0)

        await waitForDebounce()
        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk"])
    }

    func testCanSuggestAgainAfterHidingStaleSuggestion() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let travelSnapshot = makeSnapshot(
            name: "Travel",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 40, localizedName: "Travel Display", vendorID: 4, productID: 5, serialNumber: 6)
            ]
        )
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot(), travelSnapshot],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()

        currentDisplayState = travelDisplayState(currentDisplayID: 50)
        controller.displayParametersDidChange()
        XCTAssertEqual(presenter.hideCount, 1)
        await waitForDebounce()

        XCTAssertEqual(presenter.suggestions.map(\.snapshotName), ["Desk", "Travel"])
    }

    func testHidesVisibleChooserWhenDisplaySignatureChanges() async {
        let presenter = RecordingDisplayRestoreSuggestionPresenter()
        var currentDisplayState = singleDisplayState(id: 1)
        let controller = makeController(
            presenter: presenter,
            snapshots: [deskSnapshot(name: "Desk"), deskSnapshot(name: "Focus")],
            displayStateProvider: { currentDisplayState }
        )
        controller.start()

        currentDisplayState = deskDisplayState(currentDisplayID: 20)
        controller.displayParametersDidChange()
        await waitForDebounce()
        XCTAssertEqual(presenter.choosers.count, 1)

        currentDisplayState = unmatchedDisplayState(id: 30)
        controller.displayParametersDidChange()

        XCTAssertEqual(presenter.hideCount, 1)
    }

    private func makeController(
        presenter: RecordingDisplayRestoreSuggestionPresenter,
        snapshots: [Snapshot],
        displayStateProvider: @escaping () -> DisplayState,
        isSuggestionEnabled: @escaping () -> Bool = { true },
        isRestoreAuthorized: @escaping () -> Bool = { true },
        isOperating: @escaping () -> Bool = { false },
        restore: @escaping (UUID) -> Void = { _ in }
    ) -> DisplayChangeRestoreController {
        DisplayChangeRestoreController(
            notificationCenter: NotificationCenter(),
            snapshotProvider: { snapshots },
            displayStateProvider: displayStateProvider,
            isSuggestionEnabled: isSuggestionEnabled,
            isRestoreAuthorized: isRestoreAuthorized,
            isOperating: isOperating,
            suggestionPresenter: presenter,
            debounceInterval: 0.01,
            restore: restore
        )
    }

    private func waitForDebounce() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    private func singleDisplayState(id: UInt32) -> DisplayState {
        DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: id, localizedName: "Built-in", vendorID: 100, productID: 200, serialNumber: 300)
            ],
            primaryDisplayID: id
        )
    }

    private func deskDisplayState(
        currentDisplayID: UInt32,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
    ) -> DisplayState {
        DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(
                    id: currentDisplayID,
                    localizedName: "Desk Display",
                    frame: frame,
                    vendorID: 1,
                    productID: 2,
                    serialNumber: 3
                )
            ],
            primaryDisplayID: currentDisplayID
        )
    }

    private func unmatchedDisplayState(id: UInt32) -> DisplayState {
        DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: id, localizedName: "Unmatched Display", vendorID: 7, productID: 8, serialNumber: 9)
            ],
            primaryDisplayID: id
        )
    }

    private func travelDisplayState(currentDisplayID: UInt32) -> DisplayState {
        DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: currentDisplayID, localizedName: "Travel Display", vendorID: 4, productID: 5, serialNumber: 6)
            ],
            primaryDisplayID: currentDisplayID
        )
    }

    private func deskSnapshot(name: String = "Desk") -> Snapshot {
        makeSnapshot(
            name: name,
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, localizedName: "Desk Display", vendorID: 1, productID: 2, serialNumber: 3)
            ]
        )
    }
}

@MainActor
private final class RecordingDisplayRestoreSuggestionPresenter: DisplayRestoreSuggestionPresenting {
    struct Suggestion {
        let snapshotName: String
        let restore: @MainActor () -> Void
    }

    struct Chooser {
        let options: [DisplayRestoreSuggestionOption]
        let restore: @MainActor (UUID) -> Void
    }

    private(set) var suggestions: [Suggestion] = []
    private(set) var choosers: [Chooser] = []
    private(set) var hideCount = 0
    private(set) var isDisplayRestoreSuggestionVisible = false

    func showDisplayRestoreSuggestion(
        snapshotName: String,
        restore: @escaping @MainActor () -> Void
    ) {
        isDisplayRestoreSuggestionVisible = true
        suggestions.append(Suggestion(snapshotName: snapshotName, restore: restore))
    }

    func showDisplayRestoreSuggestionChooser(
        options: [DisplayRestoreSuggestionOption],
        restore: @escaping @MainActor (UUID) -> Void
    ) {
        isDisplayRestoreSuggestionVisible = true
        choosers.append(Chooser(options: options, restore: restore))
    }

    func hideDisplayRestoreSuggestion() {
        isDisplayRestoreSuggestionVisible = false
        hideCount += 1
    }

    func simulateDismissal() {
        isDisplayRestoreSuggestionVisible = false
    }
}
