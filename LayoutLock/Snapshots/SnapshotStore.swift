import Foundation

struct SnapshotSummary: Identifiable {
    let id: UUID
    let appCount: Int
    let name: String
    let createdAt: Date
    let displayCount: Int
    let updatedAt: Date
    let windowCount: Int
    let hotkey: HotkeyBinding?

    init(snapshot: Snapshot) {
        let appIdentifiers = Set(snapshot.windows.map(\.bundleIdentifier))
        let savedDisplayIDs = Set(snapshot.sourceDisplayState.displays.map(\.id))
        let occupiedDisplayIDs = Set(snapshot.windows.compactMap(\.displayID).filter(savedDisplayIDs.contains))
        id = snapshot.id
        appCount = appIdentifiers.count
        name = snapshot.name
        createdAt = snapshot.createdAt
        displayCount = occupiedDisplayIDs.count
        updatedAt = snapshot.updatedAt
        windowCount = snapshot.windows.count
        hotkey = snapshot.hotkey
    }
}

enum SnapshotStoreError: Error {
    case notFound(UUID)
    case invalidName
    case layoutRequiresWindow
    case invalidHotkeyAssignment
    case invalidWindowOrder
    case duplicateHotkeyAssignment(String)
    case unsupportedSchemaVersion(Int)
    case snapshotIdentityMismatch(URL, expected: UUID, actual: UUID)
    case directoryReadFailed(Error)
    case snapshotDecodeFailed(URL, Error)
    case snapshotWriteFailed(URL, Error)
}

extension SnapshotStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .notFound(id):
            return "The layout \(id.uuidString) could not be found."
        case .invalidName:
            return "Layout names cannot be empty."
        case .layoutRequiresWindow:
            return "A layout must keep at least one saved window. Delete the layout instead."
        case .invalidHotkeyAssignment:
            return "Use a key with Command, Option, or Control."
        case .invalidWindowOrder:
            return "Window order must include each saved window for that display exactly once."
        case let .duplicateHotkeyAssignment(snapshotName):
            return "\"\(snapshotName)\" already uses that hotkey."
        case let .unsupportedSchemaVersion(version):
            return "This layout uses unsupported schema version \(version)."
        case let .snapshotIdentityMismatch(_, expected, actual):
            return "Layout file ID \(actual.uuidString) did not match expected ID \(expected.uuidString)."
        case .directoryReadFailed:
            return "Layout storage could not be accessed."
        case let .snapshotDecodeFailed(fileURL, _):
            return "Layout data at \(fileURL.lastPathComponent) could not be read."
        case let .snapshotWriteFailed(fileURL, _):
            return "Layout data could not be written to \(fileURL.lastPathComponent)."
        }
    }
}

struct SnapshotStore {
    let snapshotsDirectoryURL: URL

    private let fileManager: FileManager

    init(
        snapshotsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.snapshotsDirectoryURL = snapshotsDirectoryURL
        self.fileManager = fileManager
    }

    init(
        bootstrapper: AppSupportDirectoryBootstrapper,
        fileManager: FileManager = .default
    ) {
        self.init(
            snapshotsDirectoryURL: bootstrapper.snapshotsURL,
            fileManager: fileManager
        )
    }

    func listSummaries() throws -> [SnapshotSummary] {
        try ensureSnapshotsDirectoryExists()

        let snapshotFileURLs: [URL]
        do {
            snapshotFileURLs = try fileManager.contentsOfDirectory(
                at: snapshotsDirectoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            throw SnapshotStoreError.directoryReadFailed(error)
        }

        let summaries = snapshotFileURLs.compactMap { fileURL in
            do {
                return try SnapshotSummary(snapshot: loadSnapshot(at: fileURL))
            } catch SnapshotStoreError.snapshotDecodeFailed,
                    SnapshotStoreError.snapshotIdentityMismatch,
                    SnapshotStoreError.unsupportedSchemaVersion {
                return nil
            } catch {
                return nil
            }
        }

        return summaries.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }

            return $0.createdAt > $1.createdAt
        }
    }

    func loadSnapshot(id: UUID) throws -> Snapshot {
        try ensureSnapshotsDirectoryExists()

        let fileURL = snapshotFileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw SnapshotStoreError.notFound(id)
        }

        return try loadSnapshot(at: fileURL)
    }

    func save(_ snapshot: Snapshot) throws {
        try ensureSnapshotsDirectoryExists()

        guard let name = normalizedSnapshotName(snapshot.name) else {
            throw SnapshotStoreError.invalidName
        }

        let snapshotToPersist = Snapshot(
            id: snapshot.id,
            name: name,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            schemaVersion: Snapshot.currentSchemaVersion,
            sourceDisplayState: snapshot.sourceDisplayState,
            windows: snapshot.windows,
            hotkey: snapshot.hotkey
        )

        let destinationURL = snapshotFileURL(for: snapshotToPersist.id)
        let temporaryURL = snapshotsDirectoryURL.appendingPathComponent(
            "\(snapshotToPersist.id.uuidString)-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            let data = try snapshotEncoder().encode(snapshotToPersist)
            try data.write(to: temporaryURL, options: .atomic)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }

            throw SnapshotStoreError.snapshotWriteFailed(destinationURL, error)
        }
    }

    func renameSnapshot(
        id: UUID,
        to name: String,
        now: Date = Date()
    ) throws {
        guard let normalizedName = normalizedSnapshotName(name) else {
            throw SnapshotStoreError.invalidName
        }

        var snapshot = try loadSnapshot(id: id)
        snapshot.name = normalizedName
        snapshot.updatedAt = now
        try save(snapshot)
    }

    @discardableResult
    func removeApp(
        bundleIdentifier: String,
        from id: UUID,
        now: Date = Date()
    ) throws -> Int {
        let snapshot = try loadSnapshot(id: id)
        let remainingWindows = snapshot.windows.filter {
            $0.bundleIdentifier != bundleIdentifier
        }
        let removedWindowCount = snapshot.windows.count - remainingWindows.count

        guard removedWindowCount > 0 else {
            return 0
        }
        guard !remainingWindows.isEmpty else {
            throw SnapshotStoreError.layoutRequiresWindow
        }

        try save(Snapshot(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            updatedAt: now,
            schemaVersion: snapshot.schemaVersion,
            sourceDisplayState: snapshot.sourceDisplayState,
            windows: remainingWindows,
            hotkey: snapshot.hotkey
        ))

        return removedWindowCount
    }

    @discardableResult
    func removeWindow(
        windowID: UUID,
        from id: UUID,
        now: Date = Date()
    ) throws -> Bool {
        let snapshot = try loadSnapshot(id: id)
        let remainingWindows = snapshot.windows.filter {
            $0.id != windowID
        }

        guard remainingWindows.count != snapshot.windows.count else {
            return false
        }
        guard !remainingWindows.isEmpty else {
            throw SnapshotStoreError.layoutRequiresWindow
        }

        try save(Snapshot(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            updatedAt: now,
            schemaVersion: snapshot.schemaVersion,
            sourceDisplayState: snapshot.sourceDisplayState,
            windows: remainingWindows,
            hotkey: snapshot.hotkey
        ))

        return true
    }

    @discardableResult
    func reorderDisplayWindows(
        snapshotID id: UUID,
        displayID: UInt32,
        orderedWindowIDs: [UUID],
        now: Date = Date()
    ) throws -> Bool {
        let snapshot = try loadSnapshot(id: id)
        let displayWindows = snapshot.windows.filter { $0.displayID == displayID }
        let displayWindowIDs = displayWindows.map(\.id)

        guard orderedWindowIDs.count == displayWindowIDs.count,
              Set(orderedWindowIDs).count == orderedWindowIDs.count,
              Set(orderedWindowIDs) == Set(displayWindowIDs) else {
            throw SnapshotStoreError.invalidWindowOrder
        }

        let currentDisplayOrder = Self.sortedWindowsForZOrder(displayWindows).map(\.id)
        guard currentDisplayOrder != orderedWindowIDs else {
            return false
        }

        let displayWindowsByID = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0) })
        let orderedDisplayWindows = orderedWindowIDs.compactMap { displayWindowsByID[$0] }
        let reorderedGlobalWindows = Self.reorderedGlobalWindows(
            in: snapshot.windows,
            displayID: displayID,
            orderedDisplayWindows: orderedDisplayWindows
        )
        let zOrderParticipants = reorderedGlobalWindows.filter { window in
            window.displayID == displayID || window.zOrderHint != nil
        }
        let zOrderHintsByWindowID = Dictionary(
            uniqueKeysWithValues: zOrderParticipants.enumerated().map { index, window in
                (window.id, index + 1)
            }
        )
        let updatedWindows = snapshot.windows.map { window in
            guard let zOrderHint = zOrderHintsByWindowID[window.id] else {
                return window.withZOrderHint(nil)
            }

            return window.withZOrderHint(zOrderHint)
        }

        try save(Snapshot(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            updatedAt: now,
            schemaVersion: snapshot.schemaVersion,
            sourceDisplayState: snapshot.sourceDisplayState,
            windows: updatedWindows,
            hotkey: snapshot.hotkey
        ))

        return true
    }

    @discardableResult
    func setOpeningConfiguration(
        snapshotID id: UUID,
        windowID: UUID,
        manualTargets: [WindowOpenTarget],
        now: Date = Date()
    ) throws -> Bool {
        let snapshot = try loadSnapshot(id: id)
        guard let windowIndex = snapshot.windows.firstIndex(where: { $0.id == windowID }) else {
            return false
        }

        var windows = snapshot.windows
        let currentConfiguration = windows[windowIndex].openingConfiguration
        let updatedConfiguration = currentConfiguration.replacingManualTargets(manualTargets)

        guard updatedConfiguration != currentConfiguration else {
            return false
        }

        windows[windowIndex] = windows[windowIndex].withOpeningConfiguration(updatedConfiguration)
        try save(Snapshot(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            updatedAt: now,
            schemaVersion: snapshot.schemaVersion,
            sourceDisplayState: snapshot.sourceDisplayState,
            windows: windows,
            hotkey: snapshot.hotkey
        ))

        return true
    }

    func setHotkey(
        for id: UUID,
        hotkey: HotkeyBinding?,
        now: Date = Date()
    ) throws {
        var snapshot = try loadSnapshot(id: id)

        if let hotkey {
            do {
                try HotkeyBindingValidator.validate(hotkey)
            } catch {
                throw SnapshotStoreError.invalidHotkeyAssignment
            }

            if let duplicate = try listSummaries().first(where: {
                $0.id != id && $0.hotkey?.matches(hotkey) == true
            }) {
                throw SnapshotStoreError.duplicateHotkeyAssignment(duplicate.name)
            }
        }

        snapshot.hotkey = hotkey
        snapshot.updatedAt = now
        try save(snapshot)
    }

    func deleteSnapshot(id: UUID) throws {
        try ensureSnapshotsDirectoryExists()

        let fileURL = snapshotFileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw SnapshotStoreError.notFound(id)
        }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw SnapshotStoreError.snapshotWriteFailed(fileURL, error)
        }
    }

    private func snapshotFileURL(for id: UUID) -> URL {
        snapshotsDirectoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func ensureSnapshotsDirectoryExists() throws {
        do {
            try fileManager.createDirectory(
                at: snapshotsDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw SnapshotStoreError.directoryReadFailed(error)
        }
    }

    private static func reorderedGlobalWindows(
        in windows: [WindowRecord],
        displayID: UInt32,
        orderedDisplayWindows: [WindowRecord]
    ) -> [WindowRecord] {
        var nextDisplayWindowIndex = 0

        return sortedWindowsForZOrder(windows).map { window in
            guard window.displayID == displayID else {
                return window
            }

            let orderedWindow = orderedDisplayWindows[nextDisplayWindowIndex]
            nextDisplayWindowIndex += 1
            return orderedWindow
        }
    }

    private static func sortedWindowsForZOrder(_ windows: [WindowRecord]) -> [WindowRecord] {
        windows.sorted { lhs, rhs in
            switch (lhs.zOrderHint, rhs.zOrderHint) {
            case let (lhsHint?, rhsHint?) where lhsHint != rhsHint:
                return lhsHint < rhsHint
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    private func loadSnapshot(at fileURL: URL) throws -> Snapshot {
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try snapshotDecoder().decode(Snapshot.self, from: data)
            let expectedIdentifier = try snapshotIdentifier(from: fileURL)

            guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
                throw SnapshotStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
            }

            guard snapshot.id == expectedIdentifier else {
                throw SnapshotStoreError.snapshotIdentityMismatch(
                    fileURL,
                    expected: expectedIdentifier,
                    actual: snapshot.id
                )
            }

            return snapshot
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.snapshotDecodeFailed(fileURL, error)
        }
    }

    private func snapshotIdentifier(from fileURL: URL) throws -> UUID {
        let identifier = fileURL.deletingPathExtension().lastPathComponent

        guard let snapshotIdentifier = UUID(uuidString: identifier) else {
            throw SnapshotStoreError.snapshotDecodeFailed(
                fileURL,
                CocoaError(.fileReadCorruptFile)
            )
        }

        return snapshotIdentifier
    }

    private func normalizedSnapshotName(_ name: String) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? nil : normalizedName
    }

    private func snapshotEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func snapshotDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
