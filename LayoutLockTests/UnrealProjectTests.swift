import AppKit
import XCTest
@testable import LayoutLock

final class UnrealProjectTests: XCTestCase {
    private var directory: URL!
    private let resolver = UnrealProjectResolver()
    private let bundle = "com.epicgames.UnrealEditor"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testProcessArgumentsSelectOnlyDocumentedProjectLocations() {
        XCTAssertEqual(UnrealProjectResolver.projectPaths(arguments: ["UnrealEditor", "/Projects/A.uproject",
            "-log", "ignored.uproject", "-authToken", "ignored-token"]), ["/Projects/A.uproject"])
        XCTAssertEqual(UnrealProjectResolver.projectPaths(arguments: ["UnrealEditor", "-Project=/Projects/A.uproject"]),
            ["/Projects/A.uproject"])
        XCTAssertEqual(UnrealProjectResolver.projectPaths(arguments: ["UnrealEditor", "-project", "/Projects/A.uproject"]),
            ["/Projects/A.uproject"])
        XCTAssertEqual(UnrealProjectResolver.projectPaths(arguments: ["UnrealEditor", "-project", "-log"]), [])
        XCTAssertEqual(UnrealProjectResolver.projectPaths(arguments: ["UnrealEditor", "-log", "ignored.uproject"]), [])
        XCTAssertTrue(UnrealProjectResolver.isUnreal(bundleIdentifier: bundle))
        XCTAssertFalse(UnrealProjectResolver.isUnreal(bundleIdentifier: "com.epicgames.UnrealEditorServices"))
    }

    func testSameNamedProjectsKeepExactIdentityAndAmbiguousPathsAreRejected() throws {
        let first = try project("A")
        let second = try project("B")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(resolver.resolve(projectPaths: [first.path], currentDirectoryURL: nil), first)
        XCTAssertEqual(resolver.resolve(projectPaths: [second.path], currentDirectoryURL: nil), second)
        XCTAssertNil(resolver.resolve(projectPaths: [first.path, second.path], currentDirectoryURL: nil))
        XCTAssertEqual(resolver.resolve(projectPaths: [first.path, first.path], currentDirectoryURL: nil), first)
        XCTAssertEqual(resolver.resolve(projectPaths: ["A/SharedProject.uproject"], currentDirectoryURL: directory), first)
        XCTAssertNil(resolver.resolve(projectPaths: ["A/SharedProject.uproject"], currentDirectoryURL: nil))
    }

    func testInvalidOrUnrelatedFilesCannotSupplyProjectIdentity() throws {
        let file = try project("Invalid")
        try Data("{}".utf8).write(to: file)
        XCTAssertNil(resolver.projectURL(file))
        try Data("not JSON".utf8).write(to: file)
        XCTAssertNil(resolver.projectURL(file))
        XCTAssertNil(resolver.projectURL(directory.appendingPathComponent("Missing.uproject")))
        XCTAssertNil(resolver.projectURL(URL(string: "https://example.com/Project.uproject")!))
        XCTAssertNil(resolver.projectURL(directory))
    }

    func testOpeningUsesOneFreshInstanceWithExplicitProjectArgument() async throws {
        let file = try project("With Spaces")
        let application = directory.appendingPathComponent("UnrealEditor.app")
        for disposition: RestoreTargetOpenDisposition in [.applicationDefault, .newApplicationInstance] {
            var calls = 0
            let opener = NSWorkspaceRestoreTargetOpener(applicationURLProvider: { _ in application },
                workspaceOpener: { _, _, _ in XCTFail("Project identity needs an explicit argument"); return false },
                instanceWorkspaceOpener: { urls, app, configuration in
                    calls += 1
                    XCTAssertTrue(urls.isEmpty)
                    XCTAssertEqual(app, application)
                    XCTAssertEqual(configuration.arguments, [file.path])
                    XCTAssertTrue(configuration.createsNewApplicationInstance)
                    XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
                    XCTAssertFalse(configuration.activates)
                    return 900
                })
            let result = await opener.open(targets: [WindowOpenTarget(kind: .file, url: file)],
                bundleIdentifier: bundle, disposition: disposition)
            guard case .openedApplicationInstance(900) = result else { return XCTFail("Expected fresh process identity") }
            XCTAssertEqual(calls, 1)
        }
    }

    func testOpeningRejectsMultipleOrInvalidProjectsAndFailedLaunches() async throws {
        let first = try project("A")
        let second = try project("B")
        var calls = 0
        let opener = NSWorkspaceRestoreTargetOpener(applicationURLProvider: { _ in self.directory },
            instanceWorkspaceOpener: { _, _, _ in calls += 1; return nil })
        for targets in [[WindowOpenTarget(kind: .file, url: first), WindowOpenTarget(kind: .file, url: second)],
                        [WindowOpenTarget(kind: .folder, url: directory)]] {
            guard case .failed(.unsupportedTarget) = await opener.open(targets: targets,
                bundleIdentifier: bundle, disposition: .newApplicationInstance) else {
                return XCTFail("Unsupported targets must not start an Editor")
            }
        }
        XCTAssertEqual(calls, 0)
        guard case .failed(.openRequestFailed) = await opener.open(targets: [WindowOpenTarget(kind: .file, url: first)],
            bundleIdentifier: bundle, disposition: .newApplicationInstance) else { return XCTFail("Expected launch failure") }
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedReferencesToOneProjectLaunchExactlyOneEditor() async throws {
        let file = try project("Repeated")
        var calls = 0
        let opener = NSWorkspaceRestoreTargetOpener(applicationURLProvider: { _ in self.directory },
            instanceWorkspaceOpener: { urls, _, configuration in
                calls += 1
                XCTAssertTrue(urls.isEmpty)
                XCTAssertEqual(configuration.arguments, [file.path])
                return 900
            })
        let targets = [WindowOpenTarget(kind: .file, url: file),
                       WindowOpenTarget(kind: .file, url: file.deletingLastPathComponent()
                        .appendingPathComponent("../Repeated/SharedProject.uproject"))]

        let result = await opener.open(targets: targets, bundleIdentifier: bundle,
            disposition: .newApplicationInstance)

        guard case .openedApplicationInstance(900) = result else { return XCTFail("Expected one project launch") }
        XCTAssertEqual(calls, 1)
    }

    private func project(_ folder: String) throws -> URL {
        let location = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let file = location.appendingPathComponent("SharedProject.uproject")
        try Data("{\"FileVersion\":3,\"EngineAssociation\":\"5.8\"}".utf8).write(to: file)
        return file
    }
}
