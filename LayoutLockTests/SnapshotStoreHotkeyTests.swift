import Carbon
import Foundation
import XCTest
@testable import LayoutLock

final class SnapshotStoreHotkeyTests: XCTestCase {
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

    func testSetHotkeyPersistsBindingAndUpdatedDate() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))

        let hotkey = makeHotkey()
        let updatedAt = Date(timeIntervalSince1970: 200)
        try store.setHotkey(for: snapshotID, hotkey: hotkey, now: updatedAt)

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.hotkey, hotkey)
        XCTAssertEqual(loadedSnapshot.updatedAt, updatedAt)
    }

    func testSetHotkeyRejectsDuplicateAssignment() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let firstSnapshot = makeSnapshot(
            id: UUID(),
            name: "First",
            hotkey: makeHotkey()
        )
        let secondSnapshotID = UUID()
        try store.save(firstSnapshot)
        try store.save(makeSnapshot(id: secondSnapshotID, name: "Second"))

        XCTAssertThrowsError(
            try store.setHotkey(for: secondSnapshotID, hotkey: makeHotkey())
        ) { error in
            guard case let SnapshotStoreError.duplicateHotkeyAssignment(snapshotName) = error else {
                return XCTFail("Expected duplicate hotkey error, got \(error).")
            }

            XCTAssertEqual(snapshotName, "First")
        }
    }

    func testSetHotkeyRejectsInvalidAssignment() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let invalidHotkey = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(shiftKey),
            displayString: "Shift-K"
        )

        XCTAssertThrowsError(
            try store.setHotkey(for: snapshotID, hotkey: invalidHotkey)
        ) { error in
            guard case SnapshotStoreError.invalidHotkeyAssignment = error else {
                return XCTFail("Expected invalid hotkey error, got \(error).")
            }
        }
    }

    func testClearHotkeyPersistsNilBinding() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            hotkey: makeHotkey()
        ))

        try store.setHotkey(for: snapshotID, hotkey: nil)

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertNil(loadedSnapshot.hotkey)
    }

    func testOpeningConfigurationRoundTripPreservesOrderDuplicatesAndManualEmptyList() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let fileURL = temporaryDirectoryURL.appendingPathComponent("Document.txt")
        try Data().write(to: fileURL)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/one"))
        let repeatedURL = try XCTUnwrap(URL(string: "https://example.com/repeated"))
        let automaticTarget = WindowOpenTarget(kind: .file, url: fileURL)
        let targets = [
            WindowOpenTarget(kind: .folder, url: temporaryDirectoryURL),
            WindowOpenTarget(kind: .webURL, url: firstURL, title: "Example One"),
            WindowOpenTarget(kind: .webURL, url: repeatedURL),
            WindowOpenTarget(kind: .webURL, url: repeatedURL)
        ]
        let window = makeWindowRecord().withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [automaticTarget],
                manualTargets: targets
            )
        )
        let snapshot = makeSnapshot(
            id: UUID(),
            name: "Opening Targets",
            windows: [window]
        )

        try store.save(snapshot)
        let loadedWindow = try XCTUnwrap(store.loadSnapshot(id: snapshot.id).windows.first)

        XCTAssertEqual(
            loadedWindow.openingConfiguration.automaticallyCapturedTargets,
            [automaticTarget]
        )
        XCTAssertEqual(loadedWindow.openingConfiguration.manualTargets, targets)
        XCTAssertEqual(loadedWindow.openingConfiguration.effectiveTargets, targets)

        XCTAssertTrue(
            try store.setOpeningConfiguration(
                snapshotID: snapshot.id,
                windowID: window.id,
                manualTargets: []
            )
        )
        XCTAssertEqual(
            try store.loadSnapshot(id: snapshot.id).windows.first?.openingConfiguration.manualTargets,
            []
        )
    }

    func testSavingEditedOpeningTargetPreservesOtherTargetsWindowsAndLayoutMetadata() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let encoder = JSONEncoder()
        let replacementFileURL = temporaryDirectoryURL.appendingPathComponent("Located.txt")
        try Data().write(to: replacementFileURL)

        for kind: WindowOpenTargetKind in [.file, .folder, .webURL] {
            let replacementURL: URL
            switch kind {
            case .file:
                replacementURL = replacementFileURL
            case .folder:
                replacementURL = temporaryDirectoryURL
            case .webURL:
                replacementURL = try XCTUnwrap(URL(string: "https://new.example.com/"))
            }
            let originalTarget = WindowOpenTarget(
                kind: kind,
                url: kind == .webURL
                    ? try XCTUnwrap(URL(string: "https://old.example.com/"))
                    : temporaryDirectoryURL.appendingPathComponent("Missing"),
                title: "Saved target"
            )
            let otherTarget = WindowOpenTarget(kind: .file, url: replacementFileURL)
            let lastTarget = WindowOpenTarget(kind: .file, url: replacementFileURL)
            let originalTargets = [otherTarget, originalTarget, lastTarget]

            for hasManualTargets in [false, true] {
                let window = makeWindowRecord(
                    zOrderHint: 2,
                    openingConfiguration: WindowOpeningConfiguration(
                        automaticallyCapturedTargets: originalTargets,
                        manualTargets: hasManualTargets ? originalTargets : nil
                    )
                )
                let otherWindow = makeWindowRecord()
                let snapshot = Snapshot(
                    name: "Daily Setup",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 200),
                    sourceDisplayState: DisplayState(displays: [makeDisplay(id: 1)], primaryDisplayID: 1),
                    windows: [window, otherWindow],
                    hotkey: makeHotkey(),
                    isPinned: true
                )
                try store.save(snapshot)

                let draft = [
                    otherTarget,
                    WindowOpenTarget(
                        id: originalTarget.id,
                        kind: kind,
                        url: replacementURL,
                        title: kind == .webURL ? nil : originalTarget.title
                    ),
                    lastTarget
                ]

                let savedAt = Date(timeIntervalSince1970: 300)
                XCTAssertTrue(try store.setOpeningConfiguration(
                    snapshotID: snapshot.id,
                    windowID: window.id,
                    manualTargets: draft,
                    now: savedAt
                ))

                let saved = try store.loadSnapshot(id: snapshot.id)
                var expectedJSON = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any]
                )
                var expectedWindows = try XCTUnwrap(expectedJSON["windows"] as? [[String: Any]])
                var expectedConfiguration = try XCTUnwrap(
                    expectedWindows[0]["openingConfiguration"] as? [String: Any]
                )
                expectedConfiguration["manualTargets"] = try JSONSerialization.jsonObject(with: encoder.encode(draft))
                expectedWindows[0]["openingConfiguration"] = expectedConfiguration
                expectedJSON["windows"] = expectedWindows
                expectedJSON["updatedAt"] = savedAt.timeIntervalSinceReferenceDate

                // Only the edited window's manual targets and the update date may change.
                XCTAssertEqual(
                    try JSONSerialization.jsonObject(with: encoder.encode(saved)) as? NSDictionary,
                    NSDictionary(dictionary: expectedJSON)
                )
            }
        }
    }

    func testWindowOpenTargetValidatorClassifiesLocalTargets() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("Document.txt")
        let folderURL = temporaryDirectoryURL.appendingPathComponent("Project", isDirectory: true)
        try Data().write(to: fileURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        let validator = WindowOpenTargetValidator()

        let fileTarget = try validator.localTarget(path: fileURL.path, expectedKind: .file)
        let folderTarget = try validator.localTarget(path: folderURL.path, expectedKind: .folder)

        XCTAssertEqual(fileTarget.kind, .file)
        XCTAssertEqual(fileTarget.url, fileURL.standardizedFileURL)
        XCTAssertEqual(folderTarget.kind, .folder)
        XCTAssertEqual(folderTarget.url, folderURL.standardizedFileURL)
        XCTAssertEqual(
            try validator.localTarget(path: " \(fileURL.path)\n", expectedKind: .file).url,
            fileURL.standardizedFileURL
        )
        XCTAssertEqual(
            try validator.localTarget(path: "~", expectedKind: .folder).url,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
        XCTAssertThrowsError(try validator.localTarget(path: folderURL.path, expectedKind: .file))
        XCTAssertThrowsError(try validator.localTarget(path: fileURL.path, expectedKind: .folder))
        XCTAssertThrowsError(
            try validator.localTarget(path: temporaryDirectoryURL.appendingPathComponent("Missing").path)
        )
        XCTAssertThrowsError(try validator.localTarget(url: folderURL, expectedKind: .file)) { error in
            XCTAssertEqual(error as? WindowOpenTargetValidationError, .expectedFile)
        }
        XCTAssertThrowsError(try validator.localTarget(url: fileURL, expectedKind: .folder)) { error in
            XCTAssertEqual(error as? WindowOpenTargetValidationError, .expectedFolder)
        }
        XCTAssertThrowsError(try validator.localTarget(url: temporaryDirectoryURL.appendingPathComponent("Missing"))) { error in
            XCTAssertEqual(error as? WindowOpenTargetValidationError, .pathDoesNotExist)
        }
    }

    func testLocalTargetURLPreservesTrailingWhitespaceWithAndWithoutSibling() throws {
        let validator = WindowOpenTargetValidator()

        for (name, kind) in [("Document.txt", WindowOpenTargetKind.file), ("Project", .folder)] {
            let selectedURL = temporaryDirectoryURL.appendingPathComponent(name + " ", isDirectory: kind == .folder)
            let siblingURL = temporaryDirectoryURL.appendingPathComponent(name, isDirectory: kind == .folder)
            if kind == .folder {
                try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: false)
            } else {
                try Data().write(to: selectedURL)
            }

            XCTAssertEqual(
                try validator.localTarget(url: selectedURL, expectedKind: kind).url,
                selectedURL.standardizedFileURL
            )

            if kind == .folder {
                try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: false)
            } else {
                try Data().write(to: siblingURL)
            }

            XCTAssertEqual(
                try validator.localTarget(url: selectedURL, expectedKind: kind).url,
                selectedURL.standardizedFileURL
            )
        }
    }

    func testWindowOpenTargetValidatorAcceptsHTTPURLsAndPreservesDuplicates() throws {
        let targets = try WindowOpenTargetValidator().webTargets(
            from: """
            https://example.com/one
            http://example.com/two
            example.com/three
            localhost:3000/four
            https://example.com/one
            """
        )

        XCTAssertEqual(
            targets.map(\.url.absoluteString),
            [
                "https://example.com/one",
                "http://example.com/two",
                "https://example.com/three",
                "https://localhost:3000/four",
                "https://example.com/one"
            ]
        )
        XCTAssertThrowsError(
            try WindowOpenTargetValidator().webTargets(from: "ftp://example.com/file")
        )
        XCTAssertThrowsError(
            try WindowOpenTargetValidator().webTargets(from: "https:///missing-host")
        )
    }

    func testSingleWebTargetValidationNormalizesAnAddressAndRejectsInvalidEdits() throws {
        let validator = WindowOpenTargetValidator()
        let target = try validator.webTarget(from: "  example.com/updated?q=one  ")
        XCTAssertEqual(target.kind, .webURL)
        XCTAssertEqual(target.url.absoluteString, "https://example.com/updated?q=one")

        for input in [
            "",
            " \t\n",
            "https://example.com/one\nhttps://example.com/two",
            "ftp://example.com/file",
            "https:///missing-host"
        ] {
            XCTAssertThrowsError(try validator.webTarget(from: input)) { error in
                XCTAssertEqual(
                    error as? WindowOpenTargetValidationError,
                    .invalidWebURL(input.trimmingCharacters(in: .whitespacesAndNewlines))
                )
            }
        }
    }

    func testReplacingTargetURLPreservesIdentityKindAndLocalTitles() throws {
        let newURL = temporaryDirectoryURL.appendingPathComponent("Replacement")
        for kind: WindowOpenTargetKind in [.file, .folder] {
            let target = WindowOpenTarget(
                kind: kind,
                url: temporaryDirectoryURL.appendingPathComponent("Original"),
                title: "Saved title"
            )
            let replacement = target.replacingURL(newURL)
            XCTAssertEqual(replacement.id, target.id)
            XCTAssertEqual(replacement.kind, kind)
            XCTAssertEqual(replacement.url, newURL)
            XCTAssertEqual(replacement.title, target.title)
        }
    }

    func testReplacingBrowserURLClearsTheCapturedTitleOnlyWhenTheURLChanges() throws {
        let target = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://old.example.com/")),
            title: "Old page title"
        )
        XCTAssertEqual(target.replacingURL(target.url), target)

        let newURL = try XCTUnwrap(URL(string: "https://new.example.com/updated"))
        let replacement = target.replacingURL(newURL)
        XCTAssertEqual(replacement.id, target.id)
        XCTAssertEqual(replacement.kind, .webURL)
        XCTAssertEqual(replacement.url, newURL)
        XCTAssertNil(replacement.title)
        XCTAssertEqual(replacement.compactDisplayName, "new.example.com")
    }

    func testListSummariesIncludesDashboardMetrics() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let displays = [
            DisplayRecord(
                id: 1,
                localizedName: "Studio Display",
                frame: CGRectCodable(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRectCodable(x: 0, y: 0, width: 1440, height: 860),
                backingScaleFactor: 2,
                isPrimary: true,
                vendorID: nil,
                productID: nil,
                serialNumber: nil
            ),
            DisplayRecord(
                id: 2,
                localizedName: "Projector",
                frame: CGRectCodable(x: 1440, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRectCodable(x: 1440, y: 0, width: 1920, height: 1040),
                backingScaleFactor: 1,
                isPrimary: false,
                vendorID: nil,
                productID: nil,
                serialNumber: nil
            )
        ]
        let windows = [
            WindowRecord(
                bundleIdentifier: "com.apple.Safari",
                pidAtCapture: 1,
                windowTitle: "Docs",
                role: "AXWindow",
                subrole: nil,
                frame: CGRectCodable(x: 10, y: 10, width: 400, height: 300),
                displayID: 1,
                normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 0.2, heightRatio: 0.2),
                zOrderHint: nil,
                isMinimized: false,
                isFullscreen: false,
                isVisible: true,
                captureSignature: WindowSignature(
                    bundleIdentifier: "com.apple.Safari",
                    owningPid: 1,
                    windowTitle: "Docs",
                    role: "AXWindow",
                    subrole: nil,
                    capturedFrame: CGRectCodable(x: 10, y: 10, width: 400, height: 300),
                    cgWindowID: nil
                )
            ),
            WindowRecord(
                bundleIdentifier: "com.apple.Notes",
                pidAtCapture: 2,
                windowTitle: "Plan",
                role: "AXWindow",
                subrole: nil,
                frame: CGRectCodable(x: 20, y: 20, width: 500, height: 350),
                displayID: 2,
                normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.1, widthRatio: 0.3, heightRatio: 0.3),
                zOrderHint: nil,
                isMinimized: false,
                isFullscreen: false,
                isVisible: true,
                captureSignature: WindowSignature(
                    bundleIdentifier: "com.apple.Notes",
                    owningPid: 2,
                    windowTitle: "Plan",
                    role: "AXWindow",
                    subrole: nil,
                    capturedFrame: CGRectCodable(x: 20, y: 20, width: 500, height: 350),
                    cgWindowID: nil
                )
            )
        ]
        try store.save(
            Snapshot(
                id: snapshotID,
                name: "Dashboard",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200),
                sourceDisplayState: DisplayState(displays: displays, primaryDisplayID: 1),
                windows: windows
            )
        )

        let summary = try XCTUnwrap(store.listSummaries().first)
        XCTAssertEqual(summary.displayCount, 2)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.windowCount, 2)
    }

    func testListSummariesCountsOnlyDisplaysWithSavedWindows() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let displays = [
            makeDisplay(id: 1),
            makeDisplay(id: 2),
            makeDisplay(id: 3)
        ]
        let windows = [
            makeWindow(bundleIdentifier: "com.example.editor", title: "Code", displayID: 1),
            makeWindow(bundleIdentifier: "com.example.terminal", title: "Shell", displayID: 3),
            makeWindow(bundleIdentifier: "com.example.unknown", title: "Unknown", displayID: 99),
            makeWindow(bundleIdentifier: "com.example.unassigned", title: "Unassigned")
        ]
        try store.save(
            Snapshot(
                id: snapshotID,
                name: "Coding",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200),
                sourceDisplayState: DisplayState(displays: displays, primaryDisplayID: 1),
                windows: windows
            )
        )

        let summary = try XCTUnwrap(store.listSummaries().first)
        XCTAssertEqual(summary.displayCount, 2)
        XCTAssertEqual(summary.windowCount, 4)
    }

    func testSnapshotEncodingAndDecodingAfterRemovingNotes() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let hotkey = makeHotkey()
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [makeWindow(bundleIdentifier: "com.example.editor", title: "One")],
            hotkey: hotkey
        ))
        let fileURL = temporaryDirectoryURL.appendingPathComponent("\(snapshotID.uuidString).json")
        let data = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertFalse(data.contains("\"notes\""))

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)

        XCTAssertEqual(loadedSnapshot.id, snapshotID)
        XCTAssertEqual(loadedSnapshot.name, "Coding")
        XCTAssertEqual(loadedSnapshot.hotkey, hotkey)
        XCTAssertEqual(loadedSnapshot.windows.map(\.bundleIdentifier), ["com.example.editor"])
    }

    func testRemoveAppDeletesMatchingWindowsAndPersistsUpdatedDate() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 200)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                makeWindow(bundleIdentifier: "com.example.editor", title: "One"),
                makeWindow(bundleIdentifier: "com.example.browser", title: "Two"),
                makeWindow(bundleIdentifier: "com.example.editor", title: "Three")
            ]
        ))

        let removedCount = try store.removeApp(
            bundleIdentifier: "com.example.editor",
            from: snapshotID,
            now: updatedAt
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(removedCount, 2)
        XCTAssertEqual(loadedSnapshot.windows.map(\.bundleIdentifier), ["com.example.browser"])
        XCTAssertEqual(loadedSnapshot.updatedAt, updatedAt)
    }

    func testRemoveWindowDeletesOnlyMatchingWindowAndPersistsUpdatedDate() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 200)
        let firstEditorWindow = makeWindow(bundleIdentifier: "com.example.editor", title: "One")
        let browserWindow = makeWindow(bundleIdentifier: "com.example.browser", title: "Two")
        let secondEditorWindow = makeWindow(bundleIdentifier: "com.example.editor", title: "Three")
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                firstEditorWindow,
                browserWindow,
                secondEditorWindow
            ]
        ))

        let didRemoveWindow = try store.removeWindow(
            windowID: firstEditorWindow.id,
            from: snapshotID,
            now: updatedAt
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertTrue(didRemoveWindow)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [
            browserWindow.id,
            secondEditorWindow.id
        ])
        XCTAssertEqual(loadedSnapshot.windows.map(\.bundleIdentifier), [
            "com.example.browser",
            "com.example.editor"
        ])
        XCTAssertEqual(loadedSnapshot.updatedAt, updatedAt)
    }

    func testRemoveWindowRejectsRemovingFinalWindow() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 100)
        let onlyWindow = makeWindow(bundleIdentifier: "com.example.editor", title: "One")
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            updatedAt: originalUpdatedAt,
            windows: [onlyWindow]
        ))

        XCTAssertThrowsError(
            try store.removeWindow(
                windowID: onlyWindow.id,
                from: snapshotID,
                now: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            guard case SnapshotStoreError.layoutRequiresWindow = error else {
                return XCTFail("Expected layoutRequiresWindow, got \(error).")
            }
        }

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [onlyWindow.id])
        XCTAssertEqual(loadedSnapshot.updatedAt, originalUpdatedAt)
    }

    func testRemoveAppRejectsRemovingFinalWindow() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 100)
        let onlyWindow = makeWindow(bundleIdentifier: "com.example.editor", title: "One")
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            updatedAt: originalUpdatedAt,
            windows: [onlyWindow]
        ))

        XCTAssertThrowsError(
            try store.removeApp(
                bundleIdentifier: "com.example.editor",
                from: snapshotID,
                now: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            guard case SnapshotStoreError.layoutRequiresWindow = error else {
                return XCTFail("Expected layoutRequiresWindow, got \(error).")
            }
        }

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [onlyWindow.id])
        XCTAssertEqual(loadedSnapshot.updatedAt, originalUpdatedAt)
    }

    func testReorderDisplayWindowsUpdatesZOrderAndPersistsUpdatedDate() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 300)
        let firstDisplayFront = makeWindow(
            bundleIdentifier: "com.example.editor",
            title: "Front",
            displayID: 1,
            zOrderHint: 1
        )
        let secondDisplayWindow = makeWindow(
            bundleIdentifier: "com.example.chat",
            title: "Other Display",
            displayID: 2,
            zOrderHint: 2
        )
        let firstDisplayMiddle = makeWindow(
            bundleIdentifier: "com.example.browser",
            title: "Middle",
            displayID: 1,
            zOrderHint: 3
        )
        let firstDisplayBack = makeWindow(
            bundleIdentifier: "com.example.terminal",
            title: "Back",
            displayID: 1,
            zOrderHint: 4
        )
        let secondDisplayIgnoredWindow = makeWindow(
            bundleIdentifier: "com.example.mail",
            title: "Ignored",
            displayID: 2,
            zOrderHint: nil
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            windows: [
                firstDisplayFront,
                secondDisplayWindow,
                firstDisplayMiddle,
                firstDisplayBack,
                secondDisplayIgnoredWindow
            ]
        ))

        let didReorder = try store.reorderDisplayWindows(
            snapshotID: snapshotID,
            displayID: 1,
            orderedWindowIDs: [
                firstDisplayBack.id,
                firstDisplayFront.id,
                firstDisplayMiddle.id
            ],
            now: updatedAt
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        let zOrderHintsByID = Dictionary(uniqueKeysWithValues: loadedSnapshot.windows.map { ($0.id, $0.zOrderHint) })
        XCTAssertTrue(didReorder)
        XCTAssertEqual(zOrderHintsByID[firstDisplayBack.id], 1)
        XCTAssertEqual(zOrderHintsByID[secondDisplayWindow.id], 2)
        XCTAssertEqual(zOrderHintsByID[firstDisplayFront.id], 3)
        XCTAssertEqual(zOrderHintsByID[firstDisplayMiddle.id], 4)
        XCTAssertNil(zOrderHintsByID[secondDisplayIgnoredWindow.id] ?? nil)
        XCTAssertEqual(loadedSnapshot.updatedAt, updatedAt)
        XCTAssertEqual(
            loadedSnapshot.windows.first(where: { $0.id == firstDisplayFront.id })?.windowTitle,
            "Front"
        )
    }

    func testReorderDisplayWindowsRejectsIncompleteOrForeignWindowIDs() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 100)
        let displayWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            title: "Display",
            displayID: 1,
            zOrderHint: 1
        )
        let otherDisplayWindow = makeWindow(
            bundleIdentifier: "com.example.browser",
            title: "Other",
            displayID: 2,
            zOrderHint: 2
        )
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            updatedAt: originalUpdatedAt,
            windows: [
                displayWindow,
                otherDisplayWindow
            ]
        ))

        XCTAssertThrowsError(try store.reorderDisplayWindows(
            snapshotID: snapshotID,
            displayID: 1,
            orderedWindowIDs: [displayWindow.id, otherDisplayWindow.id],
            now: Date(timeIntervalSince1970: 300)
        )) { error in
            guard case SnapshotStoreError.invalidWindowOrder = error else {
                XCTFail("Expected invalid window order, got \(error).")
                return
            }
        }

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(loadedSnapshot.updatedAt, originalUpdatedAt)
        XCTAssertEqual(loadedSnapshot.windows.map(\.id), [
            displayWindow.id,
            otherDisplayWindow.id
        ])
    }

    func testRemoveMissingAppDoesNotRewriteSnapshot() throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        let snapshotID = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 100)
        try store.save(makeSnapshot(
            id: snapshotID,
            name: "Coding",
            updatedAt: originalUpdatedAt,
            windows: [
                makeWindow(bundleIdentifier: "com.example.editor", title: "One")
            ]
        ))

        let removedCount = try store.removeApp(
            bundleIdentifier: "com.example.browser",
            from: snapshotID,
            now: Date(timeIntervalSince1970: 200)
        )

        let loadedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(loadedSnapshot.windows.map(\.bundleIdentifier), ["com.example.editor"])
        XCTAssertEqual(loadedSnapshot.updatedAt, originalUpdatedAt)
    }

    private func makeSnapshot(
        id: UUID,
        name: String,
        updatedAt: Date = Date(timeIntervalSince1970: 100),
        windows: [WindowRecord] = [],
        hotkey: HotkeyBinding? = nil
    ) -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: updatedAt,
            sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil),
            windows: windows,
            hotkey: hotkey
        )
    }

    private func makeWindow(
        id: UUID = UUID(),
        bundleIdentifier: String,
        title: String,
        displayID: UInt32? = nil,
        zOrderHint: Int? = nil
    ) -> WindowRecord {
        WindowRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 1,
            windowTitle: title,
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
                windowTitle: title,
                role: "AXWindow",
                subrole: nil,
                capturedFrame: CGRectCodable(x: 10, y: 10, width: 400, height: 300),
                cgWindowID: nil
            )
        )
    }

    private func makeDisplay(id: UInt32) -> DisplayRecord {
        DisplayRecord(
            id: id,
            localizedName: "Display \(id)",
            frame: CGRectCodable(x: Double(id - 1) * 1440, y: 0, width: 1440, height: 900),
            visibleFrame: CGRectCodable(x: Double(id - 1) * 1440, y: 0, width: 1440, height: 860),
            backingScaleFactor: 2,
            isPrimary: id == 1,
            vendorID: nil,
            productID: nil,
            serialNumber: nil
        )
    }

    private func makeHotkey() -> HotkeyBinding {
        HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "Command-Option-K"
        )
    }
}
