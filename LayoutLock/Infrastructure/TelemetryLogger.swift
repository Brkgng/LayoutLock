import AppKit
import Foundation

protocol TelemetryLogging {
    func log(_ event: TelemetryLogEvent)
}

struct NoOpTelemetryLogger: TelemetryLogging {
    func log(_ event: TelemetryLogEvent) {}
}

struct TelemetryLogger: TelemetryLogging {
    static let defaultRetentionPeriod: TimeInterval = 7 * 24 * 60 * 60
    static let defaultMaximumFileSize = 5 * 1024 * 1024

    let eventsLogURL: URL

    private let fileManager: FileManager
    private let retentionPeriod: TimeInterval
    private let maximumFileSize: Int
    private let now: () -> Date
    private let atomicWriter: (Data, URL) throws -> Void

    init(
        eventsLogURL: URL,
        fileManager: FileManager = .default,
        retentionPeriod: TimeInterval = TelemetryLogger.defaultRetentionPeriod,
        maximumFileSize: Int = TelemetryLogger.defaultMaximumFileSize,
        now: @escaping () -> Date = Date.init,
        atomicWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.eventsLogURL = eventsLogURL
        self.fileManager = fileManager
        self.retentionPeriod = retentionPeriod
        self.maximumFileSize = maximumFileSize
        self.now = now
        self.atomicWriter = atomicWriter
    }

    func log(_ event: TelemetryLogEvent) {
        do {
            try fileManager.createDirectory(
                at: eventsLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var data = try Self.encoder.encode(event)
            data.append(0x0A)
            guard data.count <= maximumFileSize else {
                return
            }

            var retainedLines = try loadRetainedLines()
            retainedLines.append(data)
            try writeBoundedLines(retainedLines)
        } catch {
            return
        }
    }

    func performMaintenance() {
        do {
            guard fileManager.fileExists(atPath: eventsLogURL.path) else {
                return
            }

            try writeBoundedLines(loadRetainedLines())
        } catch {
            return
        }
    }

    private func loadRetainedLines() throws -> [Data] {
        guard fileManager.fileExists(atPath: eventsLogURL.path) else {
            return []
        }

        let data = try Data(contentsOf: eventsLogURL)
        let cutoff = now().addingTimeInterval(-retentionPeriod)
        return Self.rawLines(in: data).compactMap { line -> Data? in
            guard let event = try? Self.decoder.decode(TelemetryLogEvent.self, from: line),
                  event.timestamp >= cutoff else {
                return nil
            }

            return try? Self.encodedLine(for: event)
        }
    }

    private func writeBoundedLines(_ lines: [Data]) throws {
        let retainedLines = Self.linesWithinSizeLimit(lines, maximumFileSize: maximumFileSize)
        try atomicWriter(Self.data(from: retainedLines), eventsLogURL)
    }

    private static func rawLines(in data: Data) -> [Data] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { Data($0.utf8) }
    }

    private static func encodedLine(for event: TelemetryLogEvent) throws -> Data {
        withTrailingNewline(try encoder.encode(event))
    }

    private static func withTrailingNewline(_ data: Data) -> Data {
        var line = data
        line.append(0x0A)
        return line
    }

    private static func linesWithinSizeLimit(
        _ lines: [Data],
        maximumFileSize: Int
    ) -> [Data] {
        var retainedLines: [Data] = []
        var retainedSize = 0

        for line in lines.reversed() where line.count <= maximumFileSize {
            guard retainedSize + line.count <= maximumFileSize else {
                break
            }

            retainedLines.append(line)
            retainedSize += line.count
        }

        return Array(retainedLines.reversed())
    }

    private static func data(from lines: [Data]) -> Data {
        lines.reduce(into: Data()) { data, line in
            data.append(line)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct DiagnosticLogController {
    let eventsLogURL: URL

    private let fileManager: FileManager
    private let fileRevealer: (URL) -> Void
    private let directoryRevealer: (URL) -> Void
    private let exportDestinationProvider: (String) -> URL?
    private let supportEmailComposerProvider: () -> DiagnosticLogEmailComposer?
    private let now: () -> Date

    init(
        eventsLogURL: URL,
        fileManager: FileManager = .default,
        fileRevealer: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        },
        directoryRevealer: @escaping (URL) -> Void = {
            NSWorkspace.shared.open($0)
        },
        exportDestinationProvider: @escaping (String) -> URL? = { suggestedFilename in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else {
                return nil
            }

            return panel.url
        },
        supportEmailComposerProvider: @escaping () -> DiagnosticLogEmailComposer? = {
            guard let service = NSSharingService(named: .composeEmail) else {
                return nil
            }

            return DiagnosticLogEmailComposer(
                canPerform: { body, attachmentURL in
                    service.canPerform(withItems: [body, attachmentURL])
                },
                compose: { recipient, subject, body, attachmentURL in
                    service.recipients = [recipient]
                    service.subject = subject
                    service.perform(withItems: [body, attachmentURL])
                }
            )
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.eventsLogURL = eventsLogURL
        self.fileManager = fileManager
        self.fileRevealer = fileRevealer
        self.directoryRevealer = directoryRevealer
        self.exportDestinationProvider = exportDestinationProvider
        self.supportEmailComposerProvider = supportEmailComposerProvider
        self.now = now
    }

    var hasLog: Bool {
        fileManager.fileExists(atPath: eventsLogURL.path)
    }

    func composeSupportEmail(to recipient: String, subject: String, body: String) -> Bool {
        guard hasLog,
              let supportEmailComposer = supportEmailComposerProvider(),
              supportEmailComposer.canPerform(body, eventsLogURL) else {
            return false
        }

        supportEmailComposer.compose(recipient, subject, body, eventsLogURL)
        return true
    }

    func revealInFinder() {
        if hasLog {
            fileRevealer(eventsLogURL)
        } else {
            directoryRevealer(eventsLogURL.deletingLastPathComponent())
        }
    }

    func export() throws -> DiagnosticLogExportResult {
        guard hasLog else {
            return .noLog
        }

        let data = try Data(contentsOf: eventsLogURL)
        guard let destinationURL = exportDestinationProvider(exportFilename) else {
            return .cancelled
        }

        try data.write(to: destinationURL, options: .atomic)
        return .exported(destinationURL)
    }

    func clear() throws {
        guard hasLog else {
            return
        }

        try fileManager.removeItem(at: eventsLogURL)
    }

    private var exportFilename: String {
        "LayoutLock-Diagnostic-Log-\(Self.filenameFormatter.string(from: now())).jsonl"
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct DiagnosticLogEmailComposer {
    let canPerform: (String, URL) -> Bool
    let compose: (String, String, String, URL) -> Void
}

enum DiagnosticLogExportResult: Equatable {
    case exported(URL)
    case cancelled
    case noLog
}

struct TelemetryLogEvent: Codable {
    let id: UUID
    let timestamp: Date
    let name: String
    let snapshotID: UUID?
    let savedWindowCount: Int?
    let capturedWindowCount: Int?
    let displayCount: Int?
    let restoredWindowCount: Int?
    let skippedWindowCount: Int?
    let downgradedWindowCount: Int?
    let displayFallbackCount: Int?
    let minimizedWindowCount: Int?
    let fullscreenWindowCount: Int?
    let visibleWindowCount: Int?
    let errorReason: String?
    let details: [TelemetryLogDetail]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        name: String,
        snapshotID: UUID? = nil,
        savedWindowCount: Int? = nil,
        capturedWindowCount: Int? = nil,
        displayCount: Int? = nil,
        restoredWindowCount: Int? = nil,
        skippedWindowCount: Int? = nil,
        downgradedWindowCount: Int? = nil,
        displayFallbackCount: Int? = nil,
        minimizedWindowCount: Int? = nil,
        fullscreenWindowCount: Int? = nil,
        visibleWindowCount: Int? = nil,
        errorReason: String? = nil,
        details: [TelemetryLogDetail] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.snapshotID = snapshotID
        self.savedWindowCount = savedWindowCount
        self.capturedWindowCount = capturedWindowCount
        self.displayCount = displayCount
        self.restoredWindowCount = restoredWindowCount
        self.skippedWindowCount = skippedWindowCount
        self.downgradedWindowCount = downgradedWindowCount
        self.displayFallbackCount = displayFallbackCount
        self.minimizedWindowCount = minimizedWindowCount
        self.fullscreenWindowCount = fullscreenWindowCount
        self.visibleWindowCount = visibleWindowCount
        self.errorReason = errorReason
        self.details = details
    }
}

struct TelemetryLogDetail: Codable, Equatable {
    let kind: String
    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let reason: String?
    let targetKind: String?
    let savedDisplayID: UInt32?
    let resolvedDisplayID: UInt32?
    let windowID: UUID?
    let matchStrategy: String?
    let candidateCount: Int?
    let filteredCandidateCount: Int?
    let readinessTimedOut: Bool?
    let geometryAttempted: Bool?
    let geometryAttemptCount: Int?
    let expectedFrame: CGRectCodable?
    let finalObservedFrame: CGRectCodable?
    let displayOutcome: String?
    let result: String?

    init(
        kind: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        reason: String? = nil,
        targetKind: String? = nil,
        savedDisplayID: UInt32? = nil,
        resolvedDisplayID: UInt32? = nil,
        windowID: UUID? = nil,
        matchStrategy: String? = nil,
        candidateCount: Int? = nil,
        filteredCandidateCount: Int? = nil,
        readinessTimedOut: Bool? = nil,
        geometryAttempted: Bool? = nil,
        geometryAttemptCount: Int? = nil,
        expectedFrame: CGRectCodable? = nil,
        finalObservedFrame: CGRectCodable? = nil,
        displayOutcome: String? = nil,
        result: String? = nil
    ) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.reason = reason
        self.targetKind = targetKind
        self.savedDisplayID = savedDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.windowID = windowID
        self.matchStrategy = matchStrategy
        self.candidateCount = candidateCount
        self.filteredCandidateCount = filteredCandidateCount
        self.readinessTimedOut = readinessTimedOut
        self.geometryAttempted = geometryAttempted
        self.geometryAttemptCount = geometryAttemptCount
        self.expectedFrame = expectedFrame
        self.finalObservedFrame = finalObservedFrame
        self.displayOutcome = displayOutcome
        self.result = result
    }
}

extension TelemetryLogEvent {
    static func captureCompleted(
        snapshot: Snapshot,
        discoveryDiagnostics: [WindowDiscoveryDiagnostic]
    ) -> TelemetryLogEvent {
        TelemetryLogEvent(
            name: "capture.completed",
            snapshotID: snapshot.id,
            capturedWindowCount: snapshot.windows.count,
            displayCount: snapshot.sourceDisplayState.displays.count,
            minimizedWindowCount: snapshot.windows.filter(\.isMinimized).count,
            fullscreenWindowCount: snapshot.windows.filter(\.isFullscreen).count,
            visibleWindowCount: snapshot.windows.filter(\.isVisible).count,
            details: discoveryDiagnostics.map(TelemetryLogDetail.init(discoveryDiagnostic:))
        )
    }

    static func captureFailed(
        error: Error
    ) -> TelemetryLogEvent {
        TelemetryLogEvent(
            name: "capture.failed",
            errorReason: error.userFacingDescription
        )
    }

    static func restoreCompleted(
        snapshot: Snapshot,
        result: RestoreResult
    ) -> TelemetryLogEvent {
        TelemetryLogEvent(
            name: "restore.completed",
            snapshotID: snapshot.id,
            savedWindowCount: snapshot.windows.count,
            restoredWindowCount: result.restoredWindows,
            skippedWindowCount: result.skippedItems.count,
            downgradedWindowCount: result.downgradedItems.count,
            displayFallbackCount: result.displayFallbacks.count,
            details: result.telemetryDetails
        )
    }

    static func restoreFailed(
        snapshotID: UUID,
        error: Error
    ) -> TelemetryLogEvent {
        TelemetryLogEvent(
            name: "restore.failed",
            snapshotID: snapshotID,
            errorReason: error.userFacingDescription
        )
    }

    static func browserAutomation(
        browser: BrowserAutomationBrowser,
        outcome: String
    ) -> TelemetryLogEvent {
        TelemetryLogEvent(
            name: "browserAutomation.permission",
            details: [
                TelemetryLogDetail(
                    kind: "browserAutomation",
                    bundleIdentifier: browser.bundleIdentifier,
                    reason: outcome
                )
            ]
        )
    }

}

private extension TelemetryLogDetail {
    init(discoveryDiagnostic: WindowDiscoveryDiagnostic) {
        self.init(
            kind: discoveryDiagnostic.kind.rawValue,
            bundleIdentifier: discoveryDiagnostic.bundleIdentifier,
            processIdentifier: discoveryDiagnostic.processIdentifier,
            reason: discoveryDiagnostic.reason
        )
    }
}

private extension RestoreResult {
    var telemetryDetails: [TelemetryLogDetail] {
        skippedItems.map {
            TelemetryLogDetail(
                kind: "restoreSkipped",
                bundleIdentifier: $0.bundleIdentifier,
                reason: $0.reason
            )
        } +
        downgradedItems.map {
            TelemetryLogDetail(
                kind: "restoreDowngraded",
                bundleIdentifier: $0.bundleIdentifier,
                reason: $0.reason
            )
        } +
        displayFallbacks.map {
            TelemetryLogDetail(
                kind: "displayFallback",
                bundleIdentifier: $0.bundleIdentifier,
                reason: $0.reason,
                savedDisplayID: $0.savedDisplayID,
                resolvedDisplayID: $0.resolvedDisplayID,
                windowID: $0.windowID,
                displayOutcome: $0.outcome.rawValue
            )
        } +
        targetIssues.map {
            TelemetryLogDetail(
                kind: "restoreTargetIssue",
                bundleIdentifier: $0.bundleIdentifier,
                reason: $0.reason.rawValue,
                targetKind: $0.target.kind.rawValue
            )
        } +
        windowDiagnostics.map {
            TelemetryLogDetail(
                kind: "restoreWindow",
                bundleIdentifier: $0.bundleIdentifier,
                reason: $0.reason,
                windowID: $0.windowID,
                matchStrategy: $0.matchStrategy?.rawValue,
                candidateCount: $0.candidateCount,
                filteredCandidateCount: $0.filteredCandidateCount,
                readinessTimedOut: $0.readinessTimedOut,
                geometryAttempted: $0.geometryAttempted,
                geometryAttemptCount: $0.geometryAttemptCount,
                expectedFrame: $0.expectedFrame.map(CGRectCodable.init),
                finalObservedFrame: $0.finalObservedFrame.map(CGRectCodable.init),
                displayOutcome: $0.displayOutcome?.rawValue,
                result: $0.result
            )
        } +
        discoveryDiagnostics.map(TelemetryLogDetail.init(discoveryDiagnostic:))
    }
}
