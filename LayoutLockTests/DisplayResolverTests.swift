import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import LayoutLock

final class DisplayResolverTests: XCTestCase {
    func testScreenSnapshotAlignmentUsesPrimaryDisplayAsAccessibilityAnchor() {
        let alignedScreens = DisplayResolver.ScreenSnapshot.alignedToAccessibilityCoordinates(
            makeThreeMonitorScreensInAppKitCoordinates(),
            primaryDisplayID: 1
        )

        XCTAssertEqual(alignedScreens.first(where: { $0.id == 3 })?.frame, CGRect(x: -1759, y: -1440, width: 2560, height: 1440))
        XCTAssertEqual(alignedScreens.first(where: { $0.id == 3 })?.visibleFrame, CGRect(x: -1759, y: -1415, width: 2560, height: 1415))
        XCTAssertEqual(alignedScreens.first(where: { $0.id == 1 })?.frame, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(alignedScreens.first(where: { $0.id == 1 })?.visibleFrame, CGRect(x: 0, y: 38, width: 1512, height: 944))
        XCTAssertEqual(alignedScreens.first(where: { $0.id == 2 })?.frame, CGRect(x: 801, y: -1440, width: 2560, height: 1440))
        XCTAssertEqual(alignedScreens.first(where: { $0.id == 2 })?.visibleFrame, CGRect(x: 801, y: -1415, width: 2560, height: 1415))
    }

    func testCaptureDisplayStateBuildsDisplayRecordsAndVirtualBounds() {
        let resolver = DisplayResolver(screenProvider: {
            [
                .init(
                    id: 2,
                    localizedName: "Left Display",
                    frame: CGRect(x: -1728, y: 0, width: 1728, height: 1117),
                    visibleFrame: CGRect(x: -1728, y: 23, width: 1728, height: 1056),
                    backingScaleFactor: 2,
                    isPrimary: false,
                    vendorID: 11,
                    productID: 22,
                    serialNumber: 33
                ),
                .init(
                    id: 1,
                    localizedName: "Built-in",
                    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 919),
                    backingScaleFactor: 2,
                    isPrimary: true,
                    vendorID: 44,
                    productID: 55,
                    serialNumber: 66
                )
            ]
        })

        let displayState = resolver.captureDisplayState()

        XCTAssertEqual(displayState.primaryDisplayID, 1)
        XCTAssertEqual(displayState.displays.map(\.id), [2, 1])
        XCTAssertEqual(displayState.displays.first?.localizedName, "Left Display")
        XCTAssertEqual(displayState.displays.first?.visibleFrameRect, CGRect(x: -1728, y: 23, width: 1728, height: 1056))
        XCTAssertEqual(displayState.virtualDesktopBoundsRect, CGRect(x: -1728, y: 0, width: 3240, height: 1117))
    }

    func testResolveDisplayPrefersLargestIntersectionArea() {
        let resolver = DisplayResolver()
        let displayState = DisplayState(
            displays: [
                makeDisplayRecord(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                makeDisplayRecord(id: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
            ],
            primaryDisplayID: 1
        )
        let windowFrame = CGRect(x: 1200, y: 100, width: 1200, height: 700)

        let resolvedDisplay = resolver.resolveDisplay(for: windowFrame, in: displayState)

        XCTAssertEqual(resolvedDisplay?.id, 2)
    }

    func testResolveDisplayFallsBackToNearestDisplayCenter() {
        let resolver = DisplayResolver()
        let displayState = DisplayState(
            displays: [
                makeDisplayRecord(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                makeDisplayRecord(id: 2, frame: CGRect(x: 2000, y: 0, width: 2560, height: 1440))
            ],
            primaryDisplayID: 1
        )
        let windowFrame = CGRect(x: 1500, y: 100, width: 200, height: 300)

        let resolvedDisplay = resolver.resolveDisplay(for: windowFrame, in: displayState)

        XCTAssertEqual(resolvedDisplay?.id, 1)
    }

    func testResolveDisplayMatchesThreeMonitorAccessibilityCoordinates() {
        let resolver = DisplayResolver(screenProvider: {
            DisplayResolver.ScreenSnapshot.alignedToAccessibilityCoordinates(
                self.makeThreeMonitorScreensInAppKitCoordinates(),
                primaryDisplayID: 1
            )
        })
        let displayState = resolver.captureDisplayState()

        XCTAssertEqual(
            resolver.resolveDisplay(
                for: CGRect(x: 1832, y: -1212, width: 1313, height: 900),
                in: displayState
            )?.id,
            2
        )
        XCTAssertEqual(
            resolver.resolveDisplay(
                for: CGRect(x: -1759, y: -1415, width: 502, height: 1415),
                in: displayState
            )?.id,
            3
        )
        XCTAssertEqual(
            resolver.resolveDisplay(
                for: CGRect(x: 0, y: 38, width: 1512, height: 944),
                in: displayState
            )?.id,
            1
        )
    }

    func testNormalizedFrameUsesDisplayFrameInsteadOfVisibleFrame() {
        let resolver = DisplayResolver()
        let display = DisplayRecord(
            id: 7,
            localizedName: "Primary",
            frame: CGRectCodable(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRectCodable(x: 0, y: 25, width: 1512, height: 919),
            backingScaleFactor: 2,
            isPrimary: true,
            vendorID: nil,
            productID: nil,
            serialNumber: nil
        )
        let windowFrame = CGRect(x: 120, y: 80, width: 756, height: 491)

        let normalized = resolver.normalizedFrame(for: windowFrame, in: display)

        XCTAssertEqual(normalized.xRatio, 120 / 1512, accuracy: 0.0001)
        XCTAssertEqual(normalized.yRatio, 80 / 982, accuracy: 0.0001)
        XCTAssertEqual(normalized.widthRatio, 756 / 1512, accuracy: 0.0001)
        XCTAssertEqual(normalized.heightRatio, 491 / 982, accuracy: 0.0001)
    }

    func testNormalizedRectRoundTripsAcrossDifferentDisplaySizes() {
        let savedDisplayFrame = CGRect(x: -1728, y: 0, width: 1728, height: 1117)
        let savedWindowFrame = CGRect(x: -1500, y: 100, width: 864, height: 558.5)
        let normalized = NormalizedRect(windowFrame: savedWindowFrame, displayFrame: savedDisplayFrame)
        let targetDisplayFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        let reconstructedFrame = normalized.denormalized(in: targetDisplayFrame)

        XCTAssertEqual(reconstructedFrame.origin.x, 337.7778, accuracy: 0.001)
        XCTAssertEqual(reconstructedFrame.origin.y, 128.9167, accuracy: 0.001)
        XCTAssertEqual(reconstructedFrame.size.width, 1280, accuracy: 0.001)
        XCTAssertEqual(reconstructedFrame.size.height, 720, accuracy: 0.001)
    }

    func testSnapshotCaptureAssignsExternalDisplayIDAndNormalizedFrame() throws {
        let alignedScreens = DisplayResolver.ScreenSnapshot.alignedToAccessibilityCoordinates(
            makeThreeMonitorScreensInAppKitCoordinates(),
            primaryDisplayID: 1
        )
        let resolver = DisplayResolver(screenProvider: { alignedScreens })
        let displayState = resolver.captureDisplayState()
        let service = SnapshotCaptureService(
            displayResolver: resolver,
            snapshotStore: SnapshotStore(
                snapshotsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
        )
        let window = DiscoveredWindow(
            axElement: AXUIElementCreateSystemWide(),
            title: "LayoutLock — PermissionCoordinator.swift",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRect(x: 1832, y: -1212, width: 1313, height: 900),
            isMinimized: false,
            isFullscreen: false,
            isMain: true,
            isVisible: true,
            cgWindowID: 228132,
            ownerName: "Xcode",
            cgLayer: 0,
            zOrderHint: 210,
            isOnScreen: true
        )
        let application = DiscoveredApplication(
            bundleIdentifier: "com.apple.dt.Xcode",
            pid: 73418,
            localizedName: "Xcode",
            windows: [window]
        )

        let record = try service.makeWindowRecord(
            application: application,
            window: window,
            displayState: displayState
        )
        let expectedDisplay = try XCTUnwrap(displayState.displays.first(where: { $0.id == 2 }))

        XCTAssertEqual(record.displayID, 2)
        XCTAssertNotEqual(record.displayID, 1)
        XCTAssertEqual(
            record.normalizedFrame,
            NormalizedRect(windowFrame: window.frame, displayFrame: expectedDisplay.frameRect)
        )
    }

    func testRestorePlanUsesExactDisplayIDAndNormalizedFrame() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            localizedName: "External",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let currentDisplay = makeDisplayRecord(
            id: 10,
            localizedName: "External",
            frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
            visibleFrame: CGRect(x: 0, y: 40, width: 2000, height: 900)
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.2, widthRatio: 0.5, heightRatio: 0.4)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [currentDisplay], primaryDisplayID: 10)
        )

        XCTAssertEqual(plan.targetFrame, CGRect(x: 200, y: 200, width: 1000, height: 400))
        XCTAssertEqual(plan.resolvedDisplayID, 10)
        XCTAssertNil(plan.fallback)
    }

    func testRestorePlanFallsBackByHardwareIdentifiers() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            vendorID: 1,
            productID: 2,
            serialNumber: 3
        )
        let currentDisplay = makeDisplayRecord(
            id: 20,
            frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
            vendorID: 1,
            productID: 2,
            serialNumber: 3
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.25, yRatio: 0.25, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [currentDisplay], primaryDisplayID: 20)
        )

        XCTAssertEqual(plan.targetFrame, CGRect(x: 500, y: 250, width: 1000, height: 500))
        XCTAssertEqual(plan.resolvedDisplayID, 20)
        XCTAssertEqual(plan.fallback?.reason, DisplayFallbackReason.hardwareMatch)
    }

    func testRestorePlanUsesExactDisplayIDWhenSavedDisplayHasNoStableIdentity() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let currentDisplay = makeDisplayRecord(
            id: 10,
            frame: CGRect(x: 1200, y: 0, width: 1200, height: 900)
        )
        let primaryDisplay = makeDisplayRecord(
            id: 1,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            isPrimary: true
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.25, yRatio: 0.25, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay, primaryDisplay], primaryDisplayID: 1),
            to: DisplayState(displays: [primaryDisplay, currentDisplay], primaryDisplayID: 1)
        )

        XCTAssertEqual(plan.targetFrame, CGRect(x: 1500, y: 225, width: 600, height: 450))
        XCTAssertEqual(plan.resolvedDisplayID, 10)
        XCTAssertNil(plan.fallback)
    }

    func testRestorePlanUsesHardwareIdentityWhenExternalDisplayIDsAreSwapped() {
        let resolver = DisplayResolver()
        let savedSamsung = makeDisplayRecord(
            id: 3,
            localizedName: "S27C900P",
            frame: CGRect(x: -1759, y: -1440, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -1759, y: -1415, width: 2560, height: 1415),
            isPrimary: false,
            vendorID: 19501,
            productID: 29589,
            serialNumber: 1536
        )
        let savedMSI = makeDisplayRecord(
            id: 2,
            localizedName: "MSI MP271Q",
            frame: CGRect(x: 801, y: -1440, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 801, y: -1415, width: 2560, height: 1415),
            isPrimary: false,
            vendorID: 13929,
            productID: 12451,
            serialNumber: 183
        )
        let currentSamsung = makeDisplayRecord(
            id: 2,
            localizedName: "S27C900P",
            frame: savedSamsung.frameRect,
            visibleFrame: savedSamsung.visibleFrameRect,
            isPrimary: false,
            vendorID: 19501,
            productID: 29589,
            serialNumber: 1536
        )
        let currentMSI = makeDisplayRecord(
            id: 3,
            localizedName: "MSI MP271Q",
            frame: savedMSI.frameRect,
            visibleFrame: savedMSI.visibleFrameRect,
            isPrimary: false,
            vendorID: 13929,
            productID: 12451,
            serialNumber: 183
        )
        let sourceDisplayState = DisplayState(
            displays: [savedSamsung, savedMSI],
            primaryDisplayID: nil
        )
        let currentDisplayState = DisplayState(
            displays: [currentSamsung, currentMSI],
            primaryDisplayID: nil
        )

        let samsungPlan = resolver.restorePlan(
            for: makeWindowRecord(
                displayID: 3,
                normalizedFrame: NormalizedRect(xRatio: 0.25, yRatio: 0.1, widthRatio: 0.5, heightRatio: 0.5)
            ),
            from: sourceDisplayState,
            to: currentDisplayState
        )
        let msiPlan = resolver.restorePlan(
            for: makeWindowRecord(
                displayID: 2,
                normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.2, widthRatio: 0.5, heightRatio: 0.5)
            ),
            from: sourceDisplayState,
            to: currentDisplayState
        )

        XCTAssertEqual(samsungPlan.resolvedDisplayID, 2)
        XCTAssertEqual(samsungPlan.fallback?.reason, DisplayFallbackReason.hardwareMatch)
        XCTAssertEqual(samsungPlan.targetFrame, CGRect(x: -1119, y: -1296, width: 1280, height: 720))
        XCTAssertEqual(msiPlan.resolvedDisplayID, 3)
        XCTAssertEqual(msiPlan.fallback?.reason, DisplayFallbackReason.hardwareMatch)
        XCTAssertEqual(msiPlan.targetFrame, CGRect(x: 1057, y: -1152, width: 1280, height: 720))
    }

    func testRestorePlanSkipsAmbiguousHardwareMatches() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            localizedName: "Studio Display",
            frame: CGRect(x: 1200, y: 0, width: 1000, height: 800),
            vendorID: 1,
            productID: 2
        )
        let distantHardwareMatch = makeDisplayRecord(
            id: 20,
            localizedName: "Studio Display",
            frame: CGRect(x: -3000, y: 0, width: 1000, height: 800),
            vendorID: 1,
            productID: 2
        )
        let closestHardwareMatch = makeDisplayRecord(
            id: 21,
            localizedName: "Studio Display",
            frame: CGRect(x: 1180, y: 0, width: 1000, height: 800),
            vendorID: 1,
            productID: 2
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.1, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [distantHardwareMatch, closestHardwareMatch], primaryDisplayID: 20)
        )

        XCTAssertEqual(plan.resolvedDisplayID, 21)
        XCTAssertEqual(plan.fallback?.reason, DisplayFallbackReason.semanticMatch)
    }

    func testRestorePlanFallsBackByNameAndClosestFrame() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            localizedName: "Studio Display",
            frame: CGRect(x: 1200, y: 0, width: 1000, height: 800)
        )
        let distantDisplay = makeDisplayRecord(
            id: 20,
            localizedName: "Studio Display",
            frame: CGRect(x: -3000, y: 0, width: 1600, height: 900)
        )
        let closestDisplay = makeDisplayRecord(
            id: 21,
            localizedName: "Studio Display",
            frame: CGRect(x: 1180, y: 0, width: 1000, height: 800)
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.1, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [distantDisplay, closestDisplay], primaryDisplayID: 20)
        )

        XCTAssertEqual(plan.resolvedDisplayID, 21)
        XCTAssertEqual(plan.targetFrame, CGRect(x: 1280, y: 80, width: 500, height: 400))
        XCTAssertEqual(plan.fallback?.reason, DisplayFallbackReason.semanticMatch)
    }

    func testRestorePlanFallsBackToPrimaryDisplayWhenSavedDisplayIsMissing() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            localizedName: "External",
            frame: CGRect(x: 1440, y: 0, width: 1000, height: 800)
        )
        let primaryDisplay = makeDisplayRecord(
            id: 1,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isPrimary: true
        )
        let secondaryDisplay = makeDisplayRecord(
            id: 2,
            localizedName: "Side",
            frame: CGRect(x: -1200, y: 0, width: 1200, height: 800)
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.2, yRatio: 0.25, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [secondaryDisplay, primaryDisplay], primaryDisplayID: 1)
        )

        XCTAssertEqual(plan.resolvedDisplayID, 1)
        XCTAssertEqual(plan.targetFrame, CGRect(x: 288, y: 225, width: 720, height: 450))
        XCTAssertEqual(plan.fallback?.reason, DisplayFallbackReason.primaryDisplay)
    }

    func testRestorePlanDoesNotTreatMissingNamesAsSemanticMatch() {
        let resolver = DisplayResolver()
        let savedDisplay = makeDisplayRecord(
            id: 10,
            localizedName: nil,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let unnamedSecondaryDisplay = makeDisplayRecord(
            id: 20,
            localizedName: nil,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let primaryDisplay = makeDisplayRecord(
            id: 1,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isPrimary: true
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.2, yRatio: 0.25, widthRatio: 0.5, heightRatio: 0.5)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [savedDisplay], primaryDisplayID: 10),
            to: DisplayState(displays: [unnamedSecondaryDisplay, primaryDisplay], primaryDisplayID: 1)
        )

        XCTAssertEqual(plan.resolvedDisplayID, 1)
        XCTAssertEqual(plan.fallback?.reason, DisplayFallbackReason.primaryDisplay)
    }

    func testRestorePlanClampsFrameIntoVisibleFrame() {
        let resolver = DisplayResolver()
        let display = makeDisplayRecord(
            id: 10,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 50, width: 1000, height: 700)
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.9, yRatio: 0.95, widthRatio: 0.3, heightRatio: 0.2)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [display], primaryDisplayID: 10),
            to: DisplayState(displays: [display], primaryDisplayID: 10)
        )

        XCTAssertEqual(plan.targetFrame, CGRect(x: 700, y: 590, width: 300, height: 160))
    }

    func testRestorePlanShrinksOversizedFrameToVisibleFrame() {
        let resolver = DisplayResolver()
        let display = makeDisplayRecord(
            id: 10,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let window = makeWindowRecord(
            displayID: 10,
            normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.1, widthRatio: 2, heightRatio: 2)
        )

        let plan = resolver.restorePlan(
            for: window,
            from: DisplayState(displays: [display], primaryDisplayID: 10),
            to: DisplayState(displays: [display], primaryDisplayID: 10)
        )

        XCTAssertEqual(plan.targetFrame, CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    func testRestorePlanKeepsMatchedDisplaysAndFallsBackMissingDisplayWhenDisplayCountShrinks() {
        let resolver = DisplayResolver()
        let savedPrimary = makeDisplayRecord(
            id: 1,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 860),
            isPrimary: true,
            vendorID: 1,
            productID: 10,
            serialNumber: 100
        )
        let savedSide = makeDisplayRecord(
            id: 2,
            localizedName: "Side",
            frame: CGRect(x: 1440, y: 0, width: 1200, height: 800),
            isPrimary: false,
            vendorID: 2,
            productID: 20,
            serialNumber: 200
        )
        let savedMissing = makeDisplayRecord(
            id: 3,
            localizedName: "Removed",
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 700),
            isPrimary: false,
            vendorID: 3,
            productID: 30,
            serialNumber: 300
        )
        let currentPrimary = makeDisplayRecord(
            id: 10,
            localizedName: "Built-in",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 860),
            isPrimary: true,
            vendorID: 1,
            productID: 10,
            serialNumber: 100
        )
        let currentSide = makeDisplayRecord(
            id: 20,
            localizedName: "Side",
            frame: CGRect(x: 1440, y: 0, width: 1200, height: 800),
            isPrimary: false,
            vendorID: 2,
            productID: 20,
            serialNumber: 200
        )
        let sourceDisplayState = DisplayState(
            displays: [savedPrimary, savedSide, savedMissing],
            primaryDisplayID: 1
        )
        let currentDisplayState = DisplayState(
            displays: [currentPrimary, currentSide],
            primaryDisplayID: 10
        )

        let primaryPlan = resolver.restorePlan(
            for: makeWindowRecord(
                displayID: 1,
                normalizedFrame: NormalizedRect(xRatio: 0.25, yRatio: 0.25, widthRatio: 0.5, heightRatio: 0.5)
            ),
            from: sourceDisplayState,
            to: currentDisplayState
        )
        let sidePlan = resolver.restorePlan(
            for: makeWindowRecord(
                displayID: 2,
                normalizedFrame: NormalizedRect(xRatio: 0.1, yRatio: 0.2, widthRatio: 0.4, heightRatio: 0.4)
            ),
            from: sourceDisplayState,
            to: currentDisplayState
        )
        let missingPlan = resolver.restorePlan(
            for: makeWindowRecord(
                displayID: 3,
                normalizedFrame: NormalizedRect(xRatio: 0.9, yRatio: 0.95, widthRatio: 0.5, heightRatio: 0.5)
            ),
            from: sourceDisplayState,
            to: currentDisplayState
        )

        XCTAssertEqual(primaryPlan.resolvedDisplayID, 10)
        XCTAssertEqual(primaryPlan.fallback?.reason, DisplayFallbackReason.hardwareMatch)
        XCTAssertEqual(sidePlan.resolvedDisplayID, 20)
        XCTAssertEqual(sidePlan.fallback?.reason, DisplayFallbackReason.hardwareMatch)
        XCTAssertEqual(missingPlan.resolvedDisplayID, 10)
        XCTAssertEqual(missingPlan.fallback?.reason, DisplayFallbackReason.primaryDisplay)
        XCTAssertEqual(missingPlan.targetFrame, CGRect(x: 720, y: 450, width: 720, height: 450))
        XCTAssertTrue(currentPrimary.visibleFrameRect.contains(missingPlan.targetFrame))
    }

    func testDisplayConfigurationMatcherMatchesExactHardwareConfigurationWhenIDsChange() {
        let matcher = DisplayConfigurationMatcher()
        let snapshot = makeSnapshot(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, vendorID: 1, productID: 2, serialNumber: 3),
                LayoutLockTests.makeDisplayRecord(id: 11, localizedName: "Side", frame: CGRect(x: 1000, y: 0, width: 800, height: 600), vendorID: 4, productID: 5, serialNumber: 6)
            ],
            windows: [LayoutLockTests.makeWindowRecord(displayID: 10)]
        )
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 20, vendorID: 1, productID: 2, serialNumber: 3),
                LayoutLockTests.makeDisplayRecord(id: 21, localizedName: "Side", frame: CGRect(x: 1000, y: 0, width: 800, height: 600), vendorID: 4, productID: 5, serialNumber: 6)
            ],
            primaryDisplayID: 20
        )

        let match = matcher.match(snapshot: snapshot, currentDisplayState: currentDisplayState)

        XCTAssertEqual(match?.snapshotID, snapshot.id)
        XCTAssertEqual(match?.reason, .hardwareIdentity)
    }

    func testDisplayConfigurationMatcherRejectsDisplayIDOnlyMatch() {
        let matcher = DisplayConfigurationMatcher()
        let snapshot = makeSnapshot(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, localizedName: nil)
            ]
        )
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, localizedName: nil)
            ],
            primaryDisplayID: 10
        )

        XCTAssertNil(matcher.match(snapshot: snapshot, currentDisplayState: currentDisplayState))
    }

    func testDisplayConfigurationMatcherRejectsPartialHardwareIdentity() {
        let matcher = DisplayConfigurationMatcher()
        let snapshot = makeSnapshot(
            displays: [
                LayoutLockTests.makeDisplayRecord(
                    id: 10,
                    localizedName: nil,
                    vendorID: 1,
                    productID: 2,
                    serialNumber: nil
                )
            ]
        )
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(
                    id: 20,
                    localizedName: nil,
                    vendorID: 1,
                    productID: 2,
                    serialNumber: nil
                )
            ],
            primaryDisplayID: 20
        )

        XCTAssertNil(matcher.match(snapshot: snapshot, currentDisplayState: currentDisplayState))
    }

    func testDisplayConfigurationMatcherFallsBackToUniqueNameSizeAndScale() {
        let matcher = DisplayConfigurationMatcher()
        let snapshot = makeSnapshot(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, localizedName: "Studio Display", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            ]
        )
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 20, localizedName: "Studio Display", frame: CGRect(x: 200, y: 0, width: 1000, height: 800))
            ],
            primaryDisplayID: 20
        )

        let match = matcher.match(snapshot: snapshot, currentDisplayState: currentDisplayState)

        XCTAssertEqual(match?.reason, .nameSizeScale)
    }

    func testDisplayConfigurationMatcherRejectsDisplayCountMismatch() {
        let matcher = DisplayConfigurationMatcher()
        let snapshot = makeSnapshot(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 1),
                LayoutLockTests.makeDisplayRecord(id: 2, localizedName: "Side", frame: CGRect(x: 1000, y: 0, width: 800, height: 600))
            ]
        )
        let currentDisplayState = DisplayState(
            displays: [LayoutLockTests.makeDisplayRecord(id: 1)],
            primaryDisplayID: 1
        )

        XCTAssertNil(matcher.match(snapshot: snapshot, currentDisplayState: currentDisplayState))
    }

    func testDisplayConfigurationMatcherRejectsAmbiguousMultipleLayoutMatches() {
        let matcher = DisplayConfigurationMatcher()
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 20, vendorID: 1, productID: 2, serialNumber: 3)
            ],
            primaryDisplayID: 20
        )
        let firstSnapshot = makeSnapshot(
            name: "Desk",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, vendorID: 1, productID: 2, serialNumber: 3)
            ]
        )
        let secondSnapshot = makeSnapshot(
            name: "Focus",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 11, vendorID: 1, productID: 2, serialNumber: 3)
            ]
        )

        XCTAssertNil(matcher.uniqueMatch(
            among: [firstSnapshot, secondSnapshot],
            currentDisplayState: currentDisplayState
        ))
    }

    func testDisplayConfigurationMatcherReturnsMultipleLayoutMatchesInInputOrder() {
        let matcher = DisplayConfigurationMatcher()
        let currentDisplayState = DisplayState(
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 20, vendorID: 1, productID: 2, serialNumber: 3)
            ],
            primaryDisplayID: 20
        )
        let firstSnapshot = makeSnapshot(
            name: "Newest",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 10, vendorID: 1, productID: 2, serialNumber: 3)
            ]
        )
        let secondSnapshot = makeSnapshot(
            name: "Older",
            displays: [
                LayoutLockTests.makeDisplayRecord(id: 11, vendorID: 1, productID: 2, serialNumber: 3)
            ]
        )

        let matches = matcher.matches(
            among: [firstSnapshot, secondSnapshot],
            currentDisplayState: currentDisplayState
        )

        XCTAssertEqual(matches.map(\.snapshotID), [firstSnapshot.id, secondSnapshot.id])
    }

    private func makeDisplayRecord(
        id: UInt32,
        localizedName: String? = nil,
        frame: CGRect,
        visibleFrame: CGRect? = nil,
        isPrimary: Bool? = nil,
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        serialNumber: UInt32? = nil
    ) -> DisplayRecord {
        DisplayRecord(
            id: id,
            localizedName: localizedName,
            frame: CGRectCodable(frame),
            visibleFrame: CGRectCodable(visibleFrame ?? frame),
            backingScaleFactor: 2,
            isPrimary: isPrimary ?? (id == 1),
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    private func makeWindowRecord(
        displayID: UInt32?,
        normalizedFrame: NormalizedRect,
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)
    ) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: "com.example.app",
            pidAtCapture: 42,
            windowTitle: "Window",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRectCodable(frame),
            displayID: displayID,
            normalizedFrame: normalizedFrame,
            zOrderHint: nil,
            isMinimized: false,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: "com.example.app",
                owningPid: 42,
                windowTitle: "Window",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                capturedFrame: CGRectCodable(frame),
                cgWindowID: nil
            )
        )
    }

    private func makeThreeMonitorScreensInAppKitCoordinates() -> [DisplayResolver.ScreenSnapshot] {
        [
            makeScreenSnapshot(
                id: 3,
                localizedName: "S27C900P",
                frame: CGRect(x: -1759, y: 982, width: 2560, height: 1440),
                visibleFrame: CGRect(x: -1759, y: 982, width: 2560, height: 1415),
                backingScaleFactor: 2,
                isPrimary: false,
                vendorID: 19501,
                productID: 29589,
                serialNumber: 1536
            ),
            makeScreenSnapshot(
                id: 1,
                localizedName: "Built-in Retina Display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                backingScaleFactor: 2,
                isPrimary: true,
                vendorID: 1552,
                productID: 41039,
                serialNumber: 4_251_086_178
            ),
            makeScreenSnapshot(
                id: 2,
                localizedName: "MSI MP271Q",
                frame: CGRect(x: 801, y: 982, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 801, y: 982, width: 2560, height: 1415),
                backingScaleFactor: 1,
                isPrimary: false,
                vendorID: 13929,
                productID: 12451,
                serialNumber: 183
            )
        ]
    }

    private func makeScreenSnapshot(
        id: UInt32,
        localizedName: String?,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: Double,
        isPrimary: Bool,
        vendorID: UInt32?,
        productID: UInt32?,
        serialNumber: UInt32?
    ) -> DisplayResolver.ScreenSnapshot {
        .init(
            id: id,
            localizedName: localizedName,
            frame: frame,
            visibleFrame: visibleFrame,
            backingScaleFactor: backingScaleFactor,
            isPrimary: isPrimary,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }
}
