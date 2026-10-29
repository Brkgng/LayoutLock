import ApplicationServices
import CoreGraphics
import XCTest
@testable import LayoutLock

final class SnapshotCaptureServiceTests: XCTestCase {
    func testCaptureExcludesUnrealUntitledUnknownPanels() throws {
        let windows = [
            makeDiscoveredWindow(title: "Project - Unreal Editor", cgWindowID: 100),
            makeDiscoveredWindow(title: "", subrole: "AXUnknown", cgWindowID: 101),
            makeDiscoveredWindow(title: "Output Log", subrole: "AXUnknown", cgWindowID: 102)
        ]
        let snapshot = try captureActiveWindows(windows, bundleIdentifier: "com.epicgames.UnrealEditor")

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [100, 102])
        XCTAssertEqual(try captureActiveWindows(windows).windows.count, 3,
            "Other apps can use AXUnknown for real windows.")
    }

    func testCaptureDoesNotSaveOnlyAnUnrealLoadingPanel() throws {
        XCTAssertThrowsError(try captureActiveWindows(
            [makeDiscoveredWindow(title: nil, subrole: "AXUnknown", cgWindowID: 100)],
            bundleIdentifier: "com.epicgames.UnrealEditor")) {
            guard case SnapshotCaptureServiceError.noWindowsAvailable = $0 else {
                return XCTFail("Expected no project windows, got \($0)")
            }
        }
    }

    func testCaptureKeepsMinimizedAndHiddenWindowsOnActiveSpace() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(isMinimized: true, isVisible: false, cgWindowID: 100, isOnScreen: false),
             makeDiscoveredWindow(isVisible: false, cgWindowID: 101, isOnScreen: false)],
            memberships: [100: [1], 101: [1]]
        )

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertTrue(snapshot.windows[0].isMinimized)
        XCTAssertTrue(snapshot.windows.allSatisfy { !$0.isVisible })
    }

    func testCaptureIncludesActiveSpacesAcrossDisplaysAndAllSpacesWindows() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(cgWindowID: 100),
             makeDiscoveredWindow(cgWindowID: 101),
             makeDiscoveredWindow(cgWindowID: 102),
             makeDiscoveredWindow(cgWindowID: 103)],
            memberships: [100: [1], 101: [3], 102: [1, 2, 3], 103: [2, 4]]
        )

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [100, 101, 102])
    }

    func testCaptureUsesSpaceMembershipOverVisibilityHint() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(cgWindowID: 100, isOnScreen: false),
             makeDiscoveredWindow(cgWindowID: 101, isOnScreen: true)],
            memberships: [100: [1], 101: [2]]
        )

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [100])
    }

    func testCaptureWithoutSpaceInventoryIncludesOnlyOnscreenWindows() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(title: "Onscreen", cgWindowID: 100, isOnScreen: true),
             makeDiscoveredWindow(title: "Offscreen", cgWindowID: 101, isOnScreen: false),
             makeDiscoveredWindow(title: "Unknown", cgWindowID: 102, isOnScreen: nil)],
            inventory: nil
        )

        XCTAssertEqual(snapshot.windows.map(\.windowTitle), ["Onscreen"])
    }

    func testCaptureWithUnknownMembershipIncludesOnlyOnscreenWindows() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(cgWindowID: 100, isOnScreen: true),
             makeDiscoveredWindow(cgWindowID: 101, isOnScreen: false),
             makeDiscoveredWindow(cgWindowID: 102, isOnScreen: nil),
             makeDiscoveredWindow(cgWindowID: 103, isOnScreen: true)],
            memberships: [103: []]
        )

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [100, 103])
    }

    func testCaptureDoesNotAppendUnexposedInactiveWindows() throws {
        let snapshot = try captureActiveWindows(
            [makeDiscoveredWindow(cgWindowID: 100)],
            memberships: [100: [1], 201: [2]],
            unexposedWindows: [cgCandidate(id: 201)]
        )

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [100])
    }

    func testCaptureWithOnlyInactiveWindowsDoesNotSave() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let service = activeSpaceCaptureService(
            store: store,
            windows: [makeDiscoveredWindow(cgWindowID: 100)],
            memberships: [100: [2]]
        )

        XCTAssertThrowsError(try service.captureSnapshot(named: "Inactive")) {
            guard case SnapshotCaptureServiceError.noWindowsAvailable = $0 else {
                return XCTFail("Expected no capturable windows, got \($0)")
            }
        }
        XCTAssertTrue(try store.listSummaries().isEmpty)
    }

    func testUpdateRemovesWindowsOnInactiveSpaces() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let original = makeSnapshot(windows: [makeWindowRecord(), makeWindowRecord()])
        try store.save(original)
        let service = activeSpaceCaptureService(
            store: store,
            windows: [makeDiscoveredWindow(cgWindowID: 100), makeDiscoveredWindow(cgWindowID: 101)],
            memberships: [100: [1], 101: [2]]
        )

        let result = try service.updateSnapshot(id: original.id)

        XCTAssertEqual(result.snapshot.windows.map(\.captureSignature.cgWindowID), [100])
        XCTAssertEqual(try store.loadSnapshot(id: original.id).windows.count, 1)
    }

    func testLegacyWindowSignatureDecodesWithoutCaptureSource() throws {
        let original = makeWindowRecord().captureSignature
        let encoded = try JSONEncoder().encode(original)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "source")
        let legacy = try JSONDecoder().decode(WindowSignature.self, from: JSONSerialization.data(withJSONObject: fields))

        XCTAssertNil(legacy.source)
        XCTAssertEqual(legacy.cgWindowID, original.cgWindowID)
        XCTAssertEqual(legacy.capturedFrame, original.capturedFrame)
    }

    func testLegacyWindowRecordDecodesWithoutApplicationBundleURL() throws {
        let original = makeWindowRecord(applicationBundleURL: URL(fileURLWithPath: "/Applications/Saved.app"))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields.removeValue(forKey: "applicationBundleURL")

        let decoded = try JSONDecoder().decode(WindowRecord.self,
            from: JSONSerialization.data(withJSONObject: fields))

        XCTAssertNil(decoded.applicationBundleURL)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.captureSignature, original.captureSignature)
    }

    func testWindowRecordCopiesAndUpdatesPreserveCapturedApplicationBundleURL() throws {
        let previous = makeWindowRecord(applicationBundleURL: URL(fileURLWithPath: "/Applications/Old.app"))
        let capturedURL = URL(fileURLWithPath: "/Custom Apps/Editor.app")
        let captured = makeWindowRecord(applicationBundleURL: capturedURL)

        XCTAssertEqual(captured.withZOrderHint(5).applicationBundleURL, capturedURL)
        XCTAssertEqual(captured.withOpeningConfiguration(WindowOpeningConfiguration()).applicationBundleURL, capturedURL)
        let updated = captured.preservingIdentityAndManualTargets(from: previous)
        XCTAssertEqual(updated.id, previous.id)
        XCTAssertEqual(updated.applicationBundleURL, capturedURL)
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.applicationBundleURL, capturedURL)
    }

    func testDefaultSnapshotNameUsesLayoutTimestampFallback() throws {
        let date = try makeNamingDate()
        let service = SnapshotCaptureService(
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: FileManager.default.temporaryDirectory)
        )

        XCTAssertEqual(service.defaultSnapshotName(now: date), "Layout - 2026-05-16 14:35")
    }

    func testCaptureSnapshotPreservesCapturedMetadataAndLogsSuccess() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let telemetryLogger = RecordingTelemetryLogger()
        let display = makeDisplayRecord()
        let window = makeDiscoveredWindow(
            title: "Editor",
            frame: CGRect(x: 100, y: 80, width: 500, height: 400),
            isMinimized: true,
            isFullscreen: false,
            isVisible: true,
            cgWindowID: 123,
            ownerName: "Editor",
            cgLayer: 0,
            zOrderHint: 7,
            isOnScreen: true
        )
        let application = DiscoveredApplication(
            bundleIdentifier: TestFixtures.bundleIdentifier,
            pid: 42,
            localizedName: "Editor",
            windows: [window]
        )
        let diagnostic = WindowDiscoveryDiagnostic(
            bundleIdentifier: "com.example.utility",
            processIdentifier: 77,
            reason: WindowDiscoveryDiagnosticReason.transientRole
        )
        let service = SnapshotCaptureService(
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
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [application],
                    diagnostics: [diagnostic]
                )
            }
        )

        let snapshot = try service.captureSnapshot(named: "Coding", now: TestFixtures.createdAt)
        let loadedSnapshot = try store.loadSnapshot(id: snapshot.id)
        let record = try XCTUnwrap(loadedSnapshot.windows.first)

        XCTAssertEqual(loadedSnapshot.name, "Coding")
        XCTAssertEqual(loadedSnapshot.createdAt, TestFixtures.createdAt)
        XCTAssertEqual(record.bundleIdentifier, TestFixtures.bundleIdentifier)
        XCTAssertEqual(record.windowTitle, "Editor")
        XCTAssertEqual(record.displayID, display.id)
        XCTAssertEqual(record.normalizedFrame, NormalizedRect(windowFrame: window.frame, displayFrame: display.frameRect))
        XCTAssertEqual(record.zOrderHint, 7)
        XCTAssertTrue(record.isMinimized)
        XCTAssertEqual(record.captureSignature.cgWindowID, 123)
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.completed"])
        XCTAssertEqual(
            telemetryLogger.events.first?.details.first(where: { $0.kind == diagnostic.kind.rawValue })?.reason,
            WindowDiscoveryDiagnosticReason.transientRole
        )
    }

    func testCaptureSnapshotWithContextUsesContextScreens() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let display = makeDisplayRecord()
        let window = makeDiscoveredWindow(
            frame: CGRect(x: 20, y: 30, width: 400, height: 300),
            cgWindowID: 123
        )
        let application = DiscoveredApplication(
            bundleIdentifier: TestFixtures.bundleIdentifier,
            pid: 42,
            localizedName: "Editor",
            windows: [window]
        )
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { [] }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [application], diagnostics: [])
            }
        )
        let context = SnapshotCaptureService.CaptureContext(
            runningApplications: [],
            screens: [Self.screenSnapshot(from: display)]
        )

        let snapshot = try service.captureSnapshot(
            named: "Coding",
            now: TestFixtures.createdAt,
            context: context
        )

        XCTAssertEqual(snapshot.sourceDisplayState.displays.map(\.id), [display.id])
        XCTAssertEqual(snapshot.windows.first?.displayID, display.id)
    }

    func testCaptureSnapshotLogsFailureWhenNoDisplaysAreAvailable() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let telemetryLogger = RecordingTelemetryLogger()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { [] }),
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url),
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )

        XCTAssertThrowsError(
            try service.captureSnapshot(named: "Coding", now: TestFixtures.createdAt)
        ) { error in
            guard case SnapshotCaptureServiceError.noDisplaysAvailable = error else {
                return XCTFail("Expected no displays error, got \(error).")
            }
        }
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.failed"])
        XCTAssertEqual(
            telemetryLogger.events.first?.errorReason,
            SnapshotCaptureServiceError.noDisplaysAvailable.localizedDescription
        )
    }

    func testCaptureSnapshotRejectsEmptyWindowCaptureWithoutSaving() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let telemetryLogger = RecordingTelemetryLogger()
        let display = makeDisplayRecord()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [Self.screenSnapshot(from: display)]
            }),
            snapshotStore: store,
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )

        XCTAssertThrowsError(
            try service.captureSnapshot(named: "Coding", now: TestFixtures.createdAt)
        ) { error in
            guard case SnapshotCaptureServiceError.noWindowsAvailable = error else {
                return XCTFail("Expected no windows error, got \(error).")
            }
        }
        XCTAssertTrue(try store.listSummaries().isEmpty)
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.failed"])
        XCTAssertEqual(
            telemetryLogger.events.first?.errorReason,
            SnapshotCaptureServiceError.noWindowsAvailable.localizedDescription
        )
    }

    func testCaptureSnapshotLogsFailureWhenPersistenceFails() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let unavailableDirectory = temporaryDirectory.url.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: unavailableDirectory.path, contents: Data()))
        let telemetryLogger = RecordingTelemetryLogger()
        let display = makeDisplayRecord()
        let window = makeDiscoveredWindow(cgWindowID: 123)
        let application = DiscoveredApplication(
            bundleIdentifier: TestFixtures.bundleIdentifier,
            pid: 42,
            localizedName: "Editor",
            windows: [window]
        )
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [Self.screenSnapshot(from: display)]
            }),
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: unavailableDirectory),
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [application], diagnostics: [])
            }
        )

        XCTAssertThrowsError(
            try service.captureSnapshot(named: "Coding", now: TestFixtures.createdAt)
        )
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.failed"])
    }

    func testUpdateSnapshotReplacesCapturedStateAndPreservesMetadata() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let snapshotID = UUID()
        let hotkey = makeHotkey()
        let existingWindow = makeWindowRecord(bundleIdentifier: "com.example.old")
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            createdAt: TestFixtures.createdAt,
            updatedAt: TestFixtures.createdAt,
            displays: [makeDisplayRecord(id: 1)],
            primaryDisplayID: 1,
            windows: [existingWindow],
            hotkey: hotkey,
            isPinned: true
        ))
        let telemetryLogger = RecordingTelemetryLogger()
        let newDisplay = makeDisplayRecord(
            id: 2,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        let newWindow = makeDiscoveredWindow(
            title: "Editor",
            frame: CGRect(x: 120, y: 90, width: 480, height: 360),
            cgWindowID: 456,
            zOrderHint: 2
        )
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [
                    DisplayResolver.ScreenSnapshot(
                        id: newDisplay.id,
                        localizedName: newDisplay.localizedName,
                        frame: newDisplay.frameRect,
                        visibleFrame: newDisplay.visibleFrameRect,
                        backingScaleFactor: newDisplay.backingScaleFactor,
                        isPrimary: newDisplay.isPrimary,
                        vendorID: newDisplay.vendorID,
                        productID: newDisplay.productID,
                        serialNumber: newDisplay.serialNumber
                    )
                ]
            }),
            snapshotStore: store,
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: TestFixtures.bundleIdentifier,
                            pid: 42,
                            localizedName: "Editor",
                            windows: [newWindow]
                        )
                    ],
                    diagnostics: []
                )
            }
        )

        let updateResult = try service.updateSnapshot(id: snapshotID, now: TestFixtures.updatedAt)
        let updatedSnapshot = updateResult.snapshot
        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        let loadedWindow = try XCTUnwrap(loadedSnapshot.windows.first)

        XCTAssertEqual(updatedSnapshot.id, snapshotID)
        XCTAssertEqual(loadedSnapshot.id, snapshotID)
        XCTAssertEqual(loadedSnapshot.name, "Coding")
        XCTAssertEqual(loadedSnapshot.createdAt, TestFixtures.createdAt)
        XCTAssertEqual(loadedSnapshot.updatedAt, TestFixtures.updatedAt)
        XCTAssertEqual(loadedSnapshot.hotkey?.displayString, hotkey.displayString)
        XCTAssertTrue(updatedSnapshot.isPinned)
        XCTAssertTrue(loadedSnapshot.isPinned)
        XCTAssertEqual(loadedSnapshot.sourceDisplayState.displays.map(\.id), [newDisplay.id])
        XCTAssertEqual(loadedSnapshot.windows.count, 1)
        XCTAssertEqual(loadedWindow.bundleIdentifier, TestFixtures.bundleIdentifier)
        XCTAssertEqual(loadedWindow.windowTitle, "Editor")
        XCTAssertNotEqual(loadedWindow.id, existingWindow.id)
        XCTAssertEqual(updateResult.unmatchedManualConfigurationCount, 0)
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.completed"])
    }

    func testUpdateSnapshotThrowsNotFoundWhenSnapshotIsMissing() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let service = SnapshotCaptureService(snapshotStore: store)
        let snapshotID = UUID()

        XCTAssertThrowsError(try service.updateSnapshot(id: snapshotID)) { error in
            guard case let SnapshotStoreError.notFound(missingID) = error else {
                return XCTFail("Expected not found error, got \(error).")
            }
            XCTAssertEqual(missingID, snapshotID)
        }
    }

    func testUpdateSnapshotLogsFailureWhenNoDisplaysAreAvailable() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let snapshotID = UUID()
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            updatedAt: TestFixtures.createdAt
        ))
        let telemetryLogger = RecordingTelemetryLogger()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { [] }),
            snapshotStore: store,
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )

        XCTAssertThrowsError(try service.updateSnapshot(id: snapshotID, now: TestFixtures.updatedAt)) { error in
            guard case SnapshotCaptureServiceError.noDisplaysAvailable = error else {
                return XCTFail("Expected no displays error, got \(error).")
            }
        }
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.failed"])
        XCTAssertEqual(try store.loadSnapshot(id: snapshotID).updatedAt, TestFixtures.createdAt)
    }

    func testUpdateSnapshotRejectsEmptyWindowCaptureAndPreservesExistingSnapshot() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let snapshotID = UUID()
        let existingWindow = makeWindowRecord(bundleIdentifier: "com.example.old")
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            createdAt: TestFixtures.createdAt,
            updatedAt: TestFixtures.createdAt,
            windows: [existingWindow]
        ))
        let telemetryLogger = RecordingTelemetryLogger()
        let display = makeDisplayRecord()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [Self.screenSnapshot(from: display)]
            }),
            snapshotStore: store,
            telemetryLogger: telemetryLogger,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [], diagnostics: [])
            }
        )

        XCTAssertThrowsError(try service.updateSnapshot(id: snapshotID, now: TestFixtures.updatedAt)) { error in
            guard case SnapshotCaptureServiceError.noWindowsAvailable = error else {
                return XCTFail("Expected no windows error, got \(error).")
            }
        }

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.updatedAt, TestFixtures.createdAt)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [existingWindow.id])
        XCTAssertEqual(loadedSnapshot.windows.map(\.bundleIdentifier), ["com.example.old"])
        XCTAssertEqual(telemetryLogger.events.map(\.name), ["capture.failed"])
        XCTAssertEqual(
            telemetryLogger.events.first?.errorReason,
            SnapshotCaptureServiceError.noWindowsAvailable.localizedDescription
        )
    }

    func testMakeWindowRecordKeepsWindowMetadata() throws {
        let service = SnapshotCaptureService(
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: FileManager.default.temporaryDirectory)
        )
        let display = makeDisplayRecord()
        let window = makeDiscoveredWindow(
            title: "Window A",
            subrole: "AXStandardWindow",
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            isMinimized: false,
            isFullscreen: true,
            isMain: false,
            isVisible: false,
            cgWindowID: 999,
            zOrderHint: 3,
            isOnScreen: false
        )
        let application = DiscoveredApplication(
            bundleIdentifier: "com.example.app",
            applicationBundleURL: URL(fileURLWithPath: "/Custom Apps/Captured.app"),
            pid: 88,
            localizedName: "App",
            windows: [window]
        )

        let record = try service.makeWindowRecord(
            application: application,
            window: window,
            displayState: DisplayState(displays: [display], primaryDisplayID: display.id)
        )

        XCTAssertEqual(record.bundleIdentifier, "com.example.app")
        XCTAssertEqual(record.applicationBundleURL, application.applicationBundleURL)
        XCTAssertEqual(record.pidAtCapture, 88)
        XCTAssertEqual(record.windowTitle, "Window A")
        XCTAssertEqual(record.displayID, display.id)
        XCTAssertEqual(record.zOrderHint, 3)
        XCTAssertTrue(record.isFullscreen)
        XCTAssertFalse(record.isVisible)
        XCTAssertEqual(record.captureSignature.cgWindowID, 999)
    }

    func testMakeWindowRecordCapturesExistingDocumentFilesAndFolders() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let documentURL = temporaryDirectory.url.appendingPathComponent("Notes.txt")
        try Data().write(to: documentURL)
        let folderURL = temporaryDirectory.url.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: false
        )
        let service = SnapshotCaptureService(
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        )
        let display = makeDisplayRecord()
        let cases: [(URL, WindowOpenTargetKind)] = [(documentURL, .file), (folderURL, .folder)]
        for (url, kind) in cases {
            let window = makeDiscoveredWindow(documentURL: url)
            let application = DiscoveredApplication(
                bundleIdentifier: "com.example.editor",
                pid: 88,
                localizedName: "Editor",
                windows: [window]
            )

            let record = try service.makeWindowRecord(
                application: application,
                window: window,
                displayState: DisplayState(displays: [display], primaryDisplayID: display.id)
            )

            let target = try XCTUnwrap(record.openingConfiguration.automaticallyCapturedTargets.first)
            XCTAssertEqual(target.kind, kind)
            XCTAssertEqual(target.url, url.standardizedFileURL)
            XCTAssertNil(record.openingConfiguration.manualTargets)
        }
    }

    func testMakeWindowRecordCapturesExistingPathsFromInactiveTabTitles() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let selectedFolderURL = temporaryDirectory.url.appendingPathComponent(
            "LayoutLockFiles",
            isDirectory: true
        )
        let inactiveFolderURL = temporaryDirectory.url.appendingPathComponent(
            "ZapPDF",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedFolderURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: inactiveFolderURL,
            withIntermediateDirectories: false
        )
        let selectedDocumentURL = try XCTUnwrap(
            URL(string: "file://\(selectedFolderURL.path)/")
        )
        let service = SnapshotCaptureService(
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        )
        let display = makeDisplayRecord()
        let window = makeDiscoveredWindow(
            documentURL: selectedDocumentURL,
            documentTitles: [
                "user@machine:\(selectedFolderURL.path)",
                "user@machine:\(inactiveFolderURL.path)",
                "Settings",
                "https://example.com/"
            ]
        )
        let application = DiscoveredApplication(
            bundleIdentifier: "com.mitchellh.ghostty",
            pid: 88,
            localizedName: "Ghostty",
            windows: [window]
        )

        let record = try service.makeWindowRecord(
            application: application,
            window: window,
            displayState: DisplayState(displays: [display], primaryDisplayID: display.id)
        )

        let targets = record.openingConfiguration.automaticallyCapturedTargets
        XCTAssertEqual(targets.map(\.kind), [.folder, .folder])
        XCTAssertEqual(
            targets.map { ($0.url.path as NSString).standardizingPath },
            [
                (selectedFolderURL.path as NSString).standardizingPath,
                (inactiveFolderURL.path as NSString).standardizingPath
            ]
        )
    }

    func testMakeWindowRecordCapturesHTTPDocumentAsEditableAutomaticTarget() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let service = SnapshotCaptureService(
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        )
        let display = makeDisplayRecord()
        let documentURL = try XCTUnwrap(
            URL(string: "https://www.youtube.com/watch?v=layoutlock")
        )
        let window = makeDiscoveredWindow(
            documentURL: documentURL,
            title: "YouTube"
        )
        let application = DiscoveredApplication(
            bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
            pid: 88,
            localizedName: "Firefox Developer Edition",
            windows: [window]
        )

        let record = try service.makeWindowRecord(
            application: application,
            window: window,
            displayState: DisplayState(displays: [display], primaryDisplayID: display.id)
        )

        let target = try XCTUnwrap(record.openingConfiguration.automaticallyCapturedTargets.first)
        XCTAssertEqual(target.kind, .webURL)
        XCTAssertEqual(target.url, documentURL)
        XCTAssertNil(record.openingConfiguration.manualTargets)
    }

    func testCaptureAddsOrderedBrowserTabsAndPreservesDuplicates() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let display = makeDisplayRecord()
        let frame = CGRect(x: 100, y: 80, width: 500, height: 400)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second"))
        let browserWindow = makeDiscoveredWindow(
            title: "Browser",
            frame: frame,
            cgWindowID: 123,
            zOrderHint: 0
        )
        let service = SnapshotCaptureService(
            snapshotStore: store,
            browserTabCapturer: StubBrowserTabCapturer(
                result: BrowserTabCaptureResult(
                    windows: [
                        CapturedBrowserWindow(
                            browser: .chrome,
                            scriptingIdentifier: "1",
                            title: "Browser",
                            frame: frame,
                            frontToBackIndex: 0,
                            tabs: [
                                CapturedBrowserTab(title: "First", URL: firstURL),
                                CapturedBrowserTab(title: "First duplicate", URL: firstURL),
                                CapturedBrowserTab(title: "Second", URL: secondURL)
                            ]
                        )
                    ],
                    issues: []
                )
            ),
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: BrowserAutomationBrowser.chrome.bundleIdentifier,
                            pid: 42,
                            localizedName: "Google Chrome",
                            windows: [browserWindow]
                        )
                    ],
                    diagnostics: []
                )
            }
        )
        let context = SnapshotCaptureService.CaptureContext(
            runningApplications: [
                RunningApplicationSnapshot(
                    bundleIdentifier: BrowserAutomationBrowser.chrome.bundleIdentifier,
                    processIdentifier: 42,
                    localizedName: "Google Chrome"
                )
            ],
            screens: [Self.screenSnapshot(from: display)]
        )

        let result = try service.captureSnapshotWithIssues(
            named: "Browser",
            context: context
        )

        XCTAssertEqual(
            result.snapshot.windows[0].openingConfiguration.automaticallyCapturedTargets.map(\.url),
            [firstURL, firstURL, secondURL]
        )
        XCTAssertEqual(
            result.snapshot.windows[0].openingConfiguration.automaticallyCapturedTargets.map(\.title),
            ["First", "First duplicate", "Second"]
        )
        XCTAssertTrue(result.browserCaptureIssues.isEmpty)
    }

    func testCaptureExcludesFinderWindows() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(
            snapshotsDirectoryURL: temporaryDirectory.url.appendingPathComponent("Snapshots")
        )
        let display = makeDisplayRecord()
        let frame = CGRect(x: 100, y: 80, width: 500, height: 400)
        let service = SnapshotCaptureService(
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: "com.apple.finder",
                            pid: 42,
                            localizedName: "Finder",
                            windows: [
                                makeDiscoveredWindow(
                                    title: "Downloads",
                                    frame: frame,
                                    cgWindowID: 122,
                                    zOrderHint: 0
                                )
                            ]
                        ),
                        DiscoveredApplication(
                            bundleIdentifier: "com.example.editor",
                            pid: 43,
                            localizedName: "Editor",
                            windows: [
                                makeDiscoveredWindow(
                                    title: "Document",
                                    frame: frame,
                                    cgWindowID: 123,
                                    zOrderHint: 1
                                )
                            ]
                        )
                    ],
                    diagnostics: []
                )
            },
            restoreSpaceAccess: .unavailable
        )
        let context = SnapshotCaptureService.CaptureContext(
            runningApplications: [
                RunningApplicationSnapshot(
                    bundleIdentifier: "com.apple.finder",
                    processIdentifier: 42,
                    localizedName: "Finder"
                ),
                RunningApplicationSnapshot(
                    bundleIdentifier: "com.example.editor",
                    processIdentifier: 43,
                    localizedName: "Editor"
                )
            ],
            screens: [Self.screenSnapshot(from: display)]
        )

        let result = try service.captureSnapshotWithIssues(
            named: "Without Finder",
            context: context
        )

        XCTAssertEqual(result.snapshot.windows.map(\.bundleIdentifier), ["com.example.editor"])
    }

    func testCaptureReturnsBrowserWarningsWithoutFailingLayoutSave() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let display = makeDisplayRecord()
        let issue = BrowserCaptureIssue(browser: .safari, reason: .queryFailed)
        let service = SnapshotCaptureService(
            snapshotStore: store,
            browserTabCapturer: StubBrowserTabCapturer(
                result: BrowserTabCaptureResult(windows: [], issues: [issue])
            ),
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: "com.example.editor",
                            pid: 42,
                            localizedName: "Editor",
                            windows: [makeDiscoveredWindow(cgWindowID: 123)]
                        )
                    ],
                    diagnostics: []
                )
            }
        )
        let context = SnapshotCaptureService.CaptureContext(
            runningApplications: [
                RunningApplicationSnapshot(
                    bundleIdentifier: BrowserAutomationBrowser.safari.bundleIdentifier,
                    processIdentifier: 42,
                    localizedName: "Safari"
                )
            ],
            screens: [Self.screenSnapshot(from: display)]
        )

        let result = try service.captureSnapshotWithIssues(
            named: "Warning",
            context: context
        )

        XCTAssertEqual(result.snapshot.windows.count, 1)
        XCTAssertEqual(result.browserCaptureIssues, [issue])
        XCTAssertEqual(try store.loadSnapshot(id: result.snapshot.id).windows.count, 1)
    }

    func testUpdateRefreshesAutomaticTargetAndPreservesManualTargets() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let oldDocumentURL = temporaryDirectory.url.appendingPathComponent("Old.txt")
        let newDocumentURL = temporaryDirectory.url.appendingPathComponent("New.txt")
        try Data().write(to: oldDocumentURL)
        try Data().write(to: newDocumentURL)
        let manualURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let existingWindow = makeWindowRecord(
            id: UUID(),
            bundleIdentifier: "com.example.editor",
            pidAtCapture: 42,
            windowTitle: "Editor",
            cgWindowID: 123
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [
                    WindowOpenTarget(kind: .file, url: oldDocumentURL)
                ],
                manualTargets: [
                    WindowOpenTarget(kind: .webURL, url: manualURL)
                ]
            )
        )
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectory.url)
        let snapshotID = UUID()
        try store.save(makeSnapshot(id: snapshotID, windows: [existingWindow]))
        let display = makeDisplayRecord()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [Self.screenSnapshot(from: display)]
            }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: "com.example.editor",
                            pid: 42,
                            localizedName: "Editor",
                            windows: [
                                makeDiscoveredWindow(
                                    documentURL: newDocumentURL,
                                    title: "Editor",
                                    cgWindowID: 123
                                )
                            ]
                        )
                    ],
                    diagnostics: []
                )
            }
        )

        let result = try service.updateSnapshot(id: snapshotID)
        let updatedWindow = try XCTUnwrap(result.snapshot.windows.first)

        XCTAssertEqual(updatedWindow.id, existingWindow.id)
        XCTAssertEqual(
            updatedWindow.openingConfiguration.automaticallyCapturedTargets.map(\.url),
            [newDocumentURL.standardizedFileURL]
        )
        XCTAssertEqual(
            updatedWindow.openingConfiguration.manualTargets?.map(\.url),
            [manualURL]
        )
        XCTAssertEqual(result.unmatchedManualConfigurationCount, 0)
    }

    func testUpdatePreservesCoreGraphicsManualTargetsWhenRecapturedThroughAXAfterRestart() throws {
        let captured = makeSnapshot(windows: [
            makeRecaptureWindow(source: .coreGraphics, subrole: nil),
            makeRecaptureWindow(source: .coreGraphics, subrole: nil, cgWindowID: 202, title: "Companion")
        ])
        let previousWindow = try XCTUnwrap(captured.windows.first)
        let manualTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/project"))
        )
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        try store.save(captured)
        XCTAssertTrue(try store.setOpeningConfiguration(
            snapshotID: captured.id,
            windowID: previousWindow.id,
            manualTargets: [manualTarget]
        ))
        let display = makeDisplayRecord()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { [Self.screenSnapshot(from: display)] }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(applications: [DiscoveredApplication(
                    bundleIdentifier: TestFixtures.bundleIdentifier,
                    pid: 77,
                    localizedName: "Editor",
                    windows: [
                        makeDiscoveredWindow(title: "Companion", cgWindowID: 302),
                        makeDiscoveredWindow(title: "Editor", cgWindowID: 301)
                    ]
                )], diagnostics: [])
            },
            restoreSpaceAccess: .unavailable
        )

        let result = try service.updateSnapshot(id: captured.id)
        let saved = try store.loadSnapshot(id: captured.id)
        let updatedWindow = try XCTUnwrap(saved.windows.last)

        XCTAssertEqual(saved.windows.map(\.id), captured.windows.reversed().map(\.id))
        XCTAssertEqual(updatedWindow.id, previousWindow.id)
        XCTAssertEqual(updatedWindow.openingConfiguration.manualTargets, [manualTarget])
        XCTAssertEqual(updatedWindow.captureSignature.source, .accessibility)
        XCTAssertEqual(updatedWindow.pidAtCapture, 77)
        XCTAssertEqual(updatedWindow.captureSignature.cgWindowID, 301)
        XCTAssertEqual(updatedWindow.subrole, "AXStandardWindow")
        XCTAssertEqual(result.unmatchedManualConfigurationCount, 0)
    }

    func testUpdateDoesNotTransferCoreGraphicsManualTargetsAcrossDuplicateTitles() throws {
        let manualTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        let previousWindow = makeRecaptureWindow(source: .coreGraphics, subrole: nil)
            .withOpeningConfiguration(WindowOpeningConfiguration(manualTargets: [manualTarget]))
        let capturedWindow = makeRecaptureWindow(source: .accessibility, pid: 77, cgWindowID: 301)
        let duplicatePrevious = makeRecaptureWindow(source: .coreGraphics, subrole: nil, cgWindowID: 202)
        let duplicateCaptured = makeRecaptureWindow(source: .accessibility, pid: 77, cgWindowID: 302)

        for (previous, captured) in [
            ([previousWindow, duplicatePrevious], [capturedWindow]),
            ([previousWindow], [capturedWindow, duplicateCaptured])
        ] {
            let result = SnapshotWindowOpeningConfigurationMerger().merge(
                previousWindows: previous,
                capturedWindows: captured
            )

            XCTAssertEqual(result.windows.map(\.id), captured.map(\.id))
            XCTAssertTrue(result.windows.allSatisfy { !$0.openingConfiguration.isManual })
            XCTAssertEqual(result.unmatchedManualConfigurationCount, 1)
        }
    }

    func testUpdateDoesNotTreatUnknownAXSubroleAsCoreGraphicsFallback() throws {
        let sources: [WindowCaptureSource?] = [.accessibility, nil]
        for source in sources {
            let previousWindow = makeRecaptureWindow(source: source, subrole: nil)
                .withOpeningConfiguration(WindowOpeningConfiguration(manualTargets: []))
            let capturedWindow = makeRecaptureWindow(source: .accessibility, pid: 77, cgWindowID: 301)

            let result = SnapshotWindowOpeningConfigurationMerger().merge(
                previousWindows: [previousWindow],
                capturedWindows: [capturedWindow]
            )

            XCTAssertEqual(result.windows.first?.id, capturedWindow.id)
            XCTAssertFalse(result.windows.first?.openingConfiguration.isManual ?? true)
            XCTAssertEqual(result.unmatchedManualConfigurationCount, 1)
        }
    }

    func testUpdateRejectsCoreGraphicsToAXTransitionWithConflictingKnownSubrole() throws {
        let previousWindow = makeRecaptureWindow(source: .coreGraphics, subrole: "AXDialog")
            .withOpeningConfiguration(WindowOpeningConfiguration(manualTargets: []))
        let capturedWindow = makeRecaptureWindow(source: .accessibility, pid: 77, cgWindowID: 301)

        let result = SnapshotWindowOpeningConfigurationMerger().merge(
            previousWindows: [previousWindow],
            capturedWindows: [capturedWindow]
        )

        XCTAssertEqual(result.windows.first?.id, capturedWindow.id)
        XCTAssertFalse(result.windows.first?.openingConfiguration.isManual ?? true)
        XCTAssertEqual(result.unmatchedManualConfigurationCount, 1)
    }

    func testUpdatePreservesManualAppOnlyConfiguration() throws {
        let previousWindow = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Editor"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(manualTargets: [])
        )
        let capturedWindow = makeWindowRecord(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Editor"
        )

        let result = SnapshotWindowOpeningConfigurationMerger().merge(
            previousWindows: [previousWindow],
            capturedWindows: [capturedWindow]
        )

        XCTAssertEqual(result.windows.first?.id, previousWindow.id)
        XCTAssertEqual(result.windows.first?.openingConfiguration.manualTargets, [])
        XCTAssertEqual(result.unmatchedManualConfigurationCount, 0)
    }

    func testUpdateDoesNotTransferManualTargetsAcrossAmbiguousWindows() throws {
        let manualTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        let previousWindows = [
            makeWindowRecord(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            ).withOpeningConfiguration(
                WindowOpeningConfiguration(manualTargets: [manualTarget])
            ),
            makeWindowRecord(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            )
        ]
        let capturedWindows = [
            makeWindowRecord(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            ),
            makeWindowRecord(
                bundleIdentifier: "com.example.editor",
                windowTitle: "Same"
            )
        ]

        let result = SnapshotWindowOpeningConfigurationMerger().merge(
            previousWindows: previousWindows,
            capturedWindows: capturedWindows
        )

        XCTAssertTrue(result.windows.allSatisfy { !$0.openingConfiguration.isManual })
        XCTAssertEqual(result.unmatchedManualConfigurationCount, 1)
    }

    private func makeRecaptureWindow(
        source: WindowCaptureSource?,
        subrole: String? = "AXStandardWindow",
        pid: Int32 = 42,
        cgWindowID: UInt32 = 201,
        title: String = "Editor"
    ) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: TestFixtures.bundleIdentifier,
            pidAtCapture: pid,
            windowTitle: title,
            role: "AXWindow",
            subrole: subrole,
            frame: CGRectCodable(TestFixtures.windowFrame),
            displayID: 1,
            normalizedFrame: NormalizedRect(windowFrame: TestFixtures.windowFrame, displayFrame: makeDisplayRecord().frameRect),
            zOrderHint: nil,
            isMinimized: false,
            isFullscreen: false,
            isVisible: source != .coreGraphics,
            captureSignature: WindowSignature(
                bundleIdentifier: TestFixtures.bundleIdentifier,
                owningPid: pid,
                windowTitle: title,
                role: "AXWindow",
                subrole: subrole,
                capturedFrame: CGRectCodable(TestFixtures.windowFrame),
                cgWindowID: cgWindowID,
                source: source
            )
        )
    }

    private func captureActiveWindows(
        _ windows: [DiscoveredWindow],
        bundleIdentifier: String = TestFixtures.bundleIdentifier,
        memberships: [CGWindowID: Set<UInt64>] = [:],
        inventory: RestoreSpaceInventory? = RestoreSpaceInventory(
            activeByDisplay: [1: 1, 2: 3], ordinarySpaceIDs: [1, 2, 3, 4]),
        unexposedWindows: [CGWindowMetadata] = []
    ) throws -> Snapshot {
        let directory = try TestTemporaryDirectory()
        return try activeSpaceCaptureService(
            store: SnapshotStore(snapshotsDirectoryURL: directory.url),
            windows: windows, bundleIdentifier: bundleIdentifier, memberships: memberships, inventory: inventory,
            unexposedWindows: unexposedWindows
        ).captureSnapshot(named: "Active Spaces")
    }

    private func activeSpaceCaptureService(
        store: SnapshotStore,
        windows: [DiscoveredWindow],
        bundleIdentifier: String = TestFixtures.bundleIdentifier,
        memberships: [CGWindowID: Set<UInt64>],
        inventory: RestoreSpaceInventory? = RestoreSpaceInventory(
            activeByDisplay: [1: 1, 2: 3], ordinarySpaceIDs: [1, 2, 3, 4]),
        unexposedWindows: [CGWindowMetadata] = []
    ) -> SnapshotCaptureService {
        let displays = [makeDisplayRecord(), makeDisplayRecord(id: 2)]
        return SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: { displays.map(Self.screenSnapshot) }),
            snapshotStore: store,
            browserTabCapturer: StubBrowserTabCapturer(result: BrowserTabCaptureResult(windows: [], issues: [])),
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [DiscoveredApplication(
                        bundleIdentifier: bundleIdentifier, pid: 42,
                        localizedName: "Editor", windows: windows)],
                    diagnostics: [],
                    unexposedApplications: [UnexposedApplicationWindows(
                        bundleIdentifier: bundleIdentifier, pid: 42, windows: unexposedWindows)]
                )
            },
            restoreSpaceAccess: RestoreSpaceAccess(
                inventory: { _ in inventory },
                membership: { memberships[$0] },
                submitMove: { _, _ in XCTFail("Capture must never move a window"); return false },
                windowMetadata: { _, id in unexposedWindows.first { $0.windowID == id } }
            )
        )
    }

    private func cgCandidate(
        id: CGWindowID,
        pid: pid_t = 42,
        title: String? = "Hidden Editor",
        layer: Int = 0,
        isOnScreen: Bool = false,
        bounds: CGRect = CGRect(x: 100, y: 80, width: 600, height: 450)
    ) -> CGWindowMetadata {
        CGWindowMetadata(
            windowID: id,
            processIdentifier: pid,
            ownerName: "Editor",
            layer: layer,
            bounds: bounds,
            title: title,
            isOnScreen: isOnScreen,
            zOrderHint: nil
        )
    }

    private func makeNamingDate() throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 5
        components.day = 16
        components.hour = 14
        components.minute = 35
        return try XCTUnwrap(components.date)
    }

    private static func screenSnapshot(from display: DisplayRecord) -> DisplayResolver.ScreenSnapshot {
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
}

private final class RecordingTelemetryLogger: TelemetryLogging {
    private(set) var events: [TelemetryLogEvent] = []

    func log(_ event: TelemetryLogEvent) {
        events.append(event)
    }
}

private struct StubBrowserTabCapturer: BrowserTabCapturing {
    let result: BrowserTabCaptureResult

    func captureTabs(
        runningApplications _: [RunningApplicationSnapshot]
    ) -> BrowserTabCaptureResult {
        result
    }
}
