import ApplicationServices
import AppKit
import CoreGraphics
import XCTest
@testable import LayoutLock

final class WindowDiscoveryEngineTests: XCTestCase {
    func testUnrealProjectIdentityIsAvailableForVisibleAndStartingEditors() throws {
        let project = URL(fileURLWithPath: "/Projects/A/SharedProject.uproject")
        for visible in [true, false] {
            let app = AXUIElementCreateApplication(101)
            let window = AXUIElementCreateApplication(201)
            let fixture = AXAttributeFixture()
            fixture.set((visible ? [window] : []) as CFArray, for: app, attribute: kAXWindowsAttribute)
            fixture.setWindow(window, title: "SharedProject - Unreal Editor", role: "AXWindow",
                frame: CGRect(x: 20, y: 30, width: 400, height: 300))
            let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
                bundleIdentifier: "com.epicgames.UnrealEditor", unrealProjectURLProvider: { pid, document in
                    XCTAssertEqual(pid, 101)
                    XCTAssertNil(document)
                    return project
                })

            let result = try engine.discoverRunningWindowsWithDiagnostics()

            if visible {
                XCTAssertEqual(result.applications.first?.windows.first?.documentURLs, [project])
            } else {
                XCTAssertTrue(result.applications.isEmpty)
                XCTAssertEqual(result.unexposedApplications.first?.documentURLs, [project])
                XCTAssertTrue(result.unexposedApplications.first?.windows.isEmpty == true)
            }
        }
    }

    func testOtherOwnersNeverInvokeUnrealProjectProvider() throws {
        let app = AXUIElementCreateApplication(101)
        let fixture = AXAttributeFixture()
        fixture.set([] as CFArray, for: app, attribute: kAXWindowsAttribute)
        let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
            unrealProjectURLProvider: { _, _ in XCTFail("Only Unreal owns this project context"); return nil })
        XCTAssertTrue(try engine.discoverRunningWindowsWithDiagnostics().applications.isEmpty)
    }

    func testDiscoveryRetainsModalStateForMinimizedDialogWindows() throws {
        for modal: Bool? in [false, true, nil] {
            let app = AXUIElementCreateApplication(101)
            let window = AXUIElementCreateApplication(201)
            let fixture = AXAttributeFixture()
            let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
            fixture.set([window] as CFArray, for: app, attribute: kAXWindowsAttribute)
            fixture.setWindow(window, title: "Window", role: "AXWindow", subrole: "AXDialog", frame: frame)
            fixture.set(NSNumber(value: true), for: window, attribute: kAXMinimizedAttribute)
            if let modal { fixture.set(NSNumber(value: modal), for: window, attribute: kAXModalAttribute) }
            let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
                metadata: [101: [cgMetadata(id: 900, title: "Window", frame: frame)]],
                windowIDProvider: { _ in 900 })

            let result = try engine.discoverRunningWindowsWithDiagnostics()

            let discovered = try XCTUnwrap(result.applications.first?.windows.first)
            XCTAssertEqual(discovered.isModal, modal)
            XCTAssertTrue(discovered.isMinimized)
            XCTAssertEqual(discovered.subrole, "AXDialog")
            XCTAssertEqual(discovered.cgWindowID, 900)
        }
    }

    func testMainAndFocusedFallbackDeduplicatesOwnedWindowByCGIdentity() throws {
        let app = AXUIElementCreateApplication(101)
        let main = AXUIElementCreateApplication(201)
        let focused = AXUIElementCreateApplication(202)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([] as CFArray, for: app, attribute: kAXWindowsAttribute)
        fixture.set(main, for: app, attribute: kAXMainWindowAttribute)
        fixture.set(focused, for: app, attribute: kAXFocusedWindowAttribute)
        for window in [main, focused] {
            fixture.setWindow(window, title: "Document", role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String, frame: frame)
        }
        let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Document"), cgMetadata(id: 901, title: "Other hidden document")]],
            windowIDProvider: { _ in 900 })

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(result.applications.first?.windows.map(\.cgWindowID), [900])
        XCTAssertEqual(result.unexposedApplications.first?.windows.map(\.windowID), [901])
    }

    func testMainFallbackComplementsPartialAXWindowList() throws {
        let app = AXUIElementCreateApplication(101)
        let listed = AXUIElementCreateApplication(201)
        let main = AXUIElementCreateApplication(202)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([listed] as CFArray, for: app, attribute: kAXWindowsAttribute)
        fixture.set(main, for: app, attribute: kAXMainWindowAttribute)
        fixture.set(main, for: app, attribute: kAXFocusedWindowAttribute)
        for window in [listed, main] {
            fixture.setWindow(window, title: "Document", role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String, frame: frame)
        }
        let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Listed"), cgMetadata(id: 901, title: "Main")]],
            windowIDProvider: { CFEqual($0, listed) ? 900 : 901 })

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(result.applications.first?.windows.map(\.cgWindowID), [900, 901])
        XCTAssertTrue(result.unexposedApplications.isEmpty)
    }

    func testFallbackRequiresCurrentOwnerIdentityAndRetainsRoleFiltering() throws {
        for id: CGWindowID? in [nil, 0, 999, 901, 900] {
            let app = AXUIElementCreateApplication(101)
            let main = AXUIElementCreateApplication(201)
            let fixture = AXAttributeFixture()
            fixture.set([] as CFArray, for: app, attribute: kAXWindowsAttribute)
            fixture.set(main, for: app, attribute: kAXMainWindowAttribute)
            fixture.setWindow(main, title: "Panel", role: kAXSheetRole as String,
                frame: CGRect(x: 20, y: 30, width: 400, height: 300))
            let foreign = CGWindowMetadata(windowID: 901, processIdentifier: 102, ownerName: "Other",
                layer: 0, bounds: CGRect(x: 20, y: 30, width: 400, height: 300), title: "Other", isOnScreen: false, zOrderHint: nil)
            let engine = makeEngine(appElement: app, attributeReader: fixture.reader,
                metadata: [101: [cgMetadata(id: 900, title: "Hidden")], 102: [foreign]],
                windowIDProvider: { _ in id })

            let result = try engine.discoverRunningWindowsWithDiagnostics()

            XCTAssertTrue(result.applications.isEmpty)
            XCTAssertEqual(result.unexposedApplications.first?.windows.map(\.windowID) ?? [], id == 900 ? [] : [900])
            XCTAssertEqual(result.diagnostics.contains { $0.reason == WindowDiscoveryDiagnosticReason.transientRole }, id == 900)
        }
    }

    func testPartiallyExposedOwnerRetainsOnlyUnmatchedCGWindow() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(windowElement, title: "Visible", role: kAXWindowRole as String, frame: frame)
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Visible", frame: frame, isOnScreen: true),
                             cgMetadata(id: 901, title: "Hidden", frame: frame.offsetBy(dx: 100, dy: 100))]],
            windowIDProvider: { _ in 900 }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(result.applications.first?.windows.map(\.cgWindowID), [900])
        let owner = try XCTUnwrap(result.unexposedApplications.first)
        XCTAssertEqual(result.unexposedApplications.count, 1)
        XCTAssertEqual(owner.pid, 101)
        XCTAssertEqual(owner.windows.map(\.windowID), [901])
    }

    func testCaptureDoesNotReintroduceAXRejectedWindowsThroughCGFallback() throws {
        let directory = try TestTemporaryDirectory()
        let appElement = AXUIElementCreateApplication(101)
        let documentElement = AXUIElementCreateApplication(201)
        let sheetElement = AXUIElementCreateApplication(202)
        let floatingElement = AXUIElementCreateApplication(203)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([documentElement, sheetElement, floatingElement] as CFArray,
            for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(documentElement, title: "Document", role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String, frame: frame)
        fixture.setWindow(sheetElement, title: "Sheet", role: kAXSheetRole as String,
            frame: frame.offsetBy(dx: 20, dy: 20))
        fixture.setWindow(floatingElement, title: "Panel", role: kAXWindowRole as String,
            subrole: kAXFloatingWindowSubrole as String, frame: frame.offsetBy(dx: 40, dy: 40))
        let metadata = [
            cgMetadata(id: 900, title: "Document", frame: frame, isOnScreen: true),
            cgMetadata(id: 901, title: "Sheet", frame: frame.offsetBy(dx: 20, dy: 20)),
            cgMetadata(id: 902, title: "Panel", frame: frame.offsetBy(dx: 40, dy: 40)),
            cgMetadata(id: 903, title: "Hidden document", frame: frame.offsetBy(dx: 100, dy: 100))
        ]
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: metadata],
            windowIDProvider: { element in
                if CFEqual(element, documentElement) { return 900 }
                if CFEqual(element, sheetElement) { return 901 }
                if CFEqual(element, floatingElement) { return 902 }
                return nil
            }
        )
        let discovery = try engine.discoverRunningWindowsWithDiagnostics()
        XCTAssertEqual(discovery.applications.first?.windows.map(\.cgWindowID), [900])
        XCTAssertEqual(discovery.unexposedApplications.first?.windows.map(\.windowID), [903])
        XCTAssertEqual(discovery.diagnostics.map(\.reason), [
            WindowDiscoveryDiagnosticReason.transientRole,
            WindowDiscoveryDiagnosticReason.transientSubrole
        ])

        let display = makeDisplayRecord()
        let service = SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [DisplayResolver.ScreenSnapshot(
                    id: display.id,
                    localizedName: display.localizedName,
                    frame: display.frameRect,
                    visibleFrame: display.visibleFrameRect,
                    backingScaleFactor: display.backingScaleFactor,
                    isPrimary: display.isPrimary,
                    vendorID: nil, productID: nil, serialNumber: nil
                )]
            }),
            snapshotStore: SnapshotStore(snapshotsDirectoryURL: directory.url),
            discoveryResultProvider: { discovery },
            restoreSpaceAccess: RestoreSpaceAccess(
                inventory: { _ in RestoreSpaceInventory(activeByDisplay: [display.id: 1], ordinarySpaceIDs: [1, 2]) },
                membership: { $0 == 900 ? [1] : [2] },
                submitMove: { _, _ in XCTFail("Capture must not move windows"); return false },
                windowMetadata: { pid, id in metadata.first { $0.processIdentifier == pid && $0.windowID == id } }
            )
        )

        let snapshot = try service.captureSnapshot(named: "AX rejection regression")

        XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [900])
        XCTAssertEqual(snapshot.windows.map(\.captureSignature.source), [.accessibility])
    }

    func testRejectedAXWindowWithoutConfirmedIdentitySuppressesOnlyItsOwnersCGFallback() throws {
        let unknownIDs: [CGWindowID?] = [nil, 0, 999, 902]
        for unknownID in unknownIDs {
            let appElement = AXUIElementCreateApplication(101)
            let otherAppElement = AXUIElementCreateApplication(102)
            let documentElement = AXUIElementCreateApplication(201)
            let sheetElement = AXUIElementCreateApplication(202)
            let fixture = AXAttributeFixture()
            let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
            fixture.set([documentElement, sheetElement] as CFArray,
                for: appElement, attribute: kAXWindowsAttribute)
            fixture.set([] as CFArray, for: otherAppElement, attribute: kAXWindowsAttribute)
            fixture.setWindow(documentElement, title: "Document", role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String, frame: frame)
            fixture.setWindow(sheetElement, title: "Sheet", role: kAXSheetRole as String,
                frame: frame.offsetBy(dx: 20, dy: 20))
            let otherWindow = CGWindowMetadata(
                windowID: 902, processIdentifier: 102, ownerName: "Other app", layer: 0,
                bounds: frame, title: "Other hidden document", isOnScreen: false, zOrderHint: nil
            )
            let engine = WindowDiscoveryEngine(
                trustChecker: AccessibilityTrustChecker { true },
                attributeReader: fixture.reader,
                currentProcessIdentifier: 500,
                runningApplicationsProvider: {
                    [RunningApplicationSnapshot(bundleIdentifier: "com.example.editor", processIdentifier: 101, localizedName: "Editor"),
                     RunningApplicationSnapshot(bundleIdentifier: "com.example.other", processIdentifier: 102, localizedName: "Other app")]
                },
                appElementProvider: { $0 == 101 ? appElement : otherAppElement },
                cgWindowMetadataProvider: { _ in
                    [101: [self.cgMetadata(id: 900, title: "Document", frame: frame, isOnScreen: true),
                           self.cgMetadata(id: 901, title: "Sheet", frame: frame.offsetBy(dx: 20, dy: 20))],
                     102: [otherWindow]]
                },
                windowIDProvider: { CFEqual($0, documentElement) ? 900 : unknownID }
            )

            let result = try engine.discoverRunningWindowsWithDiagnostics()

            XCTAssertEqual(result.applications.first?.windows.map(\.cgWindowID), [900])
            XCTAssertEqual(result.unexposedApplications.map(\.pid), [102], "Rejected AX identity: \(String(describing: unknownID))")
            XCTAssertEqual(result.unexposedApplications.flatMap(\.windows).map(\.windowID), [902])
            XCTAssertEqual(result.diagnostics.filter { $0.processIdentifier == 101 }.map(\.reason),
                [WindowDiscoveryDiagnosticReason.transientRole])
        }
    }

    func testOwnerWithUnknownAXCGIdentityDoesNotEmitPotentialDuplicateFallback() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(windowElement, title: "Visible", role: kAXWindowRole as String, frame: frame)
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Visible", frame: frame),
                             cgMetadata(id: 901, title: "Hidden", frame: frame.offsetBy(dx: 100, dy: 100))]],
            windowIDProvider: { _ in nil }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()
        let window = try XCTUnwrap(result.applications.first?.windows.first)

        XCTAssertNil(window.cgWindowID)
        XCTAssertTrue(result.unexposedApplications.isEmpty)
    }

    func testRestoreDoesNotBindUnknownAXIdentityWithHiddenCGSibling() async throws {
        let bundle = "com.example.editor"
        let app = AXUIElementCreateApplication(101)
        let visible = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let hiddenFrame = frame.offsetBy(dx: 100, dy: 100)
        fixture.set([visible] as CFArray, for: app, attribute: kAXWindowsAttribute)
        fixture.setWindow(visible, title: "Visible", role: "AXWindow", subrole: "AXStandardWindow", frame: frame)
        let discovery = try makeEngine(appElement: app, attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Visible", frame: frame),
                cgMetadata(id: 901, title: "Hidden", frame: hiddenFrame)]],
            windowIDProvider: { _ in nil }).discoverRunningWindowsWithDiagnostics()
        XCTAssertEqual(discovery.applications.first?.windows.count, 1)
        XCTAssertNil(discovery.applications.first?.windows.first?.cgWindowID)
        XCTAssertTrue(discovery.unexposedApplications.isEmpty)

        let saved = WindowRecord(bundleIdentifier: bundle, pidAtCapture: 101, windowTitle: nil,
            role: "AXWindow", subrole: nil, frame: CGRectCodable(hiddenFrame), displayID: nil,
            normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 1, heightRatio: 1),
            zOrderHint: nil, isMinimized: false, isFullscreen: false, isVisible: false,
            captureSignature: WindowSignature(bundleIdentifier: bundle, owningPid: 101, windowTitle: nil,
                role: "AXWindow", subrole: nil, capturedFrame: CGRectCodable(hiddenFrame),
                cgWindowID: 901, source: .coreGraphics))
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let snapshot = Snapshot(name: "Hidden saved window",
            sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil), windows: [saved])
        try store.save(snapshot)
        let applier = ScopedDiscoveryWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier, displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationActivator: applier, discoveryResultProvider: { discovery },
            runningApplicationBundleProvider: { [bundle] }, launchTimeout: 0)

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.map(\.reason), [RestoreSkipReason.windowNotFound])
        XCTAssertEqual(result.windowDiagnostics.first?.candidateCount, 1)
        XCTAssertTrue(applier.windowIDs.isEmpty, "The unrelated exposed window must not receive geometry.")
    }

    func testUnityUntitledAndSavedSceneWindowsAppendValidatedProjectRoot() throws {
        let directory = try TestTemporaryDirectory()
        let project = try makeUnityProject(in: directory.url)
        let scene = project.appendingPathComponent("Assets/Level.unity")
        try Data().write(to: scene)
        let appElement = AXUIElementCreateApplication(101)
        let untitledElement = AXUIElementCreateApplication(201)
        let sceneElement = AXUIElementCreateApplication(202)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([untitledElement, sceneElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(untitledElement, title: "Untitled", role: kAXWindowRole as String, frame: frame)
        fixture.setWindow(sceneElement, title: "Level", role: kAXWindowRole as String, frame: frame)
        fixture.set(scene.absoluteString as CFString, for: sceneElement, attribute: kAXDocumentAttribute)
        var requestedPIDs: [pid_t] = []
        var requestedDocuments: [URL?] = []
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            bundleIdentifier: "com.unity3d.UnityEditor5.x",
            unityProjectURLProvider: { pid, document in
                requestedPIDs.append(pid)
                requestedDocuments.append(document)
                return UnityProjectResolver().projectURL(containing: document ?? project)
            }
        )

        let windows = try XCTUnwrap(engine.discoverRunningWindowsWithDiagnostics().applications.first?.windows)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].documentURL, project)
        XCTAssertEqual(windows[0].documentURLs, [project])
        XCTAssertEqual(windows[1].documentURL, scene)
        XCTAssertEqual(windows[1].documentURLs, [scene, project])
        XCTAssertEqual(requestedPIDs, [101, 101])
        XCTAssertEqual(requestedDocuments, [nil, scene])
    }

    func testNonUnityOwnersNeverInvokeUnityProjectProvider() throws {
        let appElement = AXUIElementCreateApplication(101)
        let windowElement = AXUIElementCreateApplication(201)
        let fixture = AXAttributeFixture()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([windowElement] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        fixture.setWindow(windowElement, title: "Visible", role: kAXWindowRole as String, frame: frame)
        var providerCalls = 0
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Visible", frame: frame),
                             cgMetadata(id: 901, title: "Hidden", frame: frame.offsetBy(dx: 100, dy: 100))]],
            windowIDProvider: { _ in 900 },
            unityProjectURLProvider: { _, _ in providerCalls += 1; return nil }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertEqual(result.applications.first?.windows.count, 1)
        XCTAssertEqual(result.unexposedApplications.first?.windows.map(\.windowID), [901])
        XCTAssertEqual(providerCalls, 0)
        XCTAssertTrue(result.unexposedApplications.first?.documentURLs.isEmpty == true)
    }

    func testUnityOwnerWithNoAXWindowsCarriesProjectContextAlongsideCGWindows() throws {
        let directory = try TestTemporaryDirectory()
        let project = try makeUnityProject(in: directory.url)
        let appElement = AXUIElementCreateApplication(101)
        let fixture = AXAttributeFixture()
        fixture.set([] as CFArray, for: appElement, attribute: kAXWindowsAttribute)
        var providerCalls = 0
        let engine = makeEngine(
            appElement: appElement,
            attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 901, title: "Hidden Unity")]],
            bundleIdentifier: "com.unity3d.UnityEditor5.x",
            unityProjectURLProvider: { pid, document in
                XCTAssertEqual(pid, 101)
                XCTAssertNil(document)
                providerCalls += 1
                return UnityProjectResolver().projectURL(containing: project)
            }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()
        let owner = try XCTUnwrap(result.unexposedApplications.first)

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(owner.bundleIdentifier, "com.unity3d.UnityEditor5.x")
        XCTAssertEqual(owner.windows.map(\.windowID), [901])
        XCTAssertEqual(owner.documentURLs, [project])
        XCTAssertEqual(providerCalls, 1)
    }

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

    func testScopedDiscoveryFiltersBeforeCGAndAXReadsWithoutChangingCapture() throws {
        let applications = [
            RunningApplicationSnapshot(bundleIdentifier: "com.example.editor", processIdentifier: 101, localizedName: "One"),
            RunningApplicationSnapshot(bundleIdentifier: "com.example.editor", processIdentifier: 102, localizedName: "Two"),
            RunningApplicationSnapshot(bundleIdentifier: "com.example.other", processIdentifier: 103, localizedName: "Other")
        ]
        var cgPIDs: Set<pid_t> = []
        var axPIDs: Set<pid_t> = []
        let engine = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true },
            attributeReader: AXAttributeReader(attributeValueProvider: { _, _ in nil }),
            currentProcessIdentifier: 500,
            runningApplicationsProvider: { applications },
            appElementProvider: { pid in axPIDs.insert(pid); return AXUIElementCreateApplication(pid) },
            cgWindowMetadataProvider: { cgPIDs = $0; return [:] }
        )

        let scopes: [(Set<String>?, pid_t?, Set<pid_t>)] = [
            (["com.example.editor"], nil, [101, 102]),
            (nil, 102, [102]),
            (["com.example.editor"], 103, []),
            ([], nil, [])
        ]
        for (bundles, pid, expected) in scopes {
            axPIDs = []
            _ = try engine.discoverRunningWindowsWithDiagnostics(bundleIdentifiers: bundles, processIdentifier: pid)
            XCTAssertEqual(cgPIDs, expected)
            XCTAssertEqual(axPIDs, expected)
        }

        axPIDs = []
        _ = try engine.discoverRunningWindowsWithDiagnostics()
        XCTAssertEqual(cgPIDs, [101, 102, 103])
        XCTAssertEqual(axPIDs, [101, 102, 103])
    }

    func testRestoreRetainsOtherLayoutWindowsAfterPIDScopedSpaceRecovery() async throws {
        let directory = try TestTemporaryDirectory()
        let fixture = AXAttributeFixture()
        let hiddenApp = AXUIElementCreateApplication(101)
        let recoveredApp = AXUIElementCreateApplication(201)
        let otherApp = AXUIElementCreateApplication(102)
        let hiddenWindow = AXUIElementCreateApplication(301)
        let otherWindow = AXUIElementCreateApplication(302)
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        fixture.set([] as CFArray, for: hiddenApp, attribute: kAXWindowsAttribute)
        fixture.set([hiddenWindow] as CFArray, for: recoveredApp, attribute: kAXWindowsAttribute)
        fixture.set([otherWindow] as CFArray, for: otherApp, attribute: kAXWindowsAttribute)
        fixture.setWindow(hiddenWindow, title: "Hidden", role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String, frame: frame)
        fixture.setWindow(otherWindow, title: "Other", role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String, frame: frame)
        var moved = false
        var queries: [Set<pid_t>] = []
        let discovery = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true }, attributeReader: fixture.reader,
            currentProcessIdentifier: 500,
            runningApplicationsProvider: {
                [RunningApplicationSnapshot(bundleIdentifier: "com.example.editor", processIdentifier: 101, localizedName: "Editor"),
                 RunningApplicationSnapshot(bundleIdentifier: "com.example.other", processIdentifier: 102, localizedName: "Other"),
                 RunningApplicationSnapshot(bundleIdentifier: "com.example.unrelated", processIdentifier: 103, localizedName: "Unrelated")]
            },
            appElementProvider: { pid in
                XCTAssertNotEqual(pid, 103)
                return pid == 101 ? (moved ? recoveredApp : hiddenApp) : otherApp
            },
            cgWindowMetadataProvider: { pids in
                queries.append(pids)
                return [
                    101: [self.cgMetadata(id: 900, title: "Hidden", frame: frame, isOnScreen: moved)],
                    102: [CGWindowMetadata(windowID: 901, processIdentifier: 102, ownerName: "Other", layer: 0,
                        bounds: frame, title: "Other", isOnScreen: true, zOrderHint: nil)]
                ].filter { pids.contains($0.key) }
            },
            windowIDProvider: { CFEqual($0, hiddenWindow) ? 900 : 901 }
        )
        let display = makeDisplayRecord()
        let windows = [("com.example.editor", "Hidden", Int32(101)), ("com.example.other", "Other", Int32(102))].map { bundle, title, pid in
            WindowRecord(bundleIdentifier: bundle, pidAtCapture: pid, windowTitle: title,
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                frame: CGRectCodable(frame), displayID: display.id,
                normalizedFrame: NormalizedRect(windowFrame: frame, displayFrame: display.frameRect),
                zOrderHint: nil, isMinimized: false, isFullscreen: false, isVisible: true,
                captureSignature: WindowSignature(bundleIdentifier: bundle, owningPid: pid, windowTitle: title,
                    role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                    capturedFrame: CGRectCodable(frame), cgWindowID: nil))
        }
        let snapshot = Snapshot(name: "Scoped recovery",
            sourceDisplayState: DisplayState(displays: [display], primaryDisplayID: display.id), windows: windows)
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        try store.save(snapshot)
        let applier = ScopedDiscoveryWindowApplier()
        let engine = RestoreEngine(snapshotStore: store, windowDiscoveryEngine: discovery,
            trustChecker: AccessibilityTrustChecker { true }, windowApplier: applier,
            displayResolver: DisplayResolver(screenProvider: {
                [DisplayResolver.ScreenSnapshot(id: display.id, localizedName: display.localizedName,
                    frame: display.frameRect, visibleFrame: display.visibleFrameRect,
                    backingScaleFactor: display.backingScaleFactor, isPrimary: true,
                    vendorID: nil, productID: nil, serialNumber: nil)]
            }), applicationActivator: applier,
            spaces: RestoreSpaceCoordinator(access: RestoreSpaceAccess(
                inventory: { _ in RestoreSpaceInventory(activeByDisplay: [display.id: 1], ordinarySpaceIDs: [1, 2]) },
                membership: { $0 == 900 && !moved ? [2] : [1] },
                submitMove: { id, _ in XCTAssertEqual(id, 900); moved = true; return true }
            )), runningApplicationBundleProvider: { [] })

        let result = try await engine.restoreSnapshot(id: snapshot.id)

        XCTAssertTrue(moved)
        XCTAssertEqual(queries, [[101, 102], [101], [101, 102]])
        XCTAssertEqual(result.restoredWindows, 2)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.windowIDs, [900, 901])
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
            metadata: [101: [metadata]],
            windowIDProvider: { _ in 900 },
            applicationBundleURL: URL(fileURLWithPath: "/Custom Apps/Editor.app")
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()
        let application = try XCTUnwrap(result.applications.first)
        let window = try XCTUnwrap(application.windows.first)

        XCTAssertEqual(application.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(application.applicationBundleURL, URL(fileURLWithPath: "/Custom Apps/Editor.app"))
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

        XCTAssertNil(window.cgWindowID, "A geometry match must not authorize Space operations.")
        XCTAssertEqual(window.zOrderHint, 3)
        XCTAssertTrue(window.isVisible)
    }

    func testCaptureRejectsInactiveWindowBorrowingVisibleWindowsMetadata() throws {
        let app = AXUIElementCreateApplication(101)
        let inactive = AXUIElementCreateApplication(201)
        let visible = AXUIElementCreateApplication(202)
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let fixture = AXAttributeFixture()
        fixture.set([inactive, visible] as CFArray, for: app, attribute: kAXWindowsAttribute)
        for window in [inactive, visible] {
            fixture.setWindow(window, title: "Terminal", role: "AXWindow",
                subrole: "AXStandardWindow", frame: frame)
        }
        let engine = makeEngine(
            appElement: app,
            attributeReader: fixture.reader,
            metadata: [101: [
                cgMetadata(id: 900, title: "Terminal", frame: frame, isOnScreen: false),
                cgMetadata(id: 901, title: "Terminal", frame: frame, isOnScreen: true)
            ]],
            windowIDProvider: { CFEqual($0, visible) ? 901 : nil }
        )
        let discovery = try engine.discoverRunningWindowsWithDiagnostics()
        let windows = try XCTUnwrap(discovery.applications.first?.windows)
        XCTAssertNil(windows[0].cgWindowID)
        XCTAssertEqual(windows[0].isOnScreen, true, "Geometry can borrow the visible window's hints.")
        XCTAssertEqual(windows[1].cgWindowID, 901)

        let display = makeDisplayRecord()
        let spaceAccess = RestoreSpaceAccess(
            inventory: { _ in RestoreSpaceInventory(activeByDisplay: [display.id: 1], ordinarySpaceIDs: [1, 2]) },
            membership: { $0 == 901 ? [1] : [2] },
            submitMove: { _, _ in XCTFail("Capture must not move windows"); return false }
        )
        for access in [spaceAccess, .unavailable] {
            let directory = try TestTemporaryDirectory()
            let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
            let service = SnapshotCaptureService(
                displayResolver: DisplayResolver(screenProvider: {
                    [DisplayResolver.ScreenSnapshot(
                        id: display.id, localizedName: display.localizedName,
                        frame: display.frameRect, visibleFrame: display.visibleFrameRect,
                        backingScaleFactor: display.backingScaleFactor, isPrimary: display.isPrimary,
                        vendorID: nil, productID: nil, serialNumber: nil)]
                }),
                snapshotStore: store,
                discoveryResultProvider: { discovery },
                restoreSpaceAccess: access
            )

            let snapshot = try service.captureSnapshot(named: "Active Space")

            XCTAssertEqual(snapshot.windows.map(\.captureSignature.cgWindowID), [901])
            XCTAssertEqual(try store.loadSnapshot(id: snapshot.id).windows.count, 1)
        }
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

    func testApplicationDocumentURLResolverFindsSupportedEditorWorkspacesFromWindowTitles() throws {
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

        let cases = [
            (bundleIdentifier: "com.microsoft.VSCode", supportName: "Code", title: ".gitignore — ScrollSnap — work"),
            (bundleIdentifier: "com.google.antigravity-ide", supportName: "Antigravity IDE", title: "Package.swift — ScrollSnap — Antigravity IDE")
        ]
        for item in cases {
            XCTAssertEqual(
                ApplicationWindowDocumentURLResolver.applicationSupportName(bundleIdentifier: item.bundleIdentifier),
                item.supportName
            )
            XCTAssertEqual(
                resolver.resolve(bundleIdentifier: item.bundleIdentifier, windowTitle: item.title),
                workspaceURL.standardizedFileURL
            )
        }
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
        let documentURL = workspaceURL.appendingPathComponent(".gitignore")
        try Data().write(to: documentURL)
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
        fixture.set(documentURL.absoluteString as CFString, for: windowElement, attribute: kAXDocumentAttribute)
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
            attributeReader: fixture.reader,
            metadata: [101: [cgMetadata(id: 900, title: "Broken")]],
            windowIDProvider: { _ in 900 }
        )

        let result = try engine.discoverRunningWindowsWithDiagnostics()

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.unexposedApplications.flatMap(\.windows).isEmpty)
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
        windowIDProvider: @escaping (AXUIElement) -> CGWindowID? = { _ in nil },
        bundleIdentifier: String = "com.example.editor",
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver =
            ApplicationWindowDocumentURLResolver(),
        unityProjectURLProvider: @escaping (pid_t, URL?) -> URL? = { _, _ in nil },
        unrealProjectURLProvider: @escaping (pid_t, URL?) -> URL? = { _, _ in nil },
        applicationBundleURL: URL? = nil
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
                        applicationBundleURL: applicationBundleURL,
                        processIdentifier: 101,
                        localizedName: "Editor"
                    )
                ]
            },
            appElementProvider: { _ in appElement },
            cgWindowMetadataProvider: { _ in metadata },
            windowIDProvider: windowIDProvider,
            unityProjectURLProvider: unityProjectURLProvider,
            unrealProjectURLProvider: unrealProjectURLProvider
        )
    }

    private func cgMetadata(
        id: CGWindowID,
        title: String,
        frame: CGRect = CGRect(x: 20, y: 30, width: 400, height: 300),
        isOnScreen: Bool = false
    ) -> CGWindowMetadata {
        CGWindowMetadata(
            windowID: id,
            processIdentifier: 101,
            ownerName: "Editor",
            layer: 0,
            bounds: frame,
            title: title,
            isOnScreen: isOnScreen,
            zOrderHint: nil
        )
    }

    private func makeUnityProject(in directory: URL) throws -> URL {
        let project = directory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        let settings = project.appendingPathComponent("ProjectSettings", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try "m_EditorVersion: 6000.2.1f1\n".write(
            to: settings.appendingPathComponent("ProjectVersion.txt"),
            atomically: true,
            encoding: .utf8
        )
        return project.standardizedFileURL
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

private final class ScopedDiscoveryWindowApplier: RestoreWindowApplying, RestoreApplicationActivating {
    private(set) var windowIDs: [CGWindowID?] = []

    func apply(savedWindow: WindowRecord, targetFrame: CGRect, to window: DiscoveredWindow) async throws -> RestoreWindowApplyResult {
        windowIDs.append(window.cgWindowID)
        return .restored(finalObservedFrame: targetFrame)
    }

    func raise(_ window: DiscoveredWindow) -> Bool { false }
    func focus(_ window: DiscoveredWindow) -> RestoreWindowFocusResult {
        RestoreWindowFocusResult(didRaise: false, didSetMain: false, didSetFocused: false)
    }
    func activate(processIdentifier: pid_t) async -> Bool { false }
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
