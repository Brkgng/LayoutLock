import XCTest
@testable import LayoutLock

final class UnityProjectResolverTests: XCTestCase {
    private var directory: URL!
    private let resolver = UnityProjectResolver()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnityProjectResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSavedSceneResolvesItsValidatedProject() throws {
        let project = try makeProject("My project")
        let scene = project.appendingPathComponent("Assets/Scenes/Saved scene.unity")

        XCTAssertEqual(resolver.projectURL(containing: scene), project)
        XCTAssertEqual(resolver.projectURL(containing: project), project)
        XCTAssertNil(resolver.projectURL(containing: project.appendingPathComponent("Library/scene.unity")))
        XCTAssertNil(resolver.projectURL(containing: URL(string: "https://example.com/Assets/scene.unity")!))
    }

    func testScenePathWithoutProjectMetadataDoesNotSupplyIdentity() throws {
        let scene = directory.appendingPathComponent("Unknown/Assets/Scenes/Scene.unity")
        XCTAssertNil(resolver.projectURL(containing: scene))
    }

    func testUntitledProjectsUseOnlyWhitelistedProjectArguments() throws {
        let project = try makeProject("Untitled project")
        let arguments = [
            "/Applications/Unity.app/Contents/MacOS/Unity",
            "-createproject", project.path,
            "-accessToken", "ignored-token",
            "-logFile", "/tmp/unrelated.log"
        ]

        XCTAssertEqual(UnityProjectResolver.projectPaths(arguments: arguments), [project.path])
        XCTAssertEqual(
            resolver.resolve(projectPaths: UnityProjectResolver.projectPaths(arguments: arguments),
                             currentDirectoryURL: nil),
            project
        )
        XCTAssertEqual(
            UnityProjectResolver.projectPaths(arguments: ["-projectPath", project.path]),
            [project.path]
        )
        XCTAssertEqual(UnityProjectResolver.projectPaths(arguments: ["-projectPath", "-batchmode"]), [])
        XCTAssertEqual(UnityProjectResolver.projectPaths(arguments: ["-createProject"]), [])
    }

    func testCurrentDirectoryMustBeAProjectAndRelativeArgumentsNeedCurrentDirectory() throws {
        let project = try makeProject("Project")
        XCTAssertEqual(resolver.resolve(projectPaths: [], currentDirectoryURL: project), project)
        XCTAssertNil(resolver.resolve(projectPaths: [], currentDirectoryURL: directory))
        XCTAssertEqual(
            resolver.resolve(projectPaths: ["Project"], currentDirectoryURL: directory),
            project
        )
        XCTAssertNil(resolver.resolve(projectPaths: ["Project"], currentDirectoryURL: nil))
    }

    func testConflictingProjectArgumentsNeverSelectAnArbitraryProject() throws {
        let first = try makeProject("First")
        let second = try makeProject("Second")
        XCTAssertNil(resolver.resolve(projectPaths: [first.path, second.path], currentDirectoryURL: first))
        XCTAssertEqual(resolver.resolve(projectPaths: [first.path, first.path], currentDirectoryURL: nil), first)
    }

    func testProjectRequiresAssetsAndSafeEditorVersion() throws {
        let project = try makeProject("Project")
        XCTAssertEqual(resolver.editorVersion(projectURL: project), "6000.6.7f1")
        try "m_EditorVersion: ../../Other.app\n".write(
            to: project.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertNil(resolver.editorVersion(projectURL: project))
        let noAssets = try makeProject("No Assets")
        try FileManager.default.removeItem(at: noAssets.appendingPathComponent("Assets"))
        XCTAssertNil(resolver.editorVersion(projectURL: noAssets))
    }

    func testEditorSelectionRequiresExactProjectVersionAndUnityBundle() throws {
        let project = try makeProject("Project")
        let hub = directory.appendingPathComponent("Hub/Editor", isDirectory: true)
        let wrongVersion = try makeEditor(in: hub, version: "6000.5.0f1")
        let matching = try makeEditor(in: hub, version: "6000.6.7f1")

        XCTAssertEqual(resolver.editorURL(projectURL: project, preferredApplicationURL: wrongVersion), matching)
        XCTAssertEqual(resolver.editorURL(projectURL: project, preferredApplicationURL: matching), matching)
        XCTAssertTrue(UnityProjectResolver.isUnity(bundleIdentifier: "com.unity3d.UnityEditor5.x"))
        XCTAssertFalse(UnityProjectResolver.isUnity(bundleIdentifier: "com.unity3d.unityhub"))
    }

    private func makeProject(_ name: String) throws -> URL {
        let project = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Assets/Scenes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("ProjectSettings", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "m_EditorVersion: 6000.6.7f1\nm_EditorVersionWithRevision: 6000.6.7f1 (revision)\n".write(
            to: project.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true, encoding: .utf8
        )
        return project
    }

    private func makeEditor(in hub: URL, version: String) throws -> URL {
        let application = hub.appendingPathComponent("\(version)/Unity.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.unity3d.UnityEditor5.x",
            "CFBundleVersion": version,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Unity"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Unity")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return application
    }
}
