import CoreGraphics
import Foundation
import XCTest
@testable import LayoutLock

final class TelemetryLoggerTests: XCTestCase {
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

    func testLoggerWritesSingleJSONLine() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let logger = TelemetryLogger(eventsLogURL: logURL)
        let event = TelemetryLogEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            name: "capture.failed",
            errorReason: "Accessibility denied"
        )

        logger.log(event)

        let events = try readEvents(from: logURL)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, "capture.failed")
        XCTAssertEqual(events.first?.errorReason, "Accessibility denied")
    }

    func testLoggerAppendsMultipleEvents() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let logger = TelemetryLogger(eventsLogURL: logURL)

        logger.log(TelemetryLogEvent(name: "capture.completed"))
        logger.log(TelemetryLogEvent(name: "restore.completed"))

        let rawLog = try String(contentsOf: logURL, encoding: .utf8)
        let lines = rawLog.split(separator: "\n")
        let events = try readEvents(from: logURL)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(events.map(\.name), ["capture.completed", "restore.completed"])
    }

    func testRestoreEventOmitsSnapshotNamesAndWindowTitlesFromEncodedJSON() throws {
        let snapshot = makeSnapshot(
            name: "Secret Snapshot Name",
            windowTitle: "Secret Project Document"
        )
        let result = RestoreResult(
            restoredWindows: 1,
            skippedItems: [
                RestoreSkip(
                    bundleIdentifier: "com.example.editor",
                    windowTitle: "Secret Skipped Document",
                    reason: RestoreSkipReason.windowNotFound
                )
            ],
            downgradedItems: [
                RestoreDowngrade(
                    bundleIdentifier: "com.example.browser",
                    windowTitle: "Secret Fullscreen Tab",
                    reason: "fullscreen restored as standard window"
                )
            ],
            displayFallbacks: [
                DisplayFallbackEvent(
                    savedDisplayID: 10,
                    resolvedDisplayID: 20,
                    reason: "primary display fallback"
                )
            ],
            requestedTargetCount: 1,
            targetIssues: [
                RestoreTargetIssue(
                    windowID: UUID(),
                    bundleIdentifier: "com.example.editor",
                    windowTitle: "Secret Target Window",
                    target: WindowOpenTarget(
                        kind: .file,
                        url: URL(fileURLWithPath: "/Users/example/Secret Project.txt")
                    ),
                    reason: .openRequestFailed
                ),
                RestoreTargetIssue(
                    windowID: UUID(),
                    bundleIdentifier: "com.example.browser",
                    windowTitle: "Secret Browser Window",
                    target: WindowOpenTarget(
                        kind: .webURL,
                        url: URL(string: "https://secret.example.com/private")!
                    ),
                    reason: .unsupportedURL
                )
            ],
            windowDiagnostics: [
                RestoreWindowDiagnostic(
                    windowID: snapshot.windows[0].id,
                    bundleIdentifier: "com.example.editor",
                    matchStrategy: .scored,
                    candidateCount: 2,
                    filteredCandidateCount: 1,
                    readinessTimedOut: false,
                    geometryAttempted: true,
                    geometryAttemptCount: 2,
                    expectedFrame: CGRect(x: -1000, y: 20, width: 800, height: 600),
                    finalObservedFrame: CGRect(x: -1000, y: 20, width: 800, height: 600),
                    displayOutcome: .hardwareRemap,
                    result: "restored",
                    reason: nil
                )
            ]
        )
        let event = TelemetryLogEvent.restoreCompleted(snapshot: snapshot, result: result)

        let data = try encoder.encode(event)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("Secret Snapshot Name"))
        XCTAssertFalse(json.contains("Secret Project Document"))
        XCTAssertFalse(json.contains("Secret Skipped Document"))
        XCTAssertFalse(json.contains("Secret Fullscreen Tab"))
        XCTAssertFalse(json.contains("Secret Target Window"))
        XCTAssertFalse(json.contains("Secret Browser Window"))
        XCTAssertFalse(json.contains("Secret Project.txt"))
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("secret.example.com"))
        XCTAssertFalse(json.contains("/private"))
        XCTAssertTrue(json.contains("com.example.editor"))
        XCTAssertTrue(json.contains("primary display fallback"))
        XCTAssertTrue(json.contains("openRequestFailed"))
        XCTAssertTrue(json.contains("\"targetKind\":\"file\""))
        XCTAssertTrue(json.contains("\"targetKind\":\"webURL\""))
        XCTAssertTrue(json.contains("\"matchStrategy\":\"scored\""))
        XCTAssertTrue(json.contains("\"displayOutcome\":\"hardwareRemap\""))
        XCTAssertTrue(json.contains("unsupportedURL"))
    }

    func testMaintenanceRemovesExpiredAndMalformedEntriesWhileRetainingBoundaryEntry() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let retentionPeriod = TelemetryLogger.defaultRetentionPeriod
        let expiredEvent = TelemetryLogEvent(
            timestamp: now.addingTimeInterval(-retentionPeriod - 1),
            name: "expired"
        )
        let boundaryEvent = TelemetryLogEvent(
            timestamp: now.addingTimeInterval(-retentionPeriod),
            name: "boundary"
        )
        let recentEvent = TelemetryLogEvent(
            timestamp: now.addingTimeInterval(-1),
            name: "recent"
        )
        var data = try encodedLine(for: expiredEvent)
        data.append(Data("not-json\n".utf8))
        data.append(try encodedLine(for: boundaryEvent))
        data.append(try encodedLine(for: recentEvent))
        try data.write(to: logURL)
        let logger = TelemetryLogger(eventsLogURL: logURL, now: { now })

        logger.performMaintenance()

        XCTAssertEqual(try readEvents(from: logURL).map(\.name), ["boundary", "recent"])
    }

    func testMaintenanceReadsLegacyEventsContainingSnapshotName() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let event = TelemetryLogEvent(timestamp: now, name: "capture.completed")
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        let legacyJSON = json.dropLast() + ",\"snapshotName\":\"Secret Snapshot Name\"}\n"
        try Data(legacyJSON.utf8).write(to: logURL)
        let logger = TelemetryLogger(eventsLogURL: logURL, now: { now })

        logger.performMaintenance()

        XCTAssertEqual(try readEvents(from: logURL).map(\.name), ["capture.completed"])
        XCTAssertFalse(try String(contentsOf: logURL, encoding: .utf8).contains("Secret Snapshot Name"))
    }

    func testLoggerRemovesOldestCompleteLinesToEnforceMaximumFileSize() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = [
            TelemetryLogEvent(timestamp: now, name: "event.one"),
            TelemetryLogEvent(timestamp: now, name: "event.two"),
            TelemetryLogEvent(timestamp: now, name: "event.six")
        ]
        let maximumFileSize = try encodedLine(for: events[1]).count + encodedLine(for: events[2]).count
        var committedPayloads: [Data] = []
        let logger = TelemetryLogger(
            eventsLogURL: logURL,
            maximumFileSize: maximumFileSize,
            now: { now },
            atomicWriter: { data, url in
                committedPayloads.append(data)
                try data.write(to: url, options: .atomic)
            }
        )

        events.forEach(logger.log)

        XCTAssertTrue(committedPayloads.allSatisfy { $0.count <= maximumFileSize })
        XCTAssertLessThanOrEqual(try Data(contentsOf: logURL).count, maximumFileSize)
        XCTAssertEqual(try readEvents(from: logURL).map(\.name), ["event.two", "event.six"])
    }

    func testLoggerLeavesExistingBoundedLogUnchangedWhenAtomicWriteFails() throws {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let existingEvents = [
            TelemetryLogEvent(timestamp: now, name: "event.one"),
            TelemetryLogEvent(timestamp: now, name: "event.two")
        ]
        var originalData = try encodedLine(for: existingEvents[0])
        originalData.append(try encodedLine(for: existingEvents[1]))
        try originalData.write(to: logURL, options: .atomic)
        let logger = TelemetryLogger(
            eventsLogURL: logURL,
            maximumFileSize: originalData.count,
            now: { now },
            atomicWriter: { _, _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )

        logger.log(TelemetryLogEvent(timestamp: now, name: "event.three"))

        XCTAssertEqual(try Data(contentsOf: logURL), originalData)
        XCTAssertLessThanOrEqual(try Data(contentsOf: logURL).count, originalData.count)
    }

    func testLoggerDropsSingleEventLargerThanMaximumFileSize() {
        let logURL = temporaryDirectoryURL.appendingPathComponent("events.log")
        let logger = TelemetryLogger(eventsLogURL: logURL, maximumFileSize: 1)

        logger.log(TelemetryLogEvent(name: "capture.completed"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testLoggerSwallowsWriteFailures() throws {
        let blockedParentURL = temporaryDirectoryURL.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParentURL)
        let logger = TelemetryLogger(
            eventsLogURL: blockedParentURL.appendingPathComponent("events.log")
        )

        logger.log(TelemetryLogEvent(name: "capture.completed"))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: blockedParentURL.appendingPathComponent("events.log").path
            )
        )
    }

    func testCaptureCompletedEventIncludesCountsAndDiscoveryDiagnostics() {
        let snapshot = makeSnapshot(
            windows: [
                makeWindowRecord(
                    bundleIdentifier: "com.example.editor",
                    windowTitle: "Ignored Title",
                    isMinimized: true,
                    isFullscreen: false,
                    isVisible: true
                ),
                makeWindowRecord(
                    bundleIdentifier: "com.example.browser",
                    windowTitle: nil,
                    isMinimized: false,
                    isFullscreen: true,
                    isVisible: false
                )
            ]
        )
        let diagnostic = WindowDiscoveryDiagnostic(
            bundleIdentifier: "com.example.utility",
            processIdentifier: 42,
            reason: WindowDiscoveryDiagnosticReason.transientRole
        )

        let event = TelemetryLogEvent.captureCompleted(
            snapshot: snapshot,
            discoveryDiagnostics: [diagnostic]
        )

        XCTAssertEqual(event.name, "capture.completed")
        XCTAssertEqual(event.capturedWindowCount, 2)
        XCTAssertEqual(event.displayCount, 1)
        XCTAssertEqual(event.minimizedWindowCount, 1)
        XCTAssertEqual(event.fullscreenWindowCount, 1)
        XCTAssertEqual(event.visibleWindowCount, 1)
        XCTAssertEqual(
            event.details,
            [
                TelemetryLogDetail(
                    kind: "windowRejected",
                    bundleIdentifier: "com.example.utility",
                    processIdentifier: 42,
                    reason: WindowDiscoveryDiagnosticReason.transientRole
                )
            ]
        )
    }

    func testBrowserAutomationTelemetryContainsOnlyFixedBrowserMetadata() throws {
        let event = TelemetryLogEvent.browserAutomation(
            browser: .safari,
            outcome: BrowserCaptureIssueReason.queryFailed.rawValue
        )
        let encoded = try JSONEncoder().encode(event)
        let rawJSON = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(event.name, "browserAutomation.permission")
        XCTAssertEqual(event.details.count, 1)
        XCTAssertEqual(event.details[0].bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(event.details[0].reason, "queryFailed")
        XCTAssertFalse(rawJSON.contains("https://"))
        XCTAssertFalse(rawJSON.contains("tab title"))
    }

    func testRestoreCompletedEventIncludesSummaryAndDetails() {
        let snapshot = makeSnapshot()
        let result = RestoreResult(
            restoredWindows: 3,
            skippedItems: [
                RestoreSkip(
                    bundleIdentifier: "com.example.missing",
                    windowTitle: "Ignored Title",
                    reason: RestoreSkipReason.appNotRunning
                )
            ],
            downgradedItems: [
                RestoreDowngrade(
                    bundleIdentifier: "com.example.video",
                    windowTitle: "Ignored Title",
                    reason: "fullscreen restored as standard window"
                )
            ],
            displayFallbacks: [
                DisplayFallbackEvent(
                    savedDisplayID: 1,
                    resolvedDisplayID: 2,
                    reason: "hardware match"
                )
            ],
            requestedTargetCount: 1,
            targetIssues: [
                RestoreTargetIssue(
                    windowID: UUID(),
                    bundleIdentifier: "com.example.editor",
                    windowTitle: "Ignored Target Title",
                    target: WindowOpenTarget(
                        kind: .folder,
                        url: URL(fileURLWithPath: "/private/ignored")
                    ),
                    reason: .missingTarget
                )
            ]
        )

        let event = TelemetryLogEvent.restoreCompleted(snapshot: snapshot, result: result)

        XCTAssertEqual(event.name, "restore.completed")
        XCTAssertEqual(event.savedWindowCount, 1)
        XCTAssertEqual(event.restoredWindowCount, 3)
        XCTAssertEqual(event.skippedWindowCount, 1)
        XCTAssertEqual(event.downgradedWindowCount, 1)
        XCTAssertEqual(event.displayFallbackCount, 1)
        XCTAssertEqual(event.details.count, 4)
        XCTAssertEqual(event.details.map(\.kind), [
            "restoreSkipped",
            "restoreDowngraded",
            "displayFallback",
            "restoreTargetIssue"
        ])
        XCTAssertEqual(event.details.last?.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(event.details.last?.reason, "missingTarget")
        XCTAssertEqual(event.details.last?.targetKind, "folder")
    }

    private func readEvents(from logURL: URL) throws -> [TelemetryLogEvent] {
        let data = try Data(contentsOf: logURL)
        let rawLog = String(decoding: data, as: UTF8.self)
        return try rawLog.split(separator: "\n").map { line in
            try decoder.decode(TelemetryLogEvent.self, from: Data(line.utf8))
        }
    }

    private func encodedLine(for event: TelemetryLogEvent) throws -> Data {
        var data = try encoder.encode(event)
        data.append(0x0A)
        return data
    }

    private func makeSnapshot(
        id: UUID = UUID(),
        name: String = "Coding",
        windowTitle: String? = "Window",
        windows: [WindowRecord]? = nil
    ) -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            sourceDisplayState: DisplayState(
                displays: [
                    DisplayRecord(
                        id: 1,
                        localizedName: "Display",
                        frame: CGRectCodable(x: 0, y: 0, width: 1000, height: 800),
                        visibleFrame: CGRectCodable(x: 0, y: 0, width: 1000, height: 760),
                        backingScaleFactor: 2,
                        isPrimary: true,
                        vendorID: nil,
                        productID: nil,
                        serialNumber: nil
                    )
                ],
                primaryDisplayID: 1
            ),
            windows: windows ?? [
                makeWindowRecord(windowTitle: windowTitle)
            ]
        )
    }

    private func makeWindowRecord(
        bundleIdentifier: String = "com.example.editor",
        windowTitle: String? = "Window",
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        isVisible: Bool = true
    ) -> WindowRecord {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        return WindowRecord(
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 42,
            windowTitle: windowTitle,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRectCodable(frame),
            displayID: 1,
            normalizedFrame: NormalizedRect(
                xRatio: 0.1,
                yRatio: 0.1,
                widthRatio: 0.3,
                heightRatio: 0.25
            ),
            zOrderHint: nil,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isVisible: isVisible,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: 42,
                windowTitle: windowTitle,
                role: "AXWindow",
                subrole: "AXStandardWindow",
                capturedFrame: CGRectCodable(frame),
                cgWindowID: nil
            )
        )
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

final class DiagnosticLogControllerTests: XCTestCase {
    func testHasLogReflectsFileCreationAndClearing() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        let controller = DiagnosticLogController(eventsLogURL: logURL)

        XCTAssertFalse(controller.hasLog)

        try Data("log".utf8).write(to: logURL)
        XCTAssertTrue(controller.hasLog)

        try controller.clear()
        XCTAssertFalse(controller.hasLog)
    }

    func testComposeSupportEmailUsesExistingLogAsAttachment() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        var validatedItems: [(body: String, attachmentURL: URL)] = []
        var composedEmails: [(recipient: String, subject: String, body: String, attachmentURL: URL)] = []
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            supportEmailComposerProvider: {
                DiagnosticLogEmailComposer(
                    canPerform: { body, attachmentURL in
                        validatedItems.append((body, attachmentURL))
                        return true
                    },
                    compose: { recipient, subject, body, attachmentURL in
                        composedEmails.append((recipient, subject, body, attachmentURL))
                    }
                )
            }
        )

        XCTAssertTrue(
            controller.composeSupportEmail(
                to: "support@example.com",
                subject: "LayoutLock Feedback (v1.0)",
                body: "\n\n"
            )
        )
        XCTAssertEqual(validatedItems.count, 1)
        XCTAssertEqual(validatedItems.first?.body, "\n\n")
        XCTAssertEqual(validatedItems.first?.attachmentURL, logURL)
        XCTAssertEqual(composedEmails.count, 1)
        XCTAssertEqual(composedEmails.first?.recipient, "support@example.com")
        XCTAssertEqual(composedEmails.first?.subject, "LayoutLock Feedback (v1.0)")
        XCTAssertEqual(composedEmails.first?.body, "\n\n")
        XCTAssertEqual(composedEmails.first?.attachmentURL, logURL)
    }

    func testComposeSupportEmailReturnsFalseWhenLogIsMissing() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        var didAttemptComposition = false
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            supportEmailComposerProvider: {
                didAttemptComposition = true
                return DiagnosticLogEmailComposer(
                    canPerform: { _, _ in true },
                    compose: { _, _, _, _ in }
                )
            }
        )

        XCTAssertFalse(
            controller.composeSupportEmail(
                to: "support@example.com",
                subject: "LayoutLock Feedback",
                body: "\n\n"
            )
        )
        XCTAssertFalse(didAttemptComposition)
    }

    func testComposeSupportEmailReturnsFalseWhenNativeComposerIsUnavailable() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            supportEmailComposerProvider: { nil }
        )

        XCTAssertFalse(
            controller.composeSupportEmail(
                to: "support@example.com",
                subject: "LayoutLock Feedback",
                body: "\n\n"
            )
        )
    }

    func testComposeSupportEmailReturnsFalseWhenNativeComposerCannotHandleAttachment() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            supportEmailComposerProvider: {
                DiagnosticLogEmailComposer(
                    canPerform: { _, _ in false },
                    compose: { _, _, _, _ in
                        XCTFail("Composition should not start for an unsupported attachment.")
                    }
                )
            }
        )

        XCTAssertFalse(
            controller.composeSupportEmail(
                to: "support@example.com",
                subject: "LayoutLock Feedback",
                body: "\n\n"
            )
        )
    }

    func testExportCopiesRawBytesAndUsesTimestampedJSONLFilename() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        let exportURL = temporaryDirectory.url.appendingPathComponent("export.jsonl")
        let rawLog = Data("{\"name\":\"capture.completed\"}\n".utf8)
        try rawLog.write(to: logURL)
        var suggestedFilenames: [String] = []
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            exportDestinationProvider: {
                suggestedFilenames.append($0)
                return exportURL
            },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let result = try controller.export()

        XCTAssertEqual(result, .exported(exportURL))
        XCTAssertEqual(suggestedFilenames, ["LayoutLock-Diagnostic-Log-19700101-000000.jsonl"])
        XCTAssertEqual(try Data(contentsOf: exportURL), rawLog)
    }

    func testExportReturnsCancelledWithoutWritingWhenDestinationSelectionIsCancelled() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            exportDestinationProvider: { _ in nil }
        )

        XCTAssertEqual(try controller.export(), .cancelled)
    }

    func testExportReturnsNoLogWithoutRequestingDestinationWhenLogIsMissing() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        var didRequestDestination = false
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            exportDestinationProvider: { _ in
                didRequestDestination = true
                return temporaryDirectory.url.appendingPathComponent("export.jsonl")
            }
        )

        XCTAssertEqual(try controller.export(), .noLog)
        XCTAssertFalse(didRequestDestination)
    }

    func testExportThrowsWhenDestinationCannotBeWritten() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        let blockedParentURL = temporaryDirectory.url.appendingPathComponent("blocked")
        try Data("log".utf8).write(to: logURL)
        try Data("not a directory".utf8).write(to: blockedParentURL)
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            exportDestinationProvider: { _ in
                blockedParentURL.appendingPathComponent("export.jsonl")
            }
        )

        XCTAssertThrowsError(try controller.export())
    }

    func testClearRemovesExistingLogAndSucceedsWhenRepeated() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        let controller = DiagnosticLogController(eventsLogURL: logURL)

        try controller.clear()
        try controller.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testRevealSelectsExistingLogFile() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: logURL)
        var revealedFiles: [URL] = []
        var revealedDirectories: [URL] = []
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            fileRevealer: { revealedFiles.append($0) },
            directoryRevealer: { revealedDirectories.append($0) }
        )

        controller.revealInFinder()

        XCTAssertEqual(revealedFiles, [logURL])
        XCTAssertTrue(revealedDirectories.isEmpty)
    }

    func testRevealOpensLogsDirectoryWhenLogFileIsMissing() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let logURL = temporaryDirectory.url.appendingPathComponent("events.log")
        var revealedFiles: [URL] = []
        var revealedDirectories: [URL] = []
        let controller = DiagnosticLogController(
            eventsLogURL: logURL,
            fileRevealer: { revealedFiles.append($0) },
            directoryRevealer: { revealedDirectories.append($0) }
        )

        controller.revealInFinder()

        XCTAssertTrue(revealedFiles.isEmpty)
        XCTAssertEqual(revealedDirectories, [temporaryDirectory.url])
    }
}
