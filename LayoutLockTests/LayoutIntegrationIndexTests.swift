import XCTest
@testable import LayoutLock

final class LayoutIntegrationIndexTests: XCTestCase {
    func testDevelopmentAndProductionUseSeparateApplicationSupportRoots() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let production = AppSupportDirectoryBootstrapper(
            applicationSupportBaseURL: temporaryDirectory.url,
            directoryName: "LayoutLock"
        )
        let development = AppSupportDirectoryBootstrapper(
            applicationSupportBaseURL: temporaryDirectory.url,
            directoryName: "LayoutLock Dev"
        )

        XCTAssertEqual(production.rootURL.lastPathComponent, "LayoutLock")
        XCTAssertEqual(development.rootURL.lastPathComponent, "LayoutLock Dev")
        XCTAssertNotEqual(production.snapshotsURL, development.snapshotsURL)
        XCTAssertNotEqual(production.logsURL, development.logsURL)
        XCTAssertNotEqual(production.integrationsURL, development.integrationsURL)
    }

    func testIntegrationDirectoryFailureDoesNotBlockCoreDirectoryPreparation() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let bootstrapper = AppSupportDirectoryBootstrapper(
            applicationSupportBaseURL: temporaryDirectory.url
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: bootstrapper.rootURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: bootstrapper.integrationsURL)

        try bootstrapper.prepare()

        XCTAssertTrue(fileManager.fileExists(atPath: bootstrapper.snapshotsURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: bootstrapper.logsURL.path))
        XCTAssertThrowsError(
            try LayoutIntegrationIndexWriter(bootstrapper: bootstrapper).write(summaries: [])
        )

        let storageProbeURL = bootstrapper.snapshotsURL.appendingPathComponent("storage-probe")
        try Data([0x1]).write(to: storageProbeURL)
        XCTAssertTrue(fileManager.fileExists(atPath: storageProbeURL.path))
    }

    func testWritesStableSchemaFieldsISO8601DatesAndSourceOrdering() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let indexURL = temporaryDirectory.url.appendingPathComponent("Integrations/layouts-v1.json")
        let first = SnapshotSummary(
            snapshot: makeSnapshot(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Newest",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                displays: [makeDisplayRecord(id: 1), makeDisplayRecord(id: 2)],
                windows: [
                    makeWindowRecord(bundleIdentifier: "com.example.one", displayID: 1),
                    makeWindowRecord(bundleIdentifier: "com.example.two", displayID: 2)
                ]
            )
        )
        let second = SnapshotSummary(
            snapshot: makeSnapshot(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Older",
                updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
            )
        )

        try LayoutIntegrationIndexWriter(indexURL: indexURL).write(summaries: [first, second])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let layouts = try XCTUnwrap(object["layouts"] as? [[String: Any]])
        XCTAssertEqual(layouts.map { $0["name"] as? String }, ["Newest", "Older"])
        XCTAssertEqual(layouts[0]["windowCount"] as? Int, 2)
        XCTAssertEqual(layouts[0]["appCount"] as? Int, 2)
        XCTAssertEqual(layouts[0]["displayCount"] as? Int, 2)
        XCTAssertEqual(layouts[0]["updatedAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(
            Set(layouts[0].keys),
            ["id", "name", "updatedAt", "windowCount", "appCount", "displayCount"]
        )
    }

    func testWritesEmptyIndexAndAtomicallyReplacesExistingFile() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let indexURL = temporaryDirectory.url.appendingPathComponent("Integrations/layouts-v1.json")
        let writer = LayoutIntegrationIndexWriter(indexURL: indexURL)

        try writer.write(summaries: [SnapshotSummary(snapshot: makeSnapshot(name: "Initial"))])
        try writer.write(summaries: [])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(
            LayoutIntegrationIndex.self,
            from: Data(contentsOf: indexURL)
        )
        XCTAssertEqual(index, LayoutIntegrationIndex(summaries: []))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: indexURL.deletingLastPathComponent().path),
            ["layouts-v1.json"]
        )
    }

    func testWriteFailureThrowsWithoutAffectingCallers() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let blockingFile = temporaryDirectory.url.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        let writer = LayoutIntegrationIndexWriter(
            indexURL: blockingFile.appendingPathComponent("layouts-v1.json")
        )

        XCTAssertThrowsError(try writer.write(summaries: []))
    }
}
