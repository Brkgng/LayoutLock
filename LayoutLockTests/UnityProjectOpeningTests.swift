import AppKit
import XCTest
@testable import LayoutLock

final class UnityProjectOpeningTests: XCTestCase {
    private let unityBundleIdentifier = "com.unity3d.UnityEditor5.x"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnityProjectOpeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSceneAndProjectArePlannedAsOneApplicationDefaultRequest() throws {
        let project = try makeProject("Project")
        let scene = try makeAsset(in: project, named: "Scenes/Saved Scene.unity")
        let targets = [WindowOpenTarget(kind: .file, url: scene),
                       WindowOpenTarget(kind: .folder, url: project)]

        let requests = RestoreTargetOpenRequestPlanner().requests(
            targets: targets, bundleIdentifier: unityBundleIdentifier
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.targets.map(\.url), targets.map(\.url))
        XCTAssertEqual(requests.first?.disposition, .applicationDefault)
    }

    func testMissingProjectAndSceneLaunchOneExactEditorInstanceWithExplicitArguments() async throws {
        let project = try makeProject("Project With Spaces")
        let scene = try makeAsset(in: project, named: "Scenes/Saved Scene.unity")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .file, url: scene),
                      WindowOpenTarget(kind: .folder, url: project)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertOpenedInstance(result)
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.urls, [])
        XCTAssertEqual(request.applicationURL, application)
        XCTAssertTrue(request.configuration.createsNewApplicationInstance)
        XCTAssertFalse(request.configuration.activates)
        XCTAssertFalse(request.configuration.allowsRunningApplicationSubstitution)
        XCTAssertEqual(request.configuration.arguments, ["-projectPath", project.path, "-openfile", scene.path])
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testProjectWithoutSavedSceneLaunchesWithProjectArgumentOnly() async throws {
        let project = try makeProject("Untitled Project")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .folder, url: project)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertOpenedInstance(result)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.urls, [])
        XCTAssertEqual(recorder.requests.first?.configuration.arguments, ["-projectPath", project.path])
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testSavedSceneAloneDerivesItsProjectForExistingSnapshots() async throws {
        let project = try makeProject("Project")
        let scene = try makeAsset(in: project, named: "Scenes/Saved.unity")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .file, url: scene)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertOpenedInstance(result)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.configuration.arguments,
                       ["-projectPath", project.path, "-openfile", scene.path])
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testRunningExactProjectDoesNotReceiveSceneOrNativeOpenRequest() async throws {
        let project = try makeProject("Already Running")
        let scene = try makeAsset(in: project, named: "Scenes/Saved.unity")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, runningProjects: [project], recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .folder, url: project),
                      WindowOpenTarget(kind: .file, url: scene)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertFailure(result, reason: .openingNotConfirmed)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testSceneFromDifferentProjectIsRejectedBeforeNativeOpening() async throws {
        let first = try makeProject("First")
        let second = try makeProject("Second")
        let scene = try makeAsset(in: second, named: "Scenes/Saved.unity")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .folder, url: first),
                      WindowOpenTarget(kind: .file, url: scene)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertFailure(result, reason: .unsupportedTarget)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testUnsupportedAssetDoesNotFallBackToDocumentDelivery() async throws {
        let project = try makeProject("Project")
        let asset = try makeAsset(in: project, named: "Prefabs/Player.prefab")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .file, url: asset)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertFailure(result, reason: .unsupportedTarget)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    func testMissingRequiredEditorVersionDoesNotUseAvailableDifferentVersion() async throws {
        let project = try makeProject("New Version Project", version: "9999.999.999f1")
        let application = try makeEditor()
        let recorder = OpeningRecorder()
        let opener = makeOpener(application: application, recorder: recorder)

        let result = await opener.open(
            targets: [WindowOpenTarget(kind: .folder, url: project)],
            bundleIdentifier: unityBundleIdentifier, disposition: .applicationDefault
        )

        assertFailure(result, reason: .applicationUnavailable)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(recorder.workspaceRequestCount, 0)
    }

    private func makeOpener(
        application: URL,
        runningProjects: Set<URL> = [],
        recorder: OpeningRecorder
    ) -> NSWorkspaceRestoreTargetOpener {
        NSWorkspaceRestoreTargetOpener(
            applicationURLProvider: { _ in application },
            commandRunner: { _, _ in XCTFail("Unity must use its instance opener"); return false },
            workspaceOpener: { _, _, _ in
                recorder.workspaceRequestCount += 1
                return true
            },
            instanceWorkspaceOpener: { urls, applicationURL, configuration in
                recorder.requests.append(.init(urls: urls, applicationURL: applicationURL,
                                               configuration: configuration))
                return 12345
            },
            runningUnityProjectsProvider: { runningProjects }
        )
    }

    private func assertOpenedInstance(
        _ result: RestoreTargetOpenResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .openedApplicationInstance(let pid) = result else {
            return XCTFail("Expected a new Editor instance", file: file, line: line)
        }
        XCTAssertEqual(pid, 12345, file: file, line: line)
    }

    private func assertFailure(
        _ result: RestoreTargetOpenResult, reason: RestoreTargetIssueReason,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failed(let actualReason) = result else {
            return XCTFail("Expected opening to be rejected", file: file, line: line)
        }
        XCTAssertEqual(actualReason, reason, file: file, line: line)
    }

    private func makeProject(_ name: String, version: String = "6000.6.7f1") throws -> URL {
        let project = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("ProjectSettings"),
                                                withIntermediateDirectories: true)
        try "m_EditorVersion: \(version)\n".write(
            to: project.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true, encoding: .utf8
        )
        return project
    }

    private func makeAsset(in project: URL, named name: String) throws -> URL {
        let asset = project.appendingPathComponent("Assets/\(name)")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: asset)
        return asset
    }

    private func makeEditor(version: String = "6000.6.7f1") throws -> URL {
        let application = directory.appendingPathComponent("Hub/Editor/\(version)/Unity.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": unityBundleIdentifier, "CFBundleVersion": version,
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Unity"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Unity")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return application
    }
}

private final class OpeningRecorder {
    struct Request {
        let urls: [URL]
        let applicationURL: URL
        let configuration: NSWorkspace.OpenConfiguration
    }

    var requests: [Request] = []
    var workspaceRequestCount = 0
}
