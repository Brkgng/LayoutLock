import XCTest
@testable import LayoutLock

@MainActor
final class SnapshotPinningTests: XCTestCase {
    func testExistingLayoutWithoutPinFieldLoadsAsUnpinned() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = makeSnapshot(hotkey: makeHotkey())
        try store.save(snapshot)
        let fileURL = directory.url.appendingPathComponent("\(snapshot.id.uuidString).json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        object.removeValue(forKey: "isPinned")
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let loaded = try store.loadSnapshot(id: snapshot.id)

        XCTAssertFalse(loaded.isPinned)
        XCTAssertEqual(loaded.hotkey, snapshot.hotkey)
        XCTAssertEqual(loaded.windows.map(\.id), snapshot.windows.map(\.id))
        XCTAssertEqual(try store.listSummaries().map(\.id), [snapshot.id])
    }

    func testExistingLayoutWithoutAppInstanceSettingPreservesCapturedProcesses() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = makeSnapshot(windows: [
            makeWindowRecord(pidAtCapture: 42),
            makeWindowRecord(pidAtCapture: 43)
        ])
        try store.save(snapshot)
        let fileURL = directory.url.appendingPathComponent("\(snapshot.id.uuidString).json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertNil(object["restoreSeparateAppInstances"])
        XCTAssertEqual(try store.loadSnapshot(id: snapshot.id).windows.map(\.pidAtCapture), [42, 43])
    }

    func testObsoleteAppInstanceSettingDoesNotChangeCapturedProcesses() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = makeSnapshot(windows: [
            makeWindowRecord(pidAtCapture: 42),
            makeWindowRecord(pidAtCapture: 43)
        ])
        try store.save(snapshot)
        let fileURL = directory.url.appendingPathComponent("\(snapshot.id.uuidString).json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        object["restoreSeparateAppInstances"] = false
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        XCTAssertEqual(try store.loadSnapshot(id: snapshot.id).windows.map(\.pidAtCapture), [42, 43])
    }

    func testPinningPrioritizesLayoutsAndUnpinningRestoresDateOrder() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let oldest = makeSnapshot(name: "Oldest", updatedAt: Date(timeIntervalSince1970: 100))
        let middle = makeSnapshot(name: "Middle", updatedAt: Date(timeIntervalSince1970: 200))
        let newest = makeSnapshot(name: "Newest", updatedAt: Date(timeIntervalSince1970: 300))
        for snapshot in [oldest, middle, newest] {
            try store.save(snapshot)
        }

        try store.setPinned(true, for: oldest.id)
        try store.setPinned(true, for: middle.id)

        let pinnedSummaries = try store.listSummaries()
        XCTAssertEqual(pinnedSummaries.map(\.id), [middle.id, oldest.id, newest.id])
        XCTAssertEqual(pinnedSummaries.map(\.isPinned), [true, true, false])
        let pinned = try store.loadSnapshot(id: oldest.id)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.createdAt, oldest.createdAt)
        XCTAssertEqual(pinned.updatedAt, oldest.updatedAt)
        XCTAssertEqual(pinned.windows.map(\.id), oldest.windows.map(\.id))

        try store.setPinned(false, for: oldest.id)
        try store.setPinned(false, for: middle.id)

        XCTAssertEqual(try store.listSummaries().map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertFalse(try store.loadSnapshot(id: oldest.id).isPinned)
        XCTAssertEqual(try store.loadSnapshot(id: oldest.id).updatedAt, oldest.updatedAt)
    }

    func testLayoutEditsPreservePin() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let firstWindow = makeWindowRecord(zOrderHint: 1)
        let secondWindow = makeWindowRecord(zOrderHint: 2)
        let browserWindow = makeWindowRecord(bundleIdentifier: "com.example.browser", zOrderHint: 3)
        let snapshot = makeSnapshot(windows: [firstWindow, secondWindow, browserWindow], isPinned: true)
        try store.save(snapshot)

        try store.renameSnapshot(id: snapshot.id, to: "Work")
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)

        try store.setHotkey(for: snapshot.id, hotkey: makeHotkey())
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)

        let target = WindowOpenTarget(kind: .webURL, url: try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertTrue(try store.setOpeningConfiguration(
            snapshotID: snapshot.id,
            windowID: firstWindow.id,
            manualTargets: [target]
        ))
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)

        XCTAssertTrue(try store.reorderDisplayWindows(
            snapshotID: snapshot.id,
            displayID: 1,
            orderedWindowIDs: [browserWindow.id, secondWindow.id, firstWindow.id]
        ))
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)

        XCTAssertTrue(try store.removeWindow(windowID: secondWindow.id, from: snapshot.id))
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)

        XCTAssertEqual(try store.removeApp(bundleIdentifier: firstWindow.bundleIdentifier, from: snapshot.id), 1)
        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)
    }

    func testControllerTogglesPinAndPublishesUpdatedSummaries() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = makeSnapshot()
        try store.save(snapshot)
        let controller = SnapshotMenuController(snapshotStore: store)
        var publishedSummaries: [SnapshotSummary] = []
        controller.setSnapshotSummariesDidChange { summaries in
            publishedSummaries = summaries
            return nil
        }

        controller.togglePin(for: snapshot.id)

        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)
        XCTAssertEqual(controller.snapshotSummaries.first?.isPinned, true)
        XCTAssertEqual(publishedSummaries.first?.isPinned, true)
        XCTAssertEqual(controller.status?.message, "Pinned \"Coding\".")

        controller.togglePin(for: snapshot.id)

        XCTAssertFalse(try store.loadSnapshot(id: snapshot.id).isPinned)
        XCTAssertEqual(controller.snapshotSummaries.first?.isPinned, false)
        XCTAssertEqual(publishedSummaries.first?.isPinned, false)
        XCTAssertEqual(controller.status?.message, "Unpinned \"Coding\".")
    }

    func testControllerPreservesSummaryRefreshFailureStatus() throws {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = makeSnapshot()
        try store.save(snapshot)
        let controller = SnapshotMenuController(snapshotStore: store)
        let refreshError = NSError(
            domain: "SnapshotPinningTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Summary refresh failed."]
        )
        controller.setSnapshotSummariesDidChange { _ in refreshError }

        controller.togglePin(for: snapshot.id)

        XCTAssertTrue(try store.loadSnapshot(id: snapshot.id).isPinned)
        XCTAssertEqual(controller.status?.message, refreshError.localizedDescription)
        XCTAssertEqual(controller.status?.isError, true)
    }
}
