import ApplicationServices
import AppKit
import CoreGraphics
import XCTest
@testable import LayoutLock

final class WindowDiscoveryEngineTests: XCTestCase {
    func testThrowsWhenAccessibilityIsDenied() {
        let engine = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { false },
            runningApplicationsProvider: { [] }
        )

        XCTAssertThrowsError(try engine.discoverRunningWindowsWithDiagnostics()) { error in
            guard case WindowDiscoveryError.accessibilityPermissionDenied = error else {
                return XCTFail("Expected accessibility error, got \(error).")
            }
        }
    }

    func testFiltersCandidateApplicationsBeforeReadingCGMetadata() throws {
        var requestedProcessIdentifiers: Set<pid_t> = []
        let engine = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true },
            currentProcessIdentifier: 500,
            runningApplicationsProvider: {
                [
                    RunningApplicationSnapshot(
                        bundleIdentifier: nil,
                        processIdentifier: 100,
                        localizedName: nil
                    ),
                    RunningApplicationSnapshot(
                        bundleIdentifier: "com.example.terminated",
                        processIdentifier: 101,
                        localizedName: "Terminated",
                        isTerminated: true
                    ),
                    RunningApplicationSnapshot(
                        bundleIdentifier: "com.example.prohibited",
                        processIdentifier: 102,
                        localizedName: "Prohibited",
                        activationPolicy: .prohibited
                    ),
                    RunningApplicationSnapshot(
                        bundleIdentifier: "com.example.current",
                        processIdentifier: 500,
                        localizedName: "LayoutLock"
                    ),
                    RunningApplicationSnapshot(
                        bundleIdentifier: "com.example.valid",
                        processIdentifier: 103,
                        localizedName: "Valid"
                    )
                ]
            },
            appElementProvider: { _ in AXUIElementCreateSystemWide() },
            cgWindowMetadataProvider: {
                requestedProcessIdentifiers = $0
                return [:]
            }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(requestedProcessIdentifiers, [103])
    }

    func testContextualDiscoveryUsesProvidedRunningApplications() throws {
        var didReadLiveRunningApplications = false
        var requestedProcessIdentifiers: Set<pid_t> = []
        let engine = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true },
            currentProcessIdentifier: 500,
            runningApplicationsProvider: {
                didReadLiveRunningApplications = true
                return []
            },
            appElementProvider: { _ in AXUIElementCreateSystemWide() },
            cgWindowMetadataProvider: {
                requestedProcessIdentifiers = $0
                return [:]
            }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics(
            runningApplications: [
                RunningApplicationSnapshot(
                    bundleIdentifier: "com.example.context",
                    processIdentifier: 104,
                    localizedName: "Context"
                )
            ]
        )

        XCTAssertFalse(didReadLiveRunningApplications)
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(requestedProcessIdentifiers, [104])
    }

    func testDiscoversWindowWithMatchedCGMetadata() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.set(NSNumber(value: false), for: appElement, attribute: kAXHiddenAttribute)
        fixture.setWindow(
            windowElement,
            title: "Document",
            role: kAXWindowRole as String,
            subrole: "AXStandardWindow",
            frame: frame,
            isHidden: false
        )
        let metadata = CGWindowMetadata(
            windowID: 900,
            processIdentifier: 101,
            ownerName: "Editor",
            layer: 0,
            bounds: frame.offsetBy(dx: 2, dy: 1),
            title: "Document",
            isOnScreen: true,
            zOrderHint: 4
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: [metadata]]
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()
        let application = try XCTUnwrap(result.applications.first)
        let window = try XCTUnwrap(application.windows.first)

        XCTAssertEqual(application.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(application.pid, 101)
        XCTAssertEqual(application.localizedName, "Editor")
        XCTAssertEqual(window.title, "Document")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.cgWindowID, 900)
        XCTAssertEqual(window.ownerName, "Editor")
        XCTAssertEqual(window.zOrderHint, 4)
        XCTAssertEqual(window.isOnScreen, true)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testPrefersOnscreenCGMatchAndUsesItForVisibility() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: "Terminal",
            role: kAXWindowRole as String,
            frame: frame,
            isHidden: true
        )
        let metadata = [
            CGWindowMetadata(
                windowID: 1,
                processIdentifier: 101,
                ownerName: "Terminal",
                layer: 0,
                bounds: frame,
                title: "Terminal",
                isOnScreen: false,
                zOrderHint: nil
            ),
            CGWindowMetadata(
                windowID: 2,
                processIdentifier: 101,
                ownerName: "Terminal",
                layer: 0,
                bounds: frame,
                title: "Terminal",
                isOnScreen: true,
                zOrderHint: 3
            )
        ]
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: metadata]
        )

        let window = try XCTUnwrap(
            engine.discoverRunningWindowsWithDiagnostics()
                .applications.first?
                .windows.first
        )

        XCTAssertEqual(window.cgWindowID, 2)
        XCTAssertEqual(window.zOrderHint, 3)
        XCTAssertTrue(window.isVisible)
    }

    func testDiscoversExistingLocalDocumentURL() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let documentURL = temporaryDirectory.url.appendingPathComponent("Document.txt")
        try Data().write(to: documentURL)
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: "Document",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.set(
            documentURL.absoluteString as CFString,
            for: windowElement,
            attribute: kAXDocumentAttribute
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(
            result.applications.first?.windows.first?.documentURL,
            documentURL.standardizedFileURL
        )
    }

    func testDiscoversWebDocumentURLFromNestedWebArea() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let groupElement = AXUIElementCreateApplication(202)
        let webAreaElement = AXUIElementCreateApplication(203)
        let webURL = try XCTUnwrap(
            NSURL(string: "https://www.youtube.com/watch?v=layoutlock")
        )
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: "YouTube",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.set(
            [groupElement] as CFArray,
            for: windowElement,
            attribute: kAXChildrenAttribute
        )
        fixture.set(
            kAXGroupRole as CFString,
            for: groupElement,
            attribute: kAXRoleAttribute
        )
        fixture.set(
            [webAreaElement] as CFArray,
            for: groupElement,
            attribute: kAXChildrenAttribute
        )
        fixture.set(
            "AXWebArea" as CFString,
            for: webAreaElement,
            attribute: kAXRoleAttribute
        )
        fixture.set(
            webURL,
            for: webAreaElement,
            attribute: kAXURLAttribute
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(
            result.applications.first?.windows.first?.documentURL,
            URL(string: "https://www.youtube.com/watch?v=layoutlock")
        )
    }

    func testDiscoversWebAreaAfterLargeBrowserChromeTree() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let webAreaElement = AXUIElementCreateApplication(202)
        let browserChromeElements = (0..<200).map {
            AXUIElementCreateApplication(pid_t(1_000 + $0))
        }
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: "YouTube",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.set(
            (browserChromeElements + [webAreaElement]) as CFArray,
            for: windowElement,
            attribute: kAXChildrenAttribute
        )
        fixture.set(
            "AXWebArea" as CFString,
            for: webAreaElement,
            attribute: kAXRoleAttribute
        )
        fixture.set(
            "https://www.youtube.com/watch?v=layoutlock" as CFString,
            for: webAreaElement,
            attribute: kAXURLAttribute
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(
            result.applications.first?.windows.first?.documentURL,
            URL(string: "https://www.youtube.com/watch?v=layoutlock")
        )
    }

    func testDiscoversInactiveTabDocumentMetadata() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let selectedURL = temporaryDirectory.url
            .appendingPathComponent("Selected", isDirectory: true)
        let inactiveURL = temporaryDirectory.url
            .appendingPathComponent("Inactive", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: inactiveURL, withIntermediateDirectories: false)

        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let tabGroupElement = AXUIElementCreateApplication(202)
        let selectedTabElement = AXUIElementCreateApplication(203)
        let inactiveTabElement = AXUIElementCreateApplication(204)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: "Selected",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.set(
            selectedURL.path as CFString,
            for: windowElement,
            attribute: kAXDocumentAttribute
        )
        fixture.set(
            [tabGroupElement] as CFArray,
            for: windowElement,
            attribute: kAXChildrenAttribute
        )
        fixture.set(
            "AXTabGroup" as CFString,
            for: tabGroupElement,
            attribute: kAXRoleAttribute
        )
        fixture.set(
            [selectedTabElement, inactiveTabElement] as CFArray,
            for: tabGroupElement,
            attribute: kAXChildrenAttribute
        )
        fixture.set(
            "~/Repo/Selected" as CFString,
            for: selectedTabElement,
            attribute: kAXTitleAttribute
        )
        fixture.set(
            "~/Repo/Inactive" as CFString,
            for: inactiveTabElement,
            attribute: kAXTitleAttribute
        )
        fixture.set(
            inactiveURL.path as CFString,
            for: inactiveTabElement,
            attribute: kAXDocumentAttribute
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let window = try XCTUnwrap(
            engine.discoverRunningWindowsWithDiagnostics()
                .applications.first?
                .windows.first
        )

        XCTAssertEqual(window.documentURL, selectedURL.standardizedFileURL)
        XCTAssertEqual(window.documentURLs, [
            selectedURL.standardizedFileURL,
            inactiveURL.standardizedFileURL
        ])
        XCTAssertEqual(window.documentTitles, [
            "~/Repo/Selected",
            "~/Repo/Inactive"
        ])
    }

    func testDocumentURLResolverAcceptsLocalAndWebTargetsAndRejectsInvalidValues() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let folderURL = temporaryDirectory.url.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        let resolver = WindowDocumentURLResolver()

        XCTAssertEqual(resolver.resolve(folderURL.path), folderURL.standardizedFileURL)
        XCTAssertEqual(
            resolver.resolve("https://example.com/document"),
            URL(string: "https://example.com/document")
        )
        XCTAssertNil(resolver.resolve("ftp://example.com/document"))
        XCTAssertNil(resolver.resolve(temporaryDirectory.url.appendingPathComponent("Missing").path))
        XCTAssertNil(resolver.resolve("relative/path"))
        XCTAssertEqual(
            resolver.resolveLocalPathReference(in: "user@machine:\(folderURL.path)"),
            folderURL.standardizedFileURL
        )
        XCTAssertEqual(
            resolver.resolveLocalPathReference(in: "user@machine:~/"),
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
        XCTAssertNil(resolver.resolveLocalPathReference(in: "hx NOTES.md"))
    }

    func testApplicationDocumentURLResolverFindsVSCodeWorkspaceFromWindowTitle() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let workspaceURL = temporaryDirectory.url.appendingPathComponent(
            "ScrollSnap",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false
        )
        let storageURL = temporaryDirectory.url.appendingPathComponent(
            "workspaceStorage",
            isDirectory: true
        )
        try writeVSCodeWorkspaceMetadata(
            folderURL: workspaceURL,
            identifier: "scrollsnap",
            storageURL: storageURL
        )
        let resolver = ApplicationWindowDocumentURLResolver(
            workspaceStorageDirectoryProvider: { _ in storageURL }
        )

        XCTAssertEqual(
            resolver.resolve(
                bundleIdentifier: "com.microsoft.VSCode",
                windowTitle: ".gitignore — ScrollSnap — work"
            ),
            workspaceURL.standardizedFileURL
        )
    }

    func testApplicationDocumentURLResolverFindsAntigravityWorkspaceFromWindowTitle() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let workspaceURL = temporaryDirectory.url.appendingPathComponent(
            "ZapPDF",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false
        )
        let storageURL = temporaryDirectory.url.appendingPathComponent(
            "workspaceStorage",
            isDirectory: true
        )
        try writeVSCodeWorkspaceMetadata(
            folderURL: workspaceURL,
            identifier: "zappdf",
            storageURL: storageURL
        )
        let resolver = ApplicationWindowDocumentURLResolver(
            workspaceStorageDirectoryProvider: { _ in storageURL }
        )

        XCTAssertEqual(
            ApplicationWindowDocumentURLResolver.applicationSupportName(
                bundleIdentifier: "com.google.antigravity-ide"
            ),
            "Antigravity IDE"
        )
        XCTAssertEqual(
            resolver.resolve(
                bundleIdentifier: "com.google.antigravity-ide",
                windowTitle: "Package.swift — ZapPDF — Antigravity IDE"
            ),
            workspaceURL.standardizedFileURL
        )
    }

    func testApplicationDocumentURLResolverIndexesWorkspaceMetadataOncePerDiscoveryCycle() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let workspaceURL = temporaryDirectory.url.appendingPathComponent(
            "ScrollSnap",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false
        )
        let storageURL = temporaryDirectory.url.appendingPathComponent(
            "workspaceStorage",
            isDirectory: true
        )
        try writeVSCodeWorkspaceMetadata(
            folderURL: workspaceURL,
            identifier: "scrollsnap",
            storageURL: storageURL
        )
        var storageLookupCount = 0
        let resolver = ApplicationWindowDocumentURLResolver(
            workspaceStorageDirectoryProvider: { _ in
                storageLookupCount += 1
                return storageURL
            }
        ).preparing(bundleIdentifiers: ["com.microsoft.VSCode"])

        XCTAssertEqual(
            resolver.resolve(
                bundleIdentifier: "com.microsoft.VSCode",
                windowTitle: ".gitignore — ScrollSnap — work"
            ),
            workspaceURL.standardizedFileURL
        )
        XCTAssertEqual(
            resolver.resolve(
                bundleIdentifier: "com.microsoft.VSCode",
                windowTitle: "README.md — ScrollSnap — work"
            ),
            workspaceURL.standardizedFileURL
        )
        XCTAssertEqual(storageLookupCount, 1)
    }

    func testApplicationDocumentURLResolverDoesNotGuessBetweenSameNamedWorkspaces() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let storageURL = temporaryDirectory.url.appendingPathComponent(
            "workspaceStorage",
            isDirectory: true
        )
        for parentName in ["One", "Two"] {
            let parentURL = temporaryDirectory.url.appendingPathComponent(
                parentName,
                isDirectory: true
            )
            let workspaceURL = parentURL.appendingPathComponent(
                "Project",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true
            )
            try writeVSCodeWorkspaceMetadata(
                folderURL: workspaceURL,
                identifier: parentName,
                storageURL: storageURL
            )
        }
        let resolver = ApplicationWindowDocumentURLResolver(
            workspaceStorageDirectoryProvider: { _ in storageURL }
        )

        XCTAssertNil(
            resolver.resolve(
                bundleIdentifier: "com.microsoft.VSCode",
                windowTitle: "File.swift — Project — Visual Studio Code"
            )
        )
    }

    func testDiscoveryUsesApplicationWorkspaceInsteadOfEditorDocument() throws {
        let temporaryDirectory = try TestTemporaryDirectory()
        let workspaceURL = temporaryDirectory.url.appendingPathComponent(
            "ScrollSnap",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false
        )
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            windowElement,
            title: ".gitignore — ScrollSnap — work",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        let resolver = ApplicationWindowDocumentURLResolver(
            workspaceStorageDirectoryProvider: { _ in temporaryDirectory.url }
        )
        try writeVSCodeWorkspaceMetadata(
            folderURL: workspaceURL,
            identifier: "scrollsnap",
            storageURL: temporaryDirectory.url
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            bundleIdentifier: "com.microsoft.VSCode",
            applicationDocumentURLResolver: resolver
        )

        let window = try XCTUnwrap(
            engine.discoverRunningWindowsWithDiagnostics()
                .applications.first?
                .windows.first
        )

        XCTAssertEqual(window.documentURLs, [workspaceURL.standardizedFileURL])
    }

    func testReportsDiagnosticForInvalidWindowFrame() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.set(makeAXValue(CGPoint(x: 0, y: 0)) as CFTypeRef, for: windowElement, attribute: kAXPositionAttribute)
        fixture.set("Broken" as CFString, for: windowElement, attribute: kAXTitleAttribute)
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(
            result.diagnostics,
            [
                WindowDiscoveryDiagnostic(
                    bundleIdentifier: "com.example.editor",
                    processIdentifier: 101,
                    reason: WindowDiscoveryDiagnosticReason.missingOrInvalidFrame
                )
            ]
        )
    }

    func testRejectsTransientRolesAndSubroles() throws {
        let appElement = AXUIElementCreateApplication(101)
        let sheetElement = AXUIElementCreateApplication(201)
        let floatingElement = AXUIElementCreateApplication(202)
        let fixture = AXAttributeFixture()
        fixture.set([sheetElement, floatingElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            sheetElement,
            title: "Sheet",
            role: kAXSheetRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.setWindow(
            floatingElement,
            title: "Floating",
            role: kAXWindowRole as String,
            subrole: kAXFloatingWindowSubrole as String,
            frame: CGRect(x: 50, y: 60, width: 400, height: 300)
        )
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(
            result.diagnostics.map(\.reason),
            [
                WindowDiscoveryDiagnosticReason.transientRole,
                WindowDiscoveryDiagnosticReason.transientSubrole
            ]
        )
    }

    func testRejectsNonzeroCGWindowLayerAndDerivesVisibilityFromCGMetadata() throws {
        let appElement = AXUIElementCreateApplication(101)
        let layeredElement = AXUIElementCreateApplication(201)
        let offscreenElement = AXUIElementCreateApplication(202)
        let fixture = AXAttributeFixture()
        fixture.set([layeredElement, offscreenElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(
            layeredElement,
            title: "Utility",
            role: kAXWindowRole as String,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300)
        )
        fixture.setWindow(
            offscreenElement,
            title: "Document",
            role: kAXWindowRole as String,
            frame: CGRect(x: 80, y: 90, width: 400, height: 300)
        )
        let metadata: [pid_t: [CGWindowMetadata]] = [
            101: [
                CGWindowMetadata(
                    windowID: 1,
                    processIdentifier: 101,
                    ownerName: "Editor",
                    layer: 1,
                    bounds: CGRect(x: 20, y: 30, width: 400, height: 300),
                    title: "Utility",
                    isOnScreen: true,
                    zOrderHint: 1
                ),
                CGWindowMetadata(
                    windowID: 2,
                    processIdentifier: 101,
                    ownerName: "Editor",
                    layer: 0,
                    bounds: CGRect(x: 80, y: 90, width: 400, height: 300),
                    title: "Document",
                    isOnScreen: false,
                    zOrderHint: 2
                )
            ]
        ]
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: metadata
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()
        let window = try XCTUnwrap(result.applications.first?.windows.first)

        XCTAssertEqual(result.diagnostics.map(\.reason), [WindowDiscoveryDiagnosticReason.nonzeroCGWindowLayer])
        XCTAssertEqual(window.title, "Document")
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.isOnScreen, false)
    }

    private func makeEngine(
        appElement: AXUIElement,
        attributeReader: AXAttributeReader,
        metadata: [pid_t: [CGWindowMetadata]] = [:],
        bundleIdentifier: String = "com.example.editor",
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver =
            ApplicationWindowDocumentURLResolver()
    ) -> WindowDiscoveryEngine {
        WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true },
            attributeReader: attributeReader,
            applicationDocumentURLResolver: applicationDocumentURLResolver,
            currentProcessIdentifier: 500,
            runningApplicationsProvider: {
                [
                    RunningApplicationSnapshot(
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: 101,
                        localizedName: "Editor"
                    )
                ]
            },
            appElementProvider: { _ in appElement },
            cgWindowMetadataProvider: { _ in metadata }
        )
    }

    private func writeVSCodeWorkspaceMetadata(
        folderURL: URL,
        identifier: String,
        storageURL: URL
    ) throws {
        let entryURL = storageURL.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: entryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["folder": folderURL.absoluteString]
        )
        try data.write(to: entryURL.appendingPathComponent("workspace.json"))
    }
}

final class CGWindowMetadataReaderTests: XCTestCase {
    func testUsesOnscreenOrderingForVisibleWindowZOrderHints() throws {
        let xcodeWindow = makeRawWindow(
            id: 100,
            pid: 10,
            ownerName: "Xcode",
            title: "Project",
            isOnScreen: true
        )
        let ghosttyWindow = makeRawWindow(
            id: 200,
            pid: 20,
            ownerName: "Ghostty",
            title: "Terminal",
            isOnScreen: true
        )
        let reader = CGWindowMetadataReader { option in
            if option == .optionOnScreenOnly {
                return [xcodeWindow, ghosttyWindow]
            }

            return [ghosttyWindow, xcodeWindow]
        }

        let metadata = reader.readWindowMetadata(processIdentifiers: [10, 20])
        let xcodeMetadata = try XCTUnwrap(metadata[10]?.first)
        let ghosttyMetadata = try XCTUnwrap(metadata[20]?.first)

        XCTAssertEqual(xcodeMetadata.zOrderHint, 0)
        XCTAssertEqual(ghosttyMetadata.zOrderHint, 1)
    }

    func testOffscreenMetadataIgnoresStaleOnscreenOrderingEntry() throws {
        let offscreenWindow = makeRawWindow(
            id: 100,
            pid: 10,
            ownerName: "Xcode",
            title: "Hidden Project",
            isOnScreen: false
        )
        let reader = CGWindowMetadataReader { _ in
            [offscreenWindow]
        }

        let window = try XCTUnwrap(
            reader.readWindowMetadata(processIdentifiers: [10])[10]?.first
        )

        XCTAssertNil(window.zOrderHint)
    }

    private func makeRawWindow(
        id: UInt32,
        pid: Int32,
        ownerName: String,
        title: String,
        isOnScreen: Bool
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: ownerName,
            kCGWindowName as String: title,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowIsOnscreen as String: NSNumber(value: isOnScreen),
            kCGWindowBounds as String: [
                "X": NSNumber(value: 20),
                "Y": NSNumber(value: 30),
                "Width": NSNumber(value: 400),
                "Height": NSNumber(value: 300)
            ]
        ]
    }
}

private final class AXAttributeFixture {
    private var values: [Int: [String: CFTypeRef]] = [:]

    var reader: AXAttributeReader {
        AXAttributeReader { [values] element, attribute in
            values[Int(CFHash(element))]?[attribute as String]
        }
    }

    func set(_ value: CFTypeRef, for element: AXUIElement, attribute: String) {
        values[Int(CFHash(element)), default: [:]][attribute] = value
    }

    func setWindow(
        _ element: AXUIElement,
        title: String,
        role: String,
        subrole: String? = nil,
        frame: CGRect,
        isHidden: Bool = false
    ) {
        set(makeAXValue(frame.origin) as CFTypeRef, for: element, attribute: kAXPositionAttribute)
        set(makeAXValue(frame.size) as CFTypeRef, for: element, attribute: kAXSizeAttribute)
        set(title as CFString, for: element, attribute: kAXTitleAttribute)
        set(role as CFString, for: element, attribute: kAXRoleAttribute)
        set(NSNumber(value: isHidden), for: element, attribute: kAXHiddenAttribute)
        set(NSNumber(value: false), for: element, attribute: kAXMinimizedAttribute)
        set(NSNumber(value: false), for: element, attribute: kAXMainAttribute)
        set(NSNumber(value: false), for: element, attribute: "AXFullScreen")
        if let subrole {
            set(subrole as CFString, for: element, attribute: kAXSubroleAttribute)
        }
    }
}
