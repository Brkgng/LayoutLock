import Carbon
import Foundation
import XCTest
@testable import LayoutLock

@MainActor
final class SnapshotMenuControllerHotkeyTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        temporaryDirectoryURL = nil
    }

    func testAssignHotkeyKeepsRegistrationFailureStatus() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let hotkey = makeHotkey()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            hotkeyPrompt: { _, _ in hotkey }
        )
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        controller.assignHotkey(to: snapshotID)

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testAssignHotkeyReportsSuccessWhenRegistrationSucceeds() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let hotkey = makeHotkey()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            hotkeyPrompt: { _, _ in hotkey }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.assignHotkey(to: snapshotID)

        XCTAssertEqual(controller.status?.message, "Assigned Command-Option-K to \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testSetHotkeyPersistsBindingAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let hotkey = makeHotkey()
        let success = controller.setHotkey(hotkey, for: snapshotID)

        XCTAssertTrue(success)
        XCTAssertEqual(controller.snapshotSummaries.first?.hotkey?.displayString, "Command-Option-K")
        XCTAssertEqual(controller.status?.message, "Assigned Command-Option-K to \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testSetHotkeyReturnsFalseWhenRegistrationFails() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        let hotkey = makeHotkey()
        let success = controller.setHotkey(hotkey, for: snapshotID)

        XCTAssertFalse(success)
        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testSetHotkeyReturnsFalseWhenSnapshotNotFound() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = SnapshotMenuController(snapshotStore: store)

        let hotkey = makeHotkey()
        let success = controller.setHotkey(hotkey, for: UUID())

        XCTAssertFalse(success)
        XCTAssertEqual(controller.status?.message, "The layout could not be found.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testSetHotkeyReturnsFalseWhenStoreUnavailable() throws {
        let controller = SnapshotMenuController()

        let hotkey = makeHotkey()
        let success = controller.setHotkey(hotkey, for: UUID())

        XCTAssertFalse(success)
        XCTAssertEqual(controller.status?.message, "Layout storage is unavailable.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testClearHotkeyKeepsRegistrationFailureStatus() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            hotkey: makeHotkey()
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        controller.clearHotkey(for: snapshotID)

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testCaptureCurrentSnapshotKeepsRegistrationFailureStatus() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" }
        )
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        let task = controller.captureCurrentSnapshot()
        await task?.value

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testCaptureCurrentSnapshotReportsSuccessWhenRegistrationSucceeds() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()
        await task?.value

        XCTAssertEqual(controller.status?.message, "Saved \"Coding\" with 1 window.")
        XCTAssertEqual(controller.status?.isError, false)
        XCTAssertEqual(controller.lastCapturedSnapshotID, controller.snapshotSummaries.first?.id)
    }

    func testSuggestedSnapshotNameForCaptureDoesNotShowStandalonePrompt() {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        var didPrompt = false
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in
                didPrompt = true
                return "Prompted Layout"
            }
        )

        let suggestedName = controller.suggestedSnapshotNameForCapture()

        XCTAssertTrue(suggestedName?.hasPrefix("Layout - ") == true)
        XCTAssertFalse(didPrompt)
        XCTAssertFalse(controller.isOperating)
    }

    func testCaptureCurrentSnapshotNamedBypassesStandalonePrompt() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        var didPrompt = false
        var capturedName: String?
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in
                didPrompt = true
                return "Prompted Layout"
            },
            snapshotCapture: { name in
                capturedName = name
                let snapshot = self.makeSnapshot(id: UUID(), name: name, windows: [
                    self.makeWindow(bundleIdentifier: "com.example.editor")
                ])
                try store.save(snapshot)
                return snapshot
            },
            operationOverlayPresenter: overlayPresenter
        )

        let task = controller.captureCurrentSnapshot(named: "Dashboard Layout")
        await task?.value

        XCTAssertFalse(didPrompt)
        XCTAssertEqual(capturedName, "Dashboard Layout")
        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Dashboard Layout")
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testCaptureCurrentSnapshotReportsEmptyCaptureErrorWithoutSaving() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeEmptySnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" }
        )

        let task = controller.captureCurrentSnapshot()
        await task?.value

        XCTAssertTrue(controller.snapshotSummaries.isEmpty)
        XCTAssertNil(controller.lastCapturedSnapshotID)
        XCTAssertEqual(
            controller.status?.message,
            SnapshotCaptureServiceError.noWindowsAvailable.localizedDescription
        )
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testCaptureCurrentSnapshotSetsOperatingImmediatelyAfterPromptConfirmation() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = makeCaptureController(store: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()

        XCTAssertTrue(controller.isOperating)
        XCTAssertEqual(controller.status?.message, "Saving...")

        await task?.value
    }

    func testCaptureCurrentSnapshotReturnsNilWhenAlreadyOperating() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeCaptureController(
            store: store,
            overlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let firstTask = controller.captureCurrentSnapshot()
        let secondTask = controller.captureCurrentSnapshot(named: "Second Layout")

        XCTAssertNil(secondTask)
        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])

        await firstTask?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
        XCTAssertTrue(overlayPresenter.restoreCompletionSummaries.isEmpty)
    }

    func testCaptureCurrentSnapshotClearsOperatingAfterSuccess() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let controller = makeCaptureController(store: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()
        await task?.value

        XCTAssertFalse(controller.isOperating)
    }

    func testNamedCaptureClearsOperatingAfterCaptureError() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" },
            snapshotCapture: { _ in
                throw NSError(
                    domain: "LayoutLockTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Capture failed."]
                )
            },
            operationOverlayPresenter: overlayPresenter
        )

        let task = controller.captureCurrentSnapshot(named: "Dashboard Layout")
        await task?.value

        XCTAssertFalse(controller.isOperating)
        XCTAssertEqual(controller.status?.message, "Capture failed.")
        XCTAssertEqual(controller.status?.isError, true)
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testCaptureCurrentSnapshotShowsAndHidesSaveOverlayAfterSuccess() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeCaptureController(
            store: store,
            overlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()

        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])

        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testCaptureCurrentSnapshotWaitsForSaveOverlayBeforeCapturing() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = SuspendingOperationOverlayPresenter()
        var didBeginCapture = false
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" },
            snapshotCapture: { name in
                didBeginCapture = true
                let snapshot = self.makeSnapshot(id: UUID(), name: name, windows: [
                    self.makeWindow(bundleIdentifier: "com.example.editor")
                ])
                try store.save(snapshot)
                return snapshot
            },
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()
        await Task.yield()

        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertFalse(didBeginCapture)
        XCTAssertEqual(overlayPresenter.hideCount, 0)

        overlayPresenter.resumeShowOverlay()
        await task?.value

        XCTAssertTrue(didBeginCapture)
        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testCaptureCurrentSnapshotDoesNotHideOverlayBeforeCaptureFinishes() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let captureStarted = expectation(description: "capture started")
        let allowCaptureToFinish = DispatchSemaphore(value: 0)
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" },
            snapshotCapture: { name in
                captureStarted.fulfill()
                allowCaptureToFinish.wait()
                let snapshot = self.makeSnapshot(id: UUID(), name: name, windows: [
                    self.makeWindow(bundleIdentifier: "com.example.editor")
                ])
                try store.save(snapshot)
                return snapshot
            },
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.captureCurrentSnapshot()
        await fulfillment(of: [captureStarted], timeout: 1)

        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertEqual(overlayPresenter.hideCount, 0)

        allowCaptureToFinish.signal()
        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testUpdateSnapshotReportsSuccessWhenRegistrationSucceeds() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [makeWindow(bundleIdentifier: "com.example.editor")]
        ))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store)
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        XCTAssertEqual(controller.status?.message, "Saving...")
        await task?.value

        XCTAssertEqual(controller.snapshotSummaries.first?.windowCount, 1)
        XCTAssertEqual(controller.status?.message, "Updated \"Coding\" with 1 window.")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testUpdateSnapshotReportsUnmatchedManualOpeningTargets() async throws {
        let snapshotID = UUID()
        let manualTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        let windows = [
            makeWindow(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            ).withOpeningConfiguration(
                WindowOpeningConfiguration(manualTargets: [manualTarget])
            ),
            makeWindow(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            )
        ]
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: windows,
            displays: [makeDisplayRecord()],
            primaryDisplayID: 1
        ))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(
                store: store,
                discoveryResultProvider: {
                    WindowDiscoveryResult(
                        applications: [
                            DiscoveredApplication(
                                bundleIdentifier: "com.example.editor",
                                pid: 42,
                                localizedName: "Editor",
                                windows: [
                                    makeDiscoveredWindow(title: "Same"),
                                    makeDiscoveredWindow(title: "Same")
                                ]
                            )
                        ],
                        diagnostics: []
                    )
                }
            )
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            controller.status?.message,
            "Updated \"Coding\" with 2 windows. 1 manual opening-target configuration could not be matched and needs review."
        )
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testUpdateSnapshotShowsSaveOverlayImmediately() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)

        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])

        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testUpdateSnapshotWaitsForSaveOverlayBeforeCapturing() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = SuspendingOperationOverlayPresenter()
        var didBeginCapture = false
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(
                store: store,
                discoveryResultProvider: {
                    didBeginCapture = true
                    return self.makeWindowDiscoveryResult()
                }
            ),
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        await Task.yield()

        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertFalse(didBeginCapture)
        XCTAssertEqual(overlayPresenter.hideCount, 0)

        overlayPresenter.resumeShowOverlay()
        await task?.value

        XCTAssertTrue(didBeginCapture)
        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testUpdateSnapshotDoesNotHideOverlayBeforeCaptureFinishes() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let captureStarted = expectation(description: "update capture started")
        let allowCaptureToFinish = DispatchSemaphore(value: 0)
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(
                store: store,
                discoveryResultProvider: {
                    captureStarted.fulfill()
                    allowCaptureToFinish.wait()
                    return self.makeWindowDiscoveryResult()
                }
            ),
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        await fulfillment(of: [captureStarted], timeout: 1)

        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertEqual(overlayPresenter.hideCount, 0)

        allowCaptureToFinish.signal()
        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testUpdateSnapshotReportsEmptyCaptureErrorAndKeepsExistingSnapshot() async throws {
        let snapshotID = UUID()
        let originalWindow = makeWindow(bundleIdentifier: "com.example.editor")
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [originalWindow]
        ))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeEmptySnapshotCaptureService(store: store)
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        await task?.value

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [originalWindow.id])
        XCTAssertEqual(controller.snapshotSummaries.first?.windowCount, 1)
        XCTAssertEqual(
            controller.status?.message,
            SnapshotCaptureServiceError.noWindowsAvailable.localizedDescription
        )
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testUpdateSnapshotReturnsNilWhenAlreadyOperating() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            operationOverlayPresenter: overlayPresenter
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let firstTask = controller.updateSnapshot(id: snapshotID)
        let secondTask = controller.updateSnapshot(id: snapshotID)

        XCTAssertNil(secondTask)
        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])

        await firstTask?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testUpdateSnapshotReportsUnavailableStorage() {
        let controller = SnapshotMenuController()

        let task = controller.updateSnapshot(id: UUID())

        XCTAssertNil(task)
        XCTAssertEqual(controller.status?.message, "Layout storage is unavailable.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testUpdateSnapshotKeepsRegistrationFailureStatus() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store)
        )
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        let task = controller.updateSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testUpdateSnapshotClearsOperatingAfterSuccess() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store)
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        let task = controller.updateSnapshot(id: snapshotID)
        await task?.value

        XCTAssertFalse(controller.isOperating)
    }

    func testUpdateSnapshotClearsOperatingAfterCaptureError() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeFailingSnapshotCaptureService(store: store),
            captureContextProvider: {
                SnapshotCaptureService.CaptureContext(
                    runningApplications: [],
                    screens: []
                )
            },
            operationOverlayPresenter: overlayPresenter
        )

        let task = controller.updateSnapshot(id: snapshotID)
        await task?.value

        XCTAssertFalse(controller.isOperating)
        XCTAssertEqual(
            controller.status?.message,
            SnapshotCaptureServiceError.noDisplaysAvailable.localizedDescription
        )
        XCTAssertEqual(controller.status?.isError, true)
        XCTAssertEqual(overlayPresenter.shownKinds, [.save])
        XCTAssertEqual(overlayPresenter.hideCount, 1)
    }

    func testCaptureCurrentSnapshotDoesNotShowOverlayWhenNamePromptIsCancelled() {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let overlayPresenter = RecordingOperationOverlayPresenter()
        var didCapture = false
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in nil },
            snapshotCapture: { _ in
                didCapture = true
                return self.makeSnapshot(id: UUID(), name: "Coding")
            },
            operationOverlayPresenter: overlayPresenter
        )

        let task = controller.captureCurrentSnapshot()

        XCTAssertNil(task)
        XCTAssertTrue(overlayPresenter.shownKinds.isEmpty)
        XCTAssertEqual(overlayPresenter.hideCount, 0)
        XCTAssertFalse(didCapture)
        XCTAssertTrue(controller.snapshotSummaries.isEmpty)
    }

    func testCaptureCurrentSnapshotPromptsBeforeCapturingWithDefaultName() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        var events: [String] = []
        var defaultName: String?
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: {
                defaultName = $0
                events.append("prompt")
                return "Coding"
            },
            snapshotCapture: { name in
                events.append("capture")
                let snapshot = self.makeSnapshot(id: UUID(), name: name)
                try store.save(snapshot)
                return snapshot
            }
        )

        let task = controller.captureCurrentSnapshot()

        XCTAssertEqual(events, ["prompt"])
        XCTAssertTrue(defaultName?.hasPrefix("Layout - ") == true)

        await task?.value

        XCTAssertEqual(events, ["prompt", "capture"])
        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Coding")
    }

    func testCaptureCurrentSnapshotReturnsNilWhenOperationStartsDuringNamePrompt() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let trustChecker = AccessibilityTrustChecker { true }
        let restoreEngine = RestoreEngine(
            snapshotStore: store,
            windowDiscoveryEngine: WindowDiscoveryEngine(trustChecker: trustChecker),
            trustChecker: trustChecker,
            displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: NoOpRestoreApplicationLauncher(),
            discoveredApplicationsProvider: { [] },
            runningApplicationBundleProvider: { [] }
        )
        var controller: SnapshotMenuController!
        var restoreTask: Task<Void, Never>?
        var didCapture = false
        controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            restoreEngine: restoreEngine,
            snapshotNamePrompt: { _ in
                restoreTask = controller.restoreSnapshot(id: snapshotID)
                return "Coding"
            },
            snapshotCapture: { name in
                didCapture = true
                return Snapshot(
                    id: UUID(),
                    name: name,
                    createdAt: Date(timeIntervalSince1970: 200),
                    updatedAt: Date(timeIntervalSince1970: 200),
                    sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil),
                    windows: []
                )
            },
            operationOverlayPresenter: overlayPresenter
        )

        let saveTask = controller.captureCurrentSnapshot()

        XCTAssertNil(saveTask)
        XCTAssertFalse(didCapture)
        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.restore])

        await restoreTask?.value

        XCTAssertEqual(overlayPresenter.hideCount, 0)
        XCTAssertEqual(overlayPresenter.restoreCompletionSummaries.count, 1)
    }

    func testRestoreSnapshotShowsCompletionAfterSuccess() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter
        )

        let task = controller.restoreSnapshot(id: snapshotID)

        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.restore])

        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 0)
        XCTAssertEqual(overlayPresenter.restoreCompletionSummaries, ["Restored \"Coding\": 0 windows restored."])
        XCTAssertEqual(overlayPresenter.restoreCompletionDetails, [nil])
    }

    func testRestoreSnapshotCompletionIncludesDisplayFallbackCount() async throws {
        let snapshotID = UUID()
        let savedDisplay = makeDisplayRecord(
            id: 3,
            localizedName: "Removed",
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 700),
            isPrimary: false,
            vendorID: 3,
            productID: 30,
            serialNumber: 300
        )
        let currentPrimaryDisplay = makeDisplayRecord(
            id: 1,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 860),
            isPrimary: true
        )
        let savedWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            displayID: savedDisplay.id
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Desk",
            windows: [savedWindow],
            displays: [savedDisplay],
            primaryDisplayID: savedDisplay.id
        ))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter,
            screenProvider: { [self.makeScreenSnapshot(from: currentPrimaryDisplay)] },
            discoveredApplicationsProvider: {
                [
                    DiscoveredApplication(
                        bundleIdentifier: savedWindow.bundleIdentifier,
                        pid: savedWindow.pidAtCapture,
                        localizedName: "Editor",
                        windows: [
                            makeDiscoveredWindow(
                                title: savedWindow.windowTitle,
                                role: savedWindow.role,
                                subrole: savedWindow.subrole,
                                frame: savedWindow.frame.cgRect
                            )
                        ]
                    )
                ]
            }
        )

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            overlayPresenter.restoreCompletionSummaries,
            ["Restored \"Desk\": 1 window restored, 1 display fallback."]
        )
        XCTAssertEqual(overlayPresenter.restoreCompletionDetails, [nil])
        XCTAssertEqual(
            controller.status?.message,
            "Restored \"Desk\": 1 window restored, 1 display fallback."
        )
    }

    func testRestoreSnapshotShowsAndHidesOverlayAfterFailure() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            isTrusted: false,
            overlayPresenter: overlayPresenter
        )

        let task = controller.restoreSnapshot(id: snapshotID)

        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.restore])

        await task?.value

        XCTAssertEqual(overlayPresenter.hideCount, 1)
        XCTAssertTrue(overlayPresenter.restoreCompletionSummaries.isEmpty)
    }

    func testRestoreSnapshotCompletionIncludesSkippedWindowDetails() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(
            makeSnapshot(
                id: snapshotID,
                name: "Coding",
                windows: [
                    makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "ScrollSnap"),
                    makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "Settings"),
                    makeWindow(bundleIdentifier: "com.example.browser", windowTitle: "   ")
                ]
            )
        )
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter,
            appNameResolver: { bundleIdentifier in
                [
                    "com.example.editor": "Editor",
                    "com.example.browser": "Browser"
                ][bundleIdentifier] ?? bundleIdentifier
            }
        )

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            overlayPresenter.restoreCompletionSummaries,
            ["Restored \"Coding\": 0 windows restored, 3 skipped."]
        )
        XCTAssertEqual(
            overlayPresenter.restoreCompletionDetails,
            ["Editor (ScrollSnap)\nEditor (Settings)\nBrowser"]
        )
        XCTAssertEqual(controller.status?.message, "Restored \"Coding\": 0 windows restored, 3 skipped.")
    }

    func testRestoreSnapshotCompletionLimitsSkippedWindowDetails() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(
            makeSnapshot(
                id: snapshotID,
                name: "Coding",
                windows: (1...7).map {
                    makeWindow(
                        bundleIdentifier: "com.example.editor",
                        windowTitle: "Window \($0)"
                    )
                }
            )
        )
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter,
            appNameResolver: { _ in "Editor" }
        )

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            overlayPresenter.restoreCompletionDetails,
            ["Editor (Window 1)\nEditor (Window 2)\nEditor (Window 3)\nEditor (Window 4)\nEditor (Window 5)\nand 2 more skipped"]
        )
    }

    func testRestoreSnapshotCompletionReportsTargetIssuesSeparatelyFromSkippedWindows() async throws {
        let snapshotID = UUID()
        let missingURL = temporaryDirectoryURL.appendingPathComponent("Missing Project.xcodeproj")
        let target = WindowOpenTarget(kind: .folder, url: missingURL)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(
            makeSnapshot(
                id: snapshotID,
                name: "Coding",
                windows: [
                    makeWindow(
                        bundleIdentifier: "com.example.editor",
                        windowTitle: "Project",
                        openingConfiguration: WindowOpeningConfiguration(
                            manualTargets: [target]
                        )
                    )
                ]
            )
        )
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter,
            appNameResolver: { _ in "Editor" }
        )

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            overlayPresenter.restoreCompletionSummaries,
            ["Restored \"Coding\": 0 windows restored, 1 skipped, 1 target issue."]
        )
        XCTAssertEqual(
            overlayPresenter.restoreCompletionDetails,
            [
                "Editor (\(missingURL.path)): Target no longer exists.\nEditor (Project)"
            ]
        )
        XCTAssertEqual(
            controller.status?.message,
            "Restored \"Coding\": 0 windows restored, 1 skipped, 1 target issue."
        )
    }

    func testRestoreSnapshotCompletionShowsUnsupportedWebURL() async throws {
        let snapshotID = UUID()
        let targetURL = try XCTUnwrap(URL(string: "ftp://example.com/private"))
        let target = WindowOpenTarget(kind: .webURL, url: targetURL)
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(
            makeSnapshot(
                id: snapshotID,
                name: "Browsing",
                windows: [
                    makeWindow(
                        bundleIdentifier: "com.example.browser",
                        windowTitle: "Private",
                        openingConfiguration: WindowOpeningConfiguration(
                            manualTargets: [target]
                        )
                    )
                ]
            )
        )
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter,
            appNameResolver: { _ in "Browser" }
        )

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertEqual(
            overlayPresenter.restoreCompletionSummaries,
            ["Restored \"Browsing\": 0 windows restored, 1 skipped, 1 target issue."]
        )
        XCTAssertEqual(
            overlayPresenter.restoreCompletionDetails,
            [
                "Browser (\(targetURL.absoluteString)): Only HTTP and HTTPS URLs can be opened.\nBrowser (Private)"
            ]
        )
    }

    func testRestoreSnapshotDoesNotShowOverlayWhenAlreadyOperating() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let overlayPresenter = RecordingOperationOverlayPresenter()
        let controller = makeRestoreController(
            store: store,
            overlayPresenter: overlayPresenter
        )

        let firstTask = controller.restoreSnapshot(id: snapshotID)
        let secondTask = controller.restoreSnapshot(id: snapshotID)

        XCTAssertNil(secondTask)
        await Task.yield()
        XCTAssertEqual(overlayPresenter.shownKinds, [.restore])

        await firstTask?.value

        XCTAssertEqual(overlayPresenter.hideCount, 0)
        XCTAssertEqual(overlayPresenter.restoreCompletionSummaries.count, 1)
    }

    func testRestoreSnapshotPublishesCompletionIDAfterSuccess() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = makeRestoreController(store: store)

        XCTAssertNil(controller.restoreCompletionID)

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertNotNil(controller.restoreCompletionID)
    }

    func testRestoreSnapshotDoesNotPublishCompletionIDAfterFailure() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = makeRestoreController(store: store, isTrusted: false)

        XCTAssertNil(controller.restoreCompletionID)

        let task = controller.restoreSnapshot(id: snapshotID)
        await task?.value

        XCTAssertNil(controller.restoreCompletionID)
    }

    func testRestoreSnapshotPublishesDistinctCompletionIDsForRepeatedRestores() async throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = makeRestoreController(store: store)

        let firstTask = controller.restoreSnapshot(id: snapshotID)
        await firstTask?.value
        let firstID = controller.restoreCompletionID

        let secondTask = controller.restoreSnapshot(id: snapshotID)
        await secondTask?.value
        let secondID = controller.restoreCompletionID

        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testRenameSnapshotUpdatesSummaryAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotRenamePrompt: { _ in "Writing" }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.renameSnapshot(id: snapshotID)

        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Writing")
        XCTAssertEqual(controller.status?.message, "Renamed \"Coding\" to \"Writing\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testRenameSnapshotReportsInvalidName() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotRenamePrompt: { _ in "" }
        )

        controller.renameSnapshot(id: snapshotID)

        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Coding")
        XCTAssertEqual(controller.status?.message, "Layout names cannot be empty.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testRenameSnapshotInlineUpdatesSummaryAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let success = controller.renameSnapshotInline(id: snapshotID, newName: "Writing")

        XCTAssertTrue(success)
        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Writing")
        XCTAssertEqual(controller.status?.message, "Renamed \"Coding\" to \"Writing\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testRenameSnapshotInlineReportsInvalidName() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)

        let success = controller.renameSnapshotInline(id: snapshotID, newName: "   ")

        XCTAssertFalse(success)
        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Coding")
        XCTAssertEqual(controller.status?.message, "Layout names cannot be empty.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testRenameSnapshotInlineReturnsSuccessWhenRegistrationFails() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        let registrationError = makeRegistrationError()
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        let success = controller.renameSnapshotInline(id: snapshotID, newName: "Writing")

        XCTAssertTrue(success)
        XCTAssertEqual(controller.snapshotSummaries.first?.name, "Writing")
        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testDeleteSnapshotRemovesSummaryAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.deleteSnapshot(id: snapshotID)

        XCTAssertTrue(controller.snapshotSummaries.isEmpty)
        XCTAssertEqual(controller.status?.message, "Deleted \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testRemoveWindowUpdatesSummaryAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let firstEditorWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "One"
        )
        let browserWindow = makeWindow(
            bundleIdentifier: "com.example.browser",
            windowTitle: "Two"
        )
        let secondEditorWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Three"
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                firstEditorWindow,
                browserWindow,
                secondEditorWindow
            ]
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.removeWindow(
            windowID: firstEditorWindow.id,
            windowTitle: firstEditorWindow.windowTitle,
            appName: "Editor",
            from: snapshotID
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(controller.snapshotSummaries.first?.appCount, 2)
        XCTAssertEqual(controller.snapshotSummaries.first?.windowCount, 2)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [
            browserWindow.id,
            secondEditorWindow.id
        ])
        XCTAssertEqual(controller.status?.message, "Removed \"One\" from \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testRemoveWindowAllowsRemovingLastWindowOnDisplay() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let displayWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Editor",
            displayID: 1
        )
        let otherDisplayWindow = makeWindow(
            bundleIdentifier: "com.example.browser",
            windowTitle: "Browser",
            displayID: 2
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                displayWindow,
                otherDisplayWindow
            ]
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.removeWindow(
            windowID: displayWindow.id,
            windowTitle: displayWindow.windowTitle,
            appName: "Editor",
            from: snapshotID
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(controller.snapshotSummaries.first?.windowCount, 1)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [otherDisplayWindow.id])
        XCTAssertEqual(controller.status?.message, "Removed \"Editor\" from \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testRemoveWindowRejectsRemovingFinalWindow() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let onlyWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Editor"
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [onlyWindow]
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.removeWindow(
            windowID: onlyWindow.id,
            windowTitle: onlyWindow.windowTitle,
            appName: "Editor",
            from: snapshotID
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(controller.snapshotSummaries.first?.windowCount, 1)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [onlyWindow.id])
        XCTAssertEqual(
            controller.status?.message,
            "A layout must keep at least one saved window. Delete the layout instead."
        )
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testReorderWindowsUpdatesSnapshotAndReportsSuccess() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let frontWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Front",
            displayID: 1,
            zOrderHint: 1
        )
        let backWindow = makeWindow(
            bundleIdentifier: "com.example.browser",
            windowTitle: "Back",
            displayID: 1,
            zOrderHint: 2
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                frontWindow,
                backWindow
            ]
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let didReorder = controller.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [
                backWindow.id,
                frontWindow.id
            ],
            in: snapshotID
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        let zOrderHintsByID = Dictionary(uniqueKeysWithValues: loadedSnapshot.windows.map { ($0.id, $0.zOrderHint) })
        XCTAssertTrue(didReorder)
        XCTAssertEqual(zOrderHintsByID[backWindow.id], 1)
        XCTAssertEqual(zOrderHintsByID[frontWindow.id], 2)
        XCTAssertEqual(controller.status?.message, "Updated restore order for \"Coding\".")
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testReorderWindowsReturnsFalseWhenStorageUnavailable() {
        let controller = SnapshotMenuController()

        let didReorder = controller.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [UUID()],
            in: UUID()
        )

        XCTAssertFalse(didReorder)
        XCTAssertEqual(controller.status?.message, "Layout storage is unavailable.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testReorderWindowsReportsInvalidOrder() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let window = makeWindow(
            bundleIdentifier: "com.example.editor",
            displayID: 1,
            zOrderHint: 1
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [window]
        ))
        let controller = SnapshotMenuController(snapshotStore: store)
        controller.setSnapshotSummariesDidChange { _ in nil }

        let didReorder = controller.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [window.id, UUID()],
            in: snapshotID
        )

        XCTAssertFalse(didReorder)
        XCTAssertEqual(
            controller.status?.message,
            "Window order must include each saved window for that display exactly once."
        )
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testRenameSnapshotKeepsRegistrationFailureStatus() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            snapshotRenamePrompt: { _ in "Writing" }
        )
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        controller.renameSnapshot(id: snapshotID)

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testDeleteSnapshotKeepsRegistrationFailureStatus() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)
        var registrationError: Error?
        controller.setSnapshotSummariesDidChange { _ in registrationError }

        registrationError = makeRegistrationError()
        controller.deleteSnapshot(id: snapshotID)

        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testLoadSnapshotReturnsStoredSnapshot() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let controller = SnapshotMenuController(snapshotStore: store)

        let snapshot = controller.loadSnapshot(id: snapshotID)

        XCTAssertEqual(snapshot?.id, snapshotID)
        XCTAssertEqual(snapshot?.name, "Coding")
    }

    func testSetOpeningTargetsWithoutProEntitlement() throws {
        let snapshotID = UUID()
        let automaticTarget = WindowOpenTarget(
            kind: .folder,
            url: temporaryDirectoryURL
        )
        let window = makeWindow(
            bundleIdentifier: "com.example.editor"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [automaticTarget]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [window]
        ))
        let controller = SnapshotMenuController(
            snapshotStore: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )
        controller.setSnapshotSummariesDidChange { _ in nil }
        let manualTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )

        XCTAssertTrue(
            controller.setOpeningTargets(
                [manualTarget],
                for: window.id,
                in: snapshotID
            )
        )
        XCTAssertEqual(
            try store.loadSnapshot(id: snapshotID)
                .windows.first?
                .openingConfiguration.manualTargets,
            [manualTarget]
        )
    }

    func testAssignHotkeyEntersAndExitsCaptureSuspension() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let hotkey = makeHotkey()
        var captureActivityLog: [Bool] = []
        let controller = SnapshotMenuController(
            snapshotStore: store,
            hotkeyPrompt: { _, _ in hotkey }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }
        controller.setHotkeyCaptureActivityDidChange { isActive in
            captureActivityLog.append(isActive)
            return nil
        }

        controller.assignHotkey(to: snapshotID)

        XCTAssertEqual(captureActivityLog, [true, false])
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testAssignHotkeyExitsSuspensionWhenPromptCancelled() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        var captureActivityLog: [Bool] = []
        let controller = SnapshotMenuController(
            snapshotStore: store,
            hotkeyPrompt: { _, _ in nil }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }
        controller.setHotkeyCaptureActivityDidChange { isActive in
            captureActivityLog.append(isActive)
            return nil
        }

        controller.assignHotkey(to: snapshotID)

        XCTAssertEqual(captureActivityLog, [true, false])
    }

    func testAssignHotkeyReportsErrorAndSkipsPromptWhenEnteringSuspensionFails() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let suspensionError = makeRegistrationError()
        var didOpenPrompt = false
        let controller = SnapshotMenuController(
            snapshotStore: store,
            hotkeyPrompt: { _, _ in
                didOpenPrompt = true
                return nil
            }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }
        controller.setHotkeyCaptureActivityDidChange { isActive in
            isActive ? suspensionError : nil
        }

        controller.assignHotkey(to: snapshotID)

        XCTAssertFalse(didOpenPrompt)
        XCTAssertEqual(controller.status?.message, "Hotkey registration failed.")
        XCTAssertEqual(controller.status?.isError, true)
    }

    private func makeSnapshot(
        id: UUID,
        name: String,
        windows: [WindowRecord] = [],
        hotkey: HotkeyBinding? = nil,
        displays: [DisplayRecord] = [],
        primaryDisplayID: UInt32? = nil
    ) -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            sourceDisplayState: DisplayState(displays: displays, primaryDisplayID: primaryDisplayID),
            windows: windows,
            hotkey: hotkey
        )
    }

    private func makeWindow(
        id: UUID = UUID(),
        bundleIdentifier: String,
        windowTitle: String? = "Window",
        displayID: UInt32? = nil,
        zOrderHint: Int? = nil,
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration()
    ) -> WindowRecord {
        WindowRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 1,
            windowTitle: windowTitle,
            role: "AXWindow",
            subrole: nil,
            frame: CGRectCodable(x: 10, y: 10, width: 400, height: 300),
            displayID: displayID,
            normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 0.2, heightRatio: 0.2),
            zOrderHint: zOrderHint,
            isMinimized: false,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: 1,
                windowTitle: windowTitle,
                role: "AXWindow",
                subrole: nil,
                capturedFrame: CGRectCodable(x: 10, y: 10, width: 400, height: 300),
                cgWindowID: nil
            ),
            openingConfiguration: openingConfiguration
        )
    }

    private func makeCaptureController(
        store: SnapshotStore,
        overlayPresenter: OperationOverlayPresenting = NoOpOperationOverlayPresenter()
    ) -> SnapshotMenuController {
        SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            snapshotNamePrompt: { _ in "Coding" },
            operationOverlayPresenter: overlayPresenter
        )
    }

    private func makeWindowDiscoveryResult() -> WindowDiscoveryResult {
        let window = makeDiscoveredWindow()
        let application = DiscoveredApplication(
            bundleIdentifier: "com.example.editor",
            pid: 42,
            localizedName: "Editor",
            windows: [window]
        )

        return WindowDiscoveryResult(applications: [application], diagnostics: [])
    }

    private func makeSnapshotCaptureService(
        store: SnapshotStore,
        discoveryResultProvider: (() throws -> WindowDiscoveryResult)? = nil
    ) -> SnapshotCaptureService {
        let display = makeDisplayRecord()
        return SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [
                    DisplayResolver.ScreenSnapshot(
                        id: display.id,
                        localizedName: display.localizedName,
                        frame: display.frameRect,
                        visibleFrame: display.visibleFrameRect,
                        backingScaleFactor: display.backingScaleFactor,
                        isPrimary: display.isPrimary,
                        vendorID: display.vendorID,
                        productID: display.productID,
                        serialNumber: display.serialNumber
                    )
                ]
            }),
            snapshotStore: store,
            discoveryResultProvider: discoveryResultProvider ?? makeWindowDiscoveryResult
        )
    }

    private func makeEmptySnapshotCaptureService(store: SnapshotStore) -> SnapshotCaptureService {
        let display = makeDisplayRecord()
        return SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [
                    DisplayResolver.ScreenSnapshot(
                        id: display.id,
                        localizedName: display.localizedName,
                        frame: display.frameRect,
                        visibleFrame: display.visibleFrameRect,
                        backingScaleFactor: display.backingScaleFactor,
                        isPrimary: display.isPrimary,
                        vendorID: display.vendorID,
                        productID: display.productID,
                        serialNumber: display.serialNumber
                    )
                ]
            }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )
    }

    private func makeFailingSnapshotCaptureService(store: SnapshotStore) -> SnapshotCaptureService {
        SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { [] }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )
    }

    private func makeRestoreController(
        store: SnapshotStore,
        isTrusted: Bool = true,
        overlayPresenter: OperationOverlayPresenting = NoOpOperationOverlayPresenter(),
        appNameResolver: @escaping SnapshotMenuController.AppNameResolver = { $0 },
        screenProvider: @escaping () -> [DisplayResolver.ScreenSnapshot] = { [] },
        discoveredApplicationsProvider: @escaping () throws -> [DiscoveredApplication] = { [] },
        windowApplier: RestoreWindowApplying = RestoringWindowApplier()
    ) -> SnapshotMenuController {
        let trustChecker = AccessibilityTrustChecker { isTrusted }
        let restoreEngine = RestoreEngine(
            snapshotStore: store,
            windowDiscoveryEngine: WindowDiscoveryEngine(trustChecker: trustChecker),
            trustChecker: trustChecker,
            windowApplier: windowApplier,
            displayResolver: DisplayResolver(screenProvider: screenProvider),
            applicationLauncher: NoOpRestoreApplicationLauncher(),
            applicationActivator: NoOpRestoreApplicationActivator(),
            discoveredApplicationsProvider: discoveredApplicationsProvider,
            runningApplicationBundleProvider: { [] }
        )

        return SnapshotMenuController(
            snapshotStore: store,
            restoreEngine: restoreEngine,
            appNameResolver: appNameResolver,
            operationOverlayPresenter: overlayPresenter
        )
    }

    private func makeHotkey() -> HotkeyBinding {
        HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "Command-Option-K"
        )
    }

    private func makeScreenSnapshot(from display: DisplayRecord) -> DisplayResolver.ScreenSnapshot {
        DisplayResolver.ScreenSnapshot(
            id: display.id,
            localizedName: display.localizedName,
            frame: display.frameRect,
            visibleFrame: display.visibleFrameRect,
            backingScaleFactor: display.backingScaleFactor,
            isPrimary: display.isPrimary,
            vendorID: display.vendorID,
            productID: display.productID,
            serialNumber: display.serialNumber
        )
    }

    private func makeRegistrationError() -> Error {
        NSError(
            domain: "LayoutLockTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Hotkey registration failed."]
        )
    }

    func testStatusAutoClearsAfterDelay() async throws {
        let controller = SnapshotMenuController(statusAutoClearDelay: 0.1)

        controller.deleteSnapshot(id: UUID())
        XCTAssertNotNil(controller.status)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(controller.status)
    }
}

@MainActor
private final class RecordingOperationOverlayPresenter: OperationOverlayPresenting {
    private(set) var shownKinds: [OperationOverlayKind] = []
    private(set) var restoreCompletionSummaries: [String] = []
    private(set) var restoreCompletionDetails: [String?] = []
    private(set) var hideCount = 0

    func showOverlay(kind: OperationOverlayKind) async {
        shownKinds.append(kind)
    }

    func showRestoreCompletion(summary: String, detail: String?) {
        restoreCompletionSummaries.append(summary)
        restoreCompletionDetails.append(detail)
    }

    func hideOverlay() {
        hideCount += 1
    }
}

@MainActor
private final class SuspendingOperationOverlayPresenter: OperationOverlayPresenting {
    private(set) var shownKinds: [OperationOverlayKind] = []
    private(set) var hideCount = 0
    private var showOverlayContinuation: CheckedContinuation<Void, Never>?

    func showOverlay(kind: OperationOverlayKind) async {
        shownKinds.append(kind)
        await withCheckedContinuation { continuation in
            showOverlayContinuation = continuation
        }
    }

    func resumeShowOverlay() {
        showOverlayContinuation?.resume()
        showOverlayContinuation = nil
    }

    func showRestoreCompletion(summary _: String, detail _: String?) {}

    func hideOverlay() {
        hideCount += 1
    }
}

private struct NoOpRestoreApplicationLauncher: RestoreApplicationLaunching {
    func requestLaunch(bundleIdentifier _: String) -> Bool {
        false
    }
}

private struct NoOpRestoreApplicationActivator: RestoreApplicationActivating {
    func activate(processIdentifier _: pid_t) -> Bool {
        false
    }
}

private final class RestoringWindowApplier: RestoreWindowApplying {
    func apply(
        savedWindow _: WindowRecord,
        targetFrame _: CGRect,
        to _: DiscoveredWindow
    ) -> RestoreWindowApplyResult {
        .restored()
    }

    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool {
        true
    }

    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult {
        RestoreWindowFocusResult(
            didRaise: true,
            didSetMain: true,
            didSetFocused: true
        )
    }
}
