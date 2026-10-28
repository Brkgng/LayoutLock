import AppKit
import ApplicationServices
import XCTest

@testable import LayoutLock

final class RestoreSpacesTests: XCTestCase {
    func testVisibleWindowOnUnchangedDisplayCanRestoreWithoutActivatingAfterAnotherDisplayChanges() async {
        let initial = RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 22, 23])
        var moveCount = 0
        let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
            inventory: { ids in RestoreSpaceInventory(
                activeByDisplay: [UInt32(1): UInt64(10), 2: 23].filter { ids.contains($0.key) },
                ordinarySpaceIDs: [10, 22, 23]) },
            membership: { _ in [10] },
            submitMove: { _, _ in moveCount += 1; return true },
            applicationWindowIDs: { _ in [7] }
        ))

        let result = await spaces.prepare(windowID: 7, displayID: 1, inventory: initial, ordinaryWindow: true)

        XCTAssertEqual(result, .alreadyVisible)
        XCTAssertEqual(moveCount, 0)
        // Geometry on this display is safe, while focus and stacking retain the global guard.
        XCTAssertFalse(spaces.canStack(window: window(), displayID: 1, inventory: initial))
        XCTAssertFalse(spaces.canActivate(windowID: 7, processIdentifier: 42, inventory: initial))
    }

    func testVisibleWindowStillRequiresItsOwnDisplayAndAnOrdinaryDestination() async {
        let initial = RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 11, 22])
        let current: [RestoreSpaceInventory?] = [
            RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 22], ordinarySpaceIDs: [10, 11, 22]),
            RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [11, 22]),
            nil
        ]
        for inventory in current {
            let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
                inventory: { _ in inventory }, membership: { _ in [10] },
                submitMove: { _, _ in XCTFail("An unconfirmed desktop must never submit a move"); return false }
            ))

            let result = await spaces.prepare(windowID: 7, displayID: 1, inventory: initial, ordinaryWindow: true)

            XCTAssertEqual(result, .unconfirmed)
        }
    }

    func testCrossSpaceMoveRemainsBlockedWhenAnotherDisplayChanges() async {
        let initial = RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 22, 23, 33])
        let spaces = RestoreSpaceCoordinator(access: RestoreSpaceAccess(
            inventory: { ids in RestoreSpaceInventory(
                activeByDisplay: [UInt32(1): UInt64(10), 2: 23].filter { ids.contains($0.key) },
                ordinarySpaceIDs: [10, 22, 23, 33]) },
            membership: { _ in [33] },
            submitMove: { _, _ in XCTFail("A cross-Space move must retain the full desktop guard"); return false }
        ))

        let result = await spaces.prepare(windowID: 7, displayID: 1, inventory: initial, ordinaryWindow: true)

        XCTAssertEqual(result, .unconfirmed)
    }

    private let inventory = RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 22], ordinarySpaceIDs: [10, 11, 22])

    func testAlreadyVisibleDoesNotSubmitMove() async {
        var submissions = 0
        let coordinator = coordinator(
            membership: { _ in [22] },
            move: { _, _ in
                submissions += 1
                return true
            })
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: true)
        XCTAssertEqual(outcome, .alreadyVisible)
        XCTAssertEqual(submissions, 0)
    }

    func testMoveWaitsForActualMembership() async {
        var membership: Set<UInt64> = [10]
        var submissions: [UInt64] = []
        var waits = 0
        var coordinator = coordinator(
            membership: { _ in membership },
            move: { _, target in
                submissions.append(target)
                return true
            })
        coordinator.sleeper = {
            waits += 1
            membership = [22]
        }
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: true)
        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(submissions, [22])
        XCTAssertEqual(waits, 1)
    }

    func testUnchangedMembershipHasBoundedFailureAndNoRetry() async {
        var submissions = 0
        var waits = 0
        var coordinator = coordinator(
            membership: { _ in [10] },
            move: { _, _ in
                submissions += 1
                return true
            })
        coordinator.sleeper = { waits += 1 }
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: true)
        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertFalse(outcome.permitsGeometry)
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(waits, 39)
    }

    func testUnavailableCapabilityPermitsGeometryFallback() async {
        let coordinator = RestoreSpaceCoordinator(access: .unavailable)
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: nil, ordinaryWindow: true)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(outcome.permitsGeometry)
    }

    func testFullscreenStickyAndUnknownMembershipAreNotGathered() async {
        for membership: Set<UInt64> in [[99], [10, 11], []] {
            var submissions = 0
            let coordinator = coordinator(
                membership: { _ in membership },
                move: { _, _ in
                    submissions += 1
                    return true
                })
            let outcome = await coordinator.prepare(
                windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: true)
            XCTAssertEqual(outcome, .ineligible)
            XCTAssertEqual(submissions, 0)
        }
    }

    func testNonordinaryAXWindowIsNotGathered() async {
        var submissions = 0
        let coordinator = coordinator(
            membership: { _ in [10] },
            move: { _, _ in
                submissions += 1
                return true
            })
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: false)
        XCTAssertEqual(outcome, .ineligible)
        XCTAssertEqual(submissions, 0)
    }

    func testVisibleDesktopChangePreventsMove() async {
        var submissions = 0
        var coordinator = coordinator(
            membership: { _ in [10] },
            move: { _, _ in
                submissions += 1
                return true
            })
        coordinator = RestoreSpaceCoordinator(
            access: RestoreSpaceAccess(
                inventory: { _ in
                    RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 11, 22])
                },
                membership: coordinator.access.membership,
                submitMove: coordinator.access.submitMove
            ))
        let outcome = await coordinator.prepare(windowID: 7, displayID: 2, inventory: inventory, ordinaryWindow: true)
        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertEqual(submissions, 0)
    }

    func testMembershipMustBeConfirmedBeforeStacking() {
        let coordinator = coordinator(membership: { _ in [10] })
        XCTAssertFalse(coordinator.canStack(window: window(), displayID: 2, inventory: inventory))
        XCTAssertTrue(coordinator.canStack(window: window(), displayID: 2, inventory: nil))
        XCTAssertFalse(coordinator.canStack(window: window(onScreen: false), displayID: 2, inventory: nil))
        XCTAssertFalse(coordinator.canStack(window: window(id: nil), displayID: 2, inventory: nil))
        XCTAssertFalse(coordinator.canStack(window: window(id: nil), displayID: 2, inventory: inventory))
    }

    func testDiscoveryAndRestoreMoveOnlyIdentifiedSiblingWithIdenticalBoundsAndMissingCGTitles() async throws {
        let fixture = siblingDiscovery()
        var memberships: [CGWindowID: Set<UInt64>] = [7: [10], 8: [22]]
        var movedIDs: [CGWindowID] = []
        let applier = SpaceTestApplier()
        let spaces = coordinator(membership: { memberships[$0] }, move: { id, destination in
            movedIDs.append(id)
            memberships[id] = [destination]
            return true
        })
        let result = try await restore(
            saved: makeWindowRecord(windowTitle: "Target", displayID: 2, zOrderHint: 0),
            spaces: spaces, applier: applier
        ) { try fixture.engine.discoverRunningWindowsWithDiagnostics() }

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(movedIDs, [7])
        XCTAssertEqual(memberships[8], [22], "The sibling must stay untouched.")
        XCTAssertEqual(applier.appliedWindowIDs, [7])
        XCTAssertTrue(CFEqual(try XCTUnwrap(applier.appliedElements.first), fixture.target))
        XCTAssertEqual(applier.raisedWindowIDs, [7])
        XCTAssertTrue(spaces.destinationsAreUnchanged(inventory))
    }

    func testUnresolvedOrWrongOwnerIdentityKeepsGeometryWithoutMovingOrForegrounding() async throws {
        for fixture in [siblingDiscovery(resolvesIdentity: false), siblingDiscovery(ownerPID: 99)] {
            let discovery = try fixture.engine.discoverRunningWindowsWithDiagnostics()
            XCTAssertTrue(discovery.applications.flatMap(\.windows).allSatisfy { $0.cgWindowID == nil })
            let applier = SpaceTestApplier()
            let spaces = coordinator(membership: { _ in [22] }, move: { _, _ in
                XCTFail("An unconfirmed identity must not authorize a move")
                return false
            }, applicationWindowIDs: { _ in [7, 8] })
            let result = try await restore(
                saved: makeWindowRecord(windowTitle: "Target", displayID: 2, zOrderHint: 0),
                spaces: spaces, applier: applier
            ) { discovery }
            XCTAssertEqual(result.restoredWindows, 1)
            XCTAssertEqual(applier.appliedCount, 1)
            XCTAssertTrue(CFEqual(try XCTUnwrap(applier.appliedElements.first), fixture.target))
            XCTAssertEqual(applier.focusCount, 0)
            XCTAssertEqual(applier.raiseCount, 0)
            XCTAssertEqual(result.downgradedItems.map(\.reason), [RestoreDowngradeReason.windowIdentityUnconfirmed])
            XCTAssertEqual(result.windowDiagnostics.first?.reason, RestoreDowngradeReason.windowIdentityUnconfirmed)
        }
    }

    func testActivationAllowsOnlyCapturedVisibleSpacesAndIgnoresSpaceLessPseudoWindows() {
        let spaces = coordinator(
            membership: { id in
                switch id {
                case 7: return [22]
                case 8: return [11]
                default: return []
                }
            },
            applicationWindowIDs: { pid in
                XCTAssertEqual(pid, 42)
                return [7, 8, 9]
            })
        XCTAssertTrue(spaces.canActivate(windowID: 7, processIdentifier: 42, inventory: inventory))
    }

    func testActivationBlocksOffSpaceFullscreenStickyAndUnknownSiblingMembership() {
        let unsafeMemberships: [Set<UInt64>?] = [[10], [99], [11, 22], nil]
        for sibling in unsafeMemberships {
            let spaces = coordinator(membership: { $0 == 7 ? [22] : sibling }, applicationWindowIDs: { _ in [7, 8] })
            XCTAssertFalse(spaces.canActivate(windowID: 7, processIdentifier: 42, inventory: inventory))
        }
    }

    func testActivationRequiresFreshInventoryContainingTheRealTarget() {
        let inventories: [[CGWindowID]?] = [nil, [], [8]]
        for ids in inventories {
            let spaces = coordinator(membership: { _ in [22] }, applicationWindowIDs: { _ in ids })
            XCTAssertFalse(spaces.canActivate(windowID: 7, processIdentifier: 42, inventory: inventory))
        }
        let pseudoTarget = coordinator(membership: { _ in [] }, applicationWindowIDs: { _ in [7] })
        XCTAssertFalse(pseudoTarget.canActivate(windowID: 7, processIdentifier: 42, inventory: inventory))
        XCTAssertFalse(pseudoTarget.canActivate(windowID: 7, processIdentifier: 42, inventory: nil))
    }

    func testActivationRejectsDesktopChangesDuringFreshInventoryCheck() {
        var checks = 0
        let spaces = RestoreSpaceCoordinator(
            access: RestoreSpaceAccess(
                inventory: { _ in
                    checks += 1
                    return checks == 1
                        ? self.inventory
                        : RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 11, 22])
                },
                membership: { _ in [22] },
                submitMove: { _, _ in
                    XCTFail("Unexpected move")
                    return false
                },
                applicationWindowIDs: { _ in [7] }
            ))
        XCTAssertFalse(spaces.canActivate(windowID: 7, processIdentifier: 42, inventory: inventory))
        XCTAssertEqual(checks, 2)
    }

    func testFreshApplicationWindowInventoryIncludesFloatingPanelsAndPreservesFailure() {
        let reader = CGWindowMetadataReader(windowListProvider: { options in
            XCTAssertEqual(options, .optionAll)
            return [
                [kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 7, kCGWindowLayer as String: 0],
                [kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 8, kCGWindowLayer as String: 3],
                [kCGWindowOwnerPID as String: 99, kCGWindowNumber as String: 9],
            ]
        })
        XCTAssertEqual(reader.readWindowIDs(processIdentifier: 42), [7, 8])
        XCTAssertNil(CGWindowMetadataReader(windowListProvider: { _ in nil }).readWindowIDs(processIdentifier: 42))
        XCTAssertNil(
            CGWindowMetadataReader(windowListProvider: { _ in
                [[kCGWindowOwnerPID as String: 42]]
            }).readWindowIDs(processIdentifier: 42))
    }

    func testUniqueCGTitleRecoversUsingCurrentProcessAndID() {
        let saved = makeWindowRecord(pidAtCapture: 5, cgWindowID: 100)
        let candidate = recovery().candidate(
            for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 7)])])
        XCTAssertEqual(candidate?.pid, 42)
        XCTAssertEqual(candidate?.window.windowID, 7)
    }

    func testDuplicateCurrentAndSavedTitlesStayUnresolved() {
        let saved = makeWindowRecord()
        let recovery = self.recovery()
        XCTAssertNil(
            recovery.candidate(
                for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 7), metadata(id: 8)])]))
        XCTAssertNil(
            recovery.candidate(
                for: saved, savedWindows: [saved, makeWindowRecord()], applications: [unexposed([metadata(id: 7)])]))
    }

    func testUniqueTitlesRecoverMultipleSavedWindowsAcrossCurrentProcesses() {
        let saved = ["Alpha", "Beta", "Gamma"].enumerated().map {
            makeWindowRecord(pidAtCapture: Int32($0.offset + 1), windowTitle: $0.element,
                             cgWindowID: UInt32(100 + $0.offset))
        }
        let owners = saved.enumerated().reversed().map { index, record in
            UnexposedApplicationWindows(bundleIdentifier: record.bundleIdentifier, pid: Int32(50 + index),
                windows: [metadata(id: UInt32(7 + index), title: record.windowTitle, pid: Int32(50 + index))])
        }

        for (index, record) in saved.enumerated() {
            let candidate = recovery().candidate(for: record, savedWindows: saved, applications: owners)
            XCTAssertEqual(candidate?.pid, Int32(50 + index))
            XCTAssertEqual(candidate?.window.windowID, UInt32(7 + index))
        }
    }

    func testUniqueTitlesRecoverMultipleWindowsWithinOneCurrentProcess() {
        let saved = ["Alpha", "Beta"].map { makeWindowRecord(pidAtCapture: 5, windowTitle: $0) }
        let owner = unexposed([metadata(id: 8, title: "Beta"), metadata(id: 7, title: "Alpha")])

        XCTAssertEqual(recovery().candidate(for: saved[0], savedWindows: saved,
                                            applications: [owner])?.window.windowID, 7)
        XCTAssertEqual(recovery().candidate(for: saved[1], savedWindows: saved,
                                            applications: [owner])?.window.windowID, 8)
    }

    func testDuplicateTitleAcrossCurrentProcessesDoesNotRecoverEitherWindow() {
        let saved = makeWindowRecord(windowTitle: "Project")
        let owners = [42, 43].map { pid in
            UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: Int32(pid),
                windows: [metadata(id: UInt32(pid), title: "Project", pid: Int32(pid))])
        }
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: owners))
    }

    func testUniqueProcessResourceRecoversTitlelessWindowAmongMultipleSavedProjects() {
        let targets = ["Alpha", "Beta"].map {
            WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/\($0)", isDirectory: true))
        }
        let saved = targets.map {
            makeWindowRecord(windowTitle: nil,
                openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [$0]))
        }
        let owners = targets.enumerated().map { index, target in
            UnexposedApplicationWindows(bundleIdentifier: saved[index].bundleIdentifier, pid: Int32(50 + index),
                windows: [metadata(id: UInt32(7 + index), title: nil, pid: Int32(50 + index))],
                documentURLs: [target.url])
        }

        for index in saved.indices {
            let candidate = recovery().candidate(for: saved[index], savedWindows: saved, applications: owners)
            XCTAssertEqual(candidate?.pid, Int32(50 + index))
            XCTAssertEqual(candidate?.window.windowID, UInt32(7 + index))
        }
    }

    func testKnownProjectContextExcludesAnotherProjectsTitleAndSoleWindow() {
        let target = WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Expected", isDirectory: true))
        let saved = makeWindowRecord(openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        for title in [saved.windowTitle, nil] {
            let owner = UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: 42,
                windows: [metadata(id: 7, title: title)],
                documentURLs: [URL(fileURLWithPath: "/Projects/Other", isDirectory: true)])
            XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: [owner]))
        }
    }

    func testDuplicateProcessOrSavedResourcesDoNotDisambiguateTitlelessWindows() {
        let target = WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Shared", isDirectory: true))
        let saved = makeWindowRecord(windowTitle: nil,
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        let owners = [42, 43].map { pid in
            UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: Int32(pid),
                windows: [metadata(id: UInt32(pid), title: nil, pid: Int32(pid))], documentURLs: [target.url])
        }
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: owners))
        let duplicateSaved = makeWindowRecord(windowTitle: nil,
            openingConfiguration: saved.openingConfiguration)
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved, duplicateSaved], applications: [owners[0]]))
    }

    func testOwnersWithoutOrdinaryCGWindowsDoNotMakeRecoveryAmbiguous() {
        let saved = makeWindowRecord()
        let owner = unexposed([metadata(id: 7)])
        let emptyHelper = UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: 43, windows: [])
        let spacelessHelper = UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: 44,
            windows: [metadata(id: 8, pid: 44)])
        let candidate = recovery(membership: { $0 == 7 ? [10] : [] }).candidate(
            for: saved, savedWindows: [saved], applications: [emptyHelper, spacelessHelper, owner])
        XCTAssertEqual(candidate?.pid, 42)
        XCTAssertEqual(candidate?.window.windowID, 7)
    }

    func testCoreGraphicsSourcePermitsUnknownSubroleButNotCapturedAXDialog() {
        let frame = CGRectCodable(TestFixtures.windowFrame)
        let saved = WindowRecord(bundleIdentifier: TestFixtures.bundleIdentifier, pidAtCapture: 5,
            windowTitle: "Window", role: "AXWindow", subrole: nil, frame: frame, displayID: 1,
            normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 0.5, heightRatio: 0.5),
            zOrderHint: nil, isMinimized: false, isFullscreen: false, isVisible: true,
            captureSignature: WindowSignature(bundleIdentifier: TestFixtures.bundleIdentifier, owningPid: 5,
                windowTitle: "Window", role: "AXWindow", subrole: nil, capturedFrame: frame,
                cgWindowID: 100, source: .coreGraphics))
        XCTAssertEqual(recovery().candidate(for: saved, savedWindows: [saved],
                                            applications: [unexposed([metadata(id: 7)])])?.window.windowID, 7)
        for subrole: String? in [nil, "AXDialog"] {
            let axSaved = makeWindowRecord(subrole: subrole)
            XCTAssertNil(recovery().candidate(for: axSaved, savedWindows: [axSaved],
                                              applications: [unexposed([metadata(id: 7)])]))
        }
    }

    func testRecoveryUsesCurrentCandidateRatherThanSavedIDOrPID() {
        let saved = makeWindowRecord(pidAtCapture: 5, windowTitle: "Old", cgWindowID: 7)
        var queriedIDs: [CGWindowID] = []
        let recovery = self.recovery(membership: { windowID in
            queriedIDs.append(windowID)
            return [10]
        })
        let candidate = recovery.candidate(
            for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 8, title: "Changed")])])
        XCTAssertEqual(candidate?.pid, 42)
        XCTAssertEqual(candidate?.window.windowID, 8)
        XCTAssertEqual(queriedIDs, [8])
        let wrongOwner = CGWindowMetadata(
            windowID: 7, processIdentifier: 99, ownerName: nil, layer: 0, bounds: TestFixtures.windowFrame,
            title: "Old", isOnScreen: false, zOrderHint: nil)
        XCTAssertNil(recovery.candidate(for: saved, savedWindows: [saved], applications: [unexposed([wrongOwner])]))
        XCTAssertEqual(queriedIDs, [8])
    }

    func testUniqueOrdinaryCGWindowRecoversWithoutAvailableOrUnchangedTitle() {
        for title: String? in [nil, "Changed"] {
            let saved = makeWindowRecord()
            let candidate = recovery().candidate(
                for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 7, title: title)])])
            XCTAssertEqual(candidate?.window.windowID, 7)
        }
    }

    func testMultipleOrdinaryCGWindowsWithoutExactTitleStayUnresolved() {
        let saved = makeWindowRecord()
        XCTAssertNil(
            recovery().candidate(
                for: saved, savedWindows: [saved],
                applications: [
                    unexposed([
                        metadata(id: 7, title: nil), metadata(id: 8, title: "Changed"),
                    ])
                ]))
    }

    func testRecoveryPrefersUniqueExactTitleAmongOrdinaryWindows() {
        let saved = makeWindowRecord()
        let candidate = recovery().candidate(
            for: saved, savedWindows: [saved],
            applications: [
                unexposed([
                    metadata(id: 7, title: "Changed"), metadata(id: 8),
                ])
            ])
        XCTAssertEqual(candidate?.window.windowID, 8)
    }

    func testRecoveryExcludesPseudoFullscreenAndMultipleSpaceWindows() {
        let saved = makeWindowRecord()
        let recovery = self.recovery(membership: { windowID in
            switch windowID {
            case 7: return []
            case 8: return [99]
            case 9: return [10, 11]
            case 10: return [10]
            default: return nil
            }
        })
        let candidate = recovery.candidate(
            for: saved, savedWindows: [saved],
            applications: [
                unexposed([
                    metadata(id: 7), metadata(id: 8), metadata(id: 9), metadata(id: 10, title: nil),
                ])
            ])
        XCTAssertEqual(candidate?.window.windowID, 10)
    }

    func testAutomaticLocalTargetsPermitUniqueOrSoleTitlelessCGInspection() {
        let target = WindowOpenTarget(kind: .folder, url: URL(fileURLWithPath: "/Projects/Workspace", isDirectory: true))
        let saved = makeWindowRecord(openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        XCTAssertTrue(RestoreCGWindowRecovery.requiresLocalTargetInspection(for: saved))
        let titleMatched = recovery().candidate(for: saved, savedWindows: [saved], applications: [
            unexposed([metadata(id: 7, title: "Other"), metadata(id: 8)])
        ])
        XCTAssertEqual(titleMatched?.window.windowID, 8)
        let soleTitleless = recovery().candidate(for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 9, title: nil)])])
        XCTAssertEqual(soleTitleless?.window.windowID, 9)
    }

    func testLocalInspectionExcludesManualRetargetMixedTargetsBrowsersAndInvalidLocalURLs() {
        let target = WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/Original.txt"))
        let other = WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/Retargeted.txt"))
        let web = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com")!)
        let cases: [(String, WindowOpeningConfiguration)] = [
            (TestFixtures.bundleIdentifier, WindowOpeningConfiguration(automaticallyCapturedTargets: [target], manualTargets: [other])),
            (TestFixtures.bundleIdentifier, WindowOpeningConfiguration(automaticallyCapturedTargets: [target, web])),
            (TestFixtures.bundleIdentifier, WindowOpeningConfiguration(automaticallyCapturedTargets: [WindowOpenTarget(kind: .file, url: web.url)])),
            (BrowserAutomationBrowser.chrome.bundleIdentifier, WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        ]
        for (bundle, configuration) in cases {
            let saved = makeWindowRecord(bundleIdentifier: bundle, openingConfiguration: configuration)
            XCTAssertFalse(RestoreCGWindowRecovery.requiresLocalTargetInspection(for: saved))
            let owner = UnexposedApplicationWindows(bundleIdentifier: bundle, pid: 42, windows: [metadata(id: 7)])
            XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: [owner]))
        }
    }

    func testAutomaticLocalInspectionRejectsMultipleOwnersAndSavedWindowAmbiguity() {
        let target = WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/Document.txt"))
        let saved = makeWindowRecord(openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        let owner = unexposed([metadata(id: 7)])
        let siblingOwner = UnexposedApplicationWindows(bundleIdentifier: saved.bundleIdentifier, pid: 43, windows: [metadata(id: 8, pid: 43)])
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: [owner, siblingOwner]))
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved, makeWindowRecord()], applications: [owner]))
        XCTAssertNil(recovery().candidate(for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 7), metadata(id: 8)])]))
    }

    func testAutomaticLocalInspectionKeepsFullscreenAndStickyWindowsExcluded() {
        let target = WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/Document.txt"))
        let configuration = WindowOpeningConfiguration(automaticallyCapturedTargets: [target])
        let fullscreen = makeWindowRecord(isFullscreen: true, openingConfiguration: configuration)
        XCTAssertNil(recovery().candidate(for: fullscreen, savedWindows: [fullscreen], applications: [unexposed([metadata(id: 7)])]))
        let saved = makeWindowRecord(openingConfiguration: configuration)
        for membership: Set<UInt64> in [[99], [10, 11], []] {
            XCTAssertNil(recovery(membership: { _ in membership }).candidate(
                for: saved, savedWindows: [saved], applications: [unexposed([metadata(id: 7)])]))
        }
    }

    func testInspectionCapturesOnlyFreshOwnerValidatedSourceAndFrame() throws {
        let current = metadata(id: 7)
        let spaces = coordinator(membership: { _ in [10] }, windowMetadata: { pid, id in
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(id, 7)
            return current
        })
        let token = try XCTUnwrap(spaces.inspection(for: current, pid: 42, displayID: 2, inventory: inventory))
        XCTAssertEqual(token.pid, 42)
        XCTAssertEqual(token.windowID, 7)
        XCTAssertEqual(token.sourceSpaceID, 10)
        XCTAssertEqual(token.destinationSpaceID, 22)
        XCTAssertEqual(token.originalFrame, current.bounds)
    }

    func testInspectionRejectsChangedOwnerFrameIdentityMembershipAndDesktopContext() {
        let original = metadata(id: 7)
        let changedMap = RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 11], ordinarySpaceIDs: [10, 11, 22])
        let cases: [(String, CGWindowMetadata?, Set<UInt64>?, RestoreSpaceInventory)] = [
            ("missing metadata", nil, [10], inventory),
            ("owner", metadata(id: 7, pid: 99), [10], inventory),
            ("identity", metadata(id: 8), [10], inventory),
            ("frame", metadata(id: 7, frame: TestFixtures.windowFrame.offsetBy(dx: 20, dy: 0)), [10], inventory),
            ("layer", metadata(id: 7, layer: 3), [10], inventory),
            ("invalid bounds", metadata(id: 7, frame: .zero), [10], inventory),
            ("unknown membership", original, nil, inventory),
            ("fullscreen", original, [99], inventory),
            ("sticky", original, [10, 11], inventory),
            ("already destination", original, [22], inventory),
            ("desktop changed", original, [10], changedMap)
        ]
        for (name, fresh, membership, currentInventory) in cases {
            let spaces = coordinator(membership: { _ in membership }, windowMetadata: { _, _ in fresh },
                                     inventoryProvider: { _ in currentInventory })
            XCTAssertNil(spaces.inspection(for: original, pid: 42, displayID: 2, inventory: inventory), name)
        }
        let spaces = coordinator(membership: { _ in [10] }, windowMetadata: { _, _ in original })
        XCTAssertNil(spaces.inspection(for: original, pid: 99, displayID: 2, inventory: inventory))
        XCTAssertNil(spaces.inspection(for: original, pid: 42, displayID: 9, inventory: inventory))
        XCTAssertNil(spaces.inspection(for: original, pid: 42, displayID: nil, inventory: inventory))
    }

    func testPrepareRejectsChangedExpectedSourceBeforeAnyMove() async {
        for membership: Set<UInt64> in [[11], [22]] {
            var submissions = 0
            let spaces = coordinator(membership: { _ in membership }, move: { _, _ in submissions += 1; return true })
            let result = await spaces.prepare(windowID: 7, displayID: 2, inventory: inventory,
                                              ordinaryWindow: true, expectedSourceSpace: 10)
            XCTAssertEqual(result, .ineligible)
            XCTAssertEqual(submissions, 0)
        }
    }

    func testInspectionSettlingUsesStableFrameAfterEarlyWindowServerGeometryChanges() async {
        let finalFrame = TestFixtures.windowFrame.offsetBy(dx: 80, dy: 40)
        var waits = 0
        var spaces = coordinator(membership: { _ in [22] }, windowMetadata: { _, _ in
            let frame = waits < 2 ? TestFixtures.windowFrame : (waits < 8 ? TestFixtures.windowFrame.offsetBy(dx: 40, dy: 20) : finalFrame)
            return self.metadata(id: 7, frame: frame)
        })
        spaces.sleeper = { waits += 1 }

        let settled = await spaces.settledWindow(windowID: 7, pid: 42, inSpace: 22, inventory: inventory)

        XCTAssertEqual(settled?.bounds, finalFrame)
        XCTAssertEqual(settled?.processIdentifier, 42)
    }

    func testInspectionSettlingAbortsOwnerMembershipAndDesktopChanges() async {
        for change in ["owner", "membership", "desktop"] {
            var changed = false
            var spaces = coordinator(membership: { _ in changed && change == "membership" ? [11] : [22] },
                                     windowMetadata: { _, _ in self.metadata(id: 7, pid: changed && change == "owner" ? 99 : 42) },
                                     inventoryProvider: { _ in
                                         changed && change == "desktop"
                                             ? RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 11], ordinarySpaceIDs: [10, 11, 22]) : self.inventory
                                     })
            spaces.sleeper = { changed = true }

            let settled = await spaces.settledWindow(windowID: 7, pid: 42, inSpace: 22, inventory: inventory)

            XCTAssertNil(settled, change)
        }
    }

    func testInspectionSettlingBoundsContinuouslyChangingGeometryWithoutMoving() async {
        var waits = 0
        var spaces = coordinator(membership: { _ in [22] }, move: { _, _ in XCTFail("Settling must not submit a move"); return false },
                                 windowMetadata: { _, _ in self.metadata(id: 7, frame: TestFixtures.windowFrame.offsetBy(dx: CGFloat(waits * 10), dy: 0)) })
        spaces.sleeper = { waits += 1 }

        let settled = await spaces.settledWindow(windowID: 7, pid: 42, inSpace: 22, inventory: inventory)

        XCTAssertNil(settled)
        XCTAssertGreaterThan(waits, 0)
        XCTAssertLessThan(waits, 100, "Unsettled geometry must have a bounded wait")
    }

    func testInspectionReturnSubmitsOnceToOriginalSourceAndConfirmsMembership() async {
        let token = inspectionToken()
        let inspectedFrame = TestFixtures.windowFrame.offsetBy(dx: 40, dy: 20)
        var membership: Set<UInt64> = [22]
        var submissions: [UInt64] = []
        let spaces = coordinator(membership: { _ in membership }, move: { id, destination in
            XCTAssertEqual(id, 7)
            submissions.append(destination)
            membership = [destination]
            return true
        }, windowMetadata: { _, _ in self.metadata(id: 7, frame: membership == [22] ? inspectedFrame : token.originalFrame) })

        let returned = await spaces.returnWindow(token, expectedFrame: inspectedFrame, inventory: inventory)

        XCTAssertTrue(returned)
        XCTAssertEqual(submissions, [10])
        XCTAssertEqual(membership, [10])
    }

    func testInspectionReturnAlreadyAtOriginalFrameAndSourceDoesNotResubmit() async {
        var submissions = 0
        let spaces = coordinator(membership: { _ in [10] }, move: { _, _ in submissions += 1; return true },
                                 windowMetadata: { _, _ in self.metadata(id: 7) })

        let returned = await spaces.returnWindow(inspectionToken(), expectedFrame: TestFixtures.windowFrame.offsetBy(dx: 40, dy: 20), inventory: inventory)

        XCTAssertTrue(returned)
        XCTAssertEqual(submissions, 0)
    }

    func testInspectionReturnRejectsChangedFrameOwnerSourceAndDesktopWithoutSubmitting() async {
        let expectedFrame = TestFixtures.windowFrame.offsetBy(dx: 40, dy: 20)
        let expected = metadata(id: 7, frame: expectedFrame)
        let sourceGone = RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 22], ordinarySpaceIDs: [11, 22])
        let changedMap = RestoreSpaceInventory(activeByDisplay: [1: 11, 2: 11], ordinarySpaceIDs: [10, 11, 22])
        let cases: [(String, CGWindowMetadata, Set<UInt64>, RestoreSpaceInventory)] = [
            ("changed frame", metadata(id: 7, frame: expectedFrame.offsetBy(dx: 10, dy: 0)), [22], inventory),
            ("changed owner", metadata(id: 7, pid: 99, frame: expectedFrame), [22], inventory),
            ("different source", expected, [11], inventory),
            ("original source gone", expected, [22], sourceGone),
            ("desktop changed", expected, [22], changedMap),
            ("already source but wrong frame", expected, [10], inventory)
        ]
        for (name, current, membership, currentInventory) in cases {
            var submissions = 0
            let spaces = coordinator(membership: { _ in membership }, move: { _, _ in submissions += 1; return true },
                                     windowMetadata: { _, _ in current }, inventoryProvider: { _ in currentInventory })

            let returned = await spaces.returnWindow(inspectionToken(), expectedFrame: expectedFrame, inventory: inventory)

            XCTAssertFalse(returned, name)
            XCTAssertEqual(submissions, 0, name)
        }
    }

    func testInspectionReturnMembershipTimeoutIsBoundedAndNeverResubmits() async {
        var submissions = 0
        var waits = 0
        var spaces = coordinator(membership: { _ in [22] }, move: { _, _ in submissions += 1; return true },
                                 windowMetadata: { _, _ in self.metadata(id: 7) })
        spaces.sleeper = { waits += 1 }

        let returned = await spaces.returnWindow(inspectionToken(), expectedFrame: TestFixtures.windowFrame, inventory: inventory)

        XCTAssertFalse(returned)
        XCTAssertEqual(submissions, 1)
        XCTAssertGreaterThan(waits, 0)
        XCTAssertLessThan(waits, 100, "A failed return must time out without another move")
    }

    private func inspectionToken() -> RestoreWindowInspection {
        RestoreWindowInspection(pid: 42, windowID: 7, sourceSpaceID: 10,
                                originalFrame: TestFixtures.windowFrame, destinationSpaceID: 22)
    }

    func testAXWindowsEmptyAndFailureRemainDistinct() {
        let element = AXUIElementCreateSystemWide()
        let empty = AXAttributeReader(attributeResultProvider: { _, _ in .init(value: [] as CFArray, error: .success) })
            .windows(from: element)
        let failure = AXAttributeReader(attributeResultProvider: { _, _ in .init(value: nil, error: .cannotComplete) })
            .windows(from: element)
        XCTAssertTrue(empty.elements.isEmpty)
        XCTAssertEqual(empty.error, .success)
        XCTAssertTrue(failure.elements.isEmpty)
        XCTAssertEqual(failure.error, .cannotComplete)
    }

    func testEngineConfirmsMoveAndRediscoversAXBeforeGeometry() async throws {
        var membership: Set<UInt64> = [10]
        let applier = SpaceTestApplier()
        var scans = 0
        let coordinator = coordinator(
            membership: { _ in membership },
            move: { _, _ in
                membership = [22]
                return true
            })
        let result = try await restore(saved: makeWindowRecord(displayID: 2), spaces: coordinator, applier: applier) {
            scans += 1
            return self.discovery(window: self.window(onScreen: scans > 1))
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(scans, 2)
        XCTAssertEqual(applier.appliedCount, 1)
        XCTAssertEqual(applier.focusCount, 0)
    }

    func testEngineUnconfirmedMoveDoesNotApplyOrFocusWindow() async throws {
        let applier = SpaceTestApplier()
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0),
            spaces: coordinator(membership: { _ in [10] }, move: { _, _ in true }), applier: applier
        ) {
            self.discovery(window: self.window(onScreen: false))
        }
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.desktopUnconfirmed)
        XCTAssertEqual(applier.appliedCount, 0)
        XCTAssertEqual(applier.focusCount, 0)
        XCTAssertEqual(applier.raiseCount, 0)
    }

    func testEngineRecoversZeroAXCandidateThenUsesRediscoveredAXWindow() async throws {
        var membership: Set<UInt64> = [10]
        var scans = 0
        let applier = SpaceTestApplier()
        let coordinator = coordinator(
            membership: { _ in membership },
            move: { _, _ in
                membership = [22]
                return true
            })
        let result = try await restore(saved: makeWindowRecord(displayID: 2), spaces: coordinator, applier: applier) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(
                    applications: [], diagnostics: [],
                    unexposedApplications: [self.unexposed([self.metadata(id: 7, title: nil)])])
            }
            return self.discovery(window: self.window())
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedCount, 1)
        // Initial layout, recovered owner, then the layout-wide refresh before matching.
        XCTAssertEqual(scans, 3)
    }

    func testWeakExposedMatchDoesNotSuppressUniqueHiddenWindowRecovery() async throws {
        for visiblePID: pid_t in [42, 43] {
            var hiddenSpace: Set<UInt64> = [10]
            var movedIDs: [CGWindowID] = []
            let applier = SpaceTestApplier()
            let spaces = coordinator(membership: { $0 == 7 ? hiddenSpace : [22] }, move: { id, space in
                movedIDs.append(id)
                hiddenSpace = [space]
                return true
            })
            let result = try await restore(saved: makeWindowRecord(displayID: 2), spaces: spaces, applier: applier) {
                let sibling = self.window(id: 8, title: "Unrelated", frame: CGRect(x: 900, y: 700, width: 100, height: 100))
                let visible = DiscoveredApplication(bundleIdentifier: TestFixtures.bundleIdentifier, pid: visiblePID,
                    localizedName: nil, windows: visiblePID == 42 && hiddenSpace == [22]
                        ? [sibling, self.window()] : [sibling])
                let target = DiscoveredApplication(bundleIdentifier: TestFixtures.bundleIdentifier, pid: 42,
                    localizedName: nil, windows: [self.window()])
                return WindowDiscoveryResult(
                    applications: hiddenSpace == [22] && visiblePID != 42 ? [visible, target] : [visible],
                    diagnostics: [], unexposedApplications: hiddenSpace == [10]
                        ? [self.unexposed([self.metadata(id: 7)])] : [])
            }

            XCTAssertEqual(result.restoredWindows, 1, "Visible PID: \(visiblePID)")
            XCTAssertEqual(movedIDs, [7], "Visible PID: \(visiblePID)")
            XCTAssertEqual(applier.appliedWindowIDs, [7], "Visible PID: \(visiblePID)")
        }
    }

    func testWeakExposedMatchDoesNotMoveAnUnrelatedHiddenWindow() async throws {
        let applier = SpaceTestApplier()
        var movedIDs: [CGWindowID] = []
        let spaces = coordinator(membership: { $0 == 7 ? [10] : [22] }, move: { id, _ in
            movedIDs.append(id)
            return false
        })
        let result = try await restore(saved: makeWindowRecord(displayID: 2), spaces: spaces, applier: applier) {
            WindowDiscoveryResult(applications: [DiscoveredApplication(bundleIdentifier: TestFixtures.bundleIdentifier,
                pid: 43, localizedName: nil, windows: [self.window(id: 8, title: "Renamed visible window")])],
                diagnostics: [], unexposedApplications: [self.unexposed([self.metadata(id: 7, title: "Unrelated hidden window")])])
        }

        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(movedIDs.isEmpty)
        XCTAssertEqual(applier.appliedWindowIDs, [8])
    }

    func testRecoveryNeverSubstitutesSameProcessSiblingAfterAXTimeout() async throws {
        var membership: Set<UInt64> = [10]
        var scans = 0
        let applier = SpaceTestApplier()
        let coordinator = coordinator(
            membership: { _ in membership },
            move: { _, _ in
                membership = [22]
                return true
            })
        let result = try await restore(saved: makeWindowRecord(displayID: 2), spaces: coordinator, applier: applier) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(
                    applications: [], diagnostics: [], unexposedApplications: [self.unexposed([self.metadata(id: 7)])])
            }
            return self.discovery(window: self.window(id: 8))
        }
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.desktopUnconfirmed)
        XCTAssertEqual(applier.appliedCount, 0)
    }

    func testRecoveryTimeoutNeverSubmitsAgainAfterReadinessScan() async throws {
        var scans = 0
        var submissions = 0
        let applier = SpaceTestApplier()
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        let saved = makeWindowRecord(displayID: 2)
        let trigger = makeWindowRecord(
            bundleIdentifier: "com.example.trigger",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let coordinator = coordinator(
            membership: { _ in [10] },
            move: { _, _ in
                submissions += 1
                return true
            })
        let result = try await restore(saved: saved, extraSaved: [trigger], spaces: coordinator, applier: applier) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(
                    applications: [], diagnostics: [], unexposedApplications: [self.unexposed([self.metadata(id: 7)])])
            }
            return self.discovery(window: self.window())
        }
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(result.restoredWindows, 0)
        XCTAssertEqual(applier.appliedCount, 0)
        XCTAssertGreaterThan(scans, 1)
    }

    func testCGRecoveryDefersToConfiguredManualAndBrowserOpeningTargets() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        for bundleIdentifier in [TestFixtures.bundleIdentifier, "com.google.Chrome"] {
            let configuration =
                bundleIdentifier == TestFixtures.bundleIdentifier
                ? WindowOpeningConfiguration(manualTargets: [target])
                : WindowOpeningConfiguration(automaticallyCapturedTargets: [target])
            let saved = makeWindowRecord(bundleIdentifier: bundleIdentifier, openingConfiguration: configuration)
            var scans = 0
            let opener = SpaceTestTargetOpener()
            opener.onOpen = { XCTAssertEqual(scans, 1, "Recovery must not poll before the configured open") }
            if bundleIdentifier == "com.google.Chrome" {
                opener.result = .openedNewBrowserWindow(
                    CapturedBrowserWindow(
                        browser: .chrome, scriptingIdentifier: "new-window", title: "Window",
                        frame: TestFixtures.windowFrame, frontToBackIndex: 0,
                        tabs: [CapturedBrowserTab(title: nil, URL: target.url)]
                    ))
            }
            let applier = SpaceTestApplier()
            let spaces = coordinator(
                membership: { windowID in
                    XCTAssertEqual(windowID, 8, "Only the intentionally opened AX window may be prepared")
                    return [11]
                },
                move: { _, _ in
                    XCTFail("No recovery move should be submitted")
                    return false
                })
            let result = try await restore(saved: saved, spaces: spaces, applier: applier, opener: opener) {
                scans += 1
                if scans == 1 {
                    let owner = UnexposedApplicationWindows(
                        bundleIdentifier: bundleIdentifier, pid: 42, windows: [self.metadata(id: 7)])
                    return WindowDiscoveryResult(applications: [], diagnostics: [], unexposedApplications: [owner])
                }
                return self.discovery(window: self.window(id: 8), bundleIdentifier: bundleIdentifier)
            }
            XCTAssertEqual(opener.count, 1)
            XCTAssertEqual(scans, 2)
            XCTAssertEqual(result.restoredWindows, 1)
            XCTAssertEqual(applier.appliedWindowIDs, [8])
        }
    }

    func testEngineRaisesCurrentWindowWithoutFocusingOrActivatingApp() async throws {
        let applier = SpaceTestApplier()
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: coordinator(membership: { _ in [22] }),
            applier: applier
        ) {
            self.discovery(window: self.window())
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.raiseCount, 1)
        XCTAssertEqual(applier.focusCount, 0)
    }

    func testEngineFocusesTargetBeforeSafeActivationAndRaise() async throws {
        let applier = SpaceTestApplier()
        let activator = SpaceTestRecordingActivator()
        activator.onActivate = { XCTAssertEqual(applier.focusCount, 1) }
        let spaces = coordinator(membership: { _ in [22] }, applicationWindowIDs: { _ in [7] })
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: spaces,
            applier: applier, applicationActivator: activator
        ) { self.discovery(window: self.window()) }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.focusCount, 1)
        XCTAssertEqual(activator.count, 1)
        XCTAssertEqual(applier.raiseCount, 1)
    }

    func testEngineRetainsGeometryAndRaiseWithoutFocusOrActivationForOffSpaceSibling() async throws {
        let applier = SpaceTestApplier()
        let activator = SpaceTestRecordingActivator()
        let spaces = coordinator(membership: { $0 == 7 ? [22] : [10] }, applicationWindowIDs: { _ in [7, 8] })
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: spaces,
            applier: applier, applicationActivator: activator
        ) { self.discovery(window: self.window()) }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedCount, 1)
        XCTAssertEqual(applier.focusCount, 0)
        XCTAssertEqual(activator.count, 0)
        XCTAssertEqual(applier.raiseCount, 1)
    }

    func testEngineRechecksAppInventoryAfterTargetFocusBeforeActivation() async throws {
        let applier = SpaceTestApplier()
        let activator = SpaceTestRecordingActivator()
        let spaces = coordinator(
            membership: { $0 == 7 ? [22] : [10] },
            applicationWindowIDs: { _ in applier.focusCount == 0 ? [7] : [7, 8] })
        _ = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: spaces,
            applier: applier, applicationActivator: activator
        ) { self.discovery(window: self.window()) }
        XCTAssertEqual(applier.focusCount, 1)
        XCTAssertEqual(activator.count, 0)
        XCTAssertEqual(applier.raiseCount, 1)
    }

    func testEngineDoesNotActivateOrRaiseAfterCapturedDesktopChangesDuringFocus() async throws {
        var changed = false
        let applier = SpaceTestApplier()
        applier.onFocus = { changed = true }
        let activator = SpaceTestRecordingActivator()
        let spaces = RestoreSpaceCoordinator(
            access: RestoreSpaceAccess(
                inventory: { _ in
                    changed
                        ? RestoreSpaceInventory(activeByDisplay: [1: 10, 2: 22], ordinarySpaceIDs: [10, 11, 22])
                        : self.inventory
                },
                membership: { _ in [22] },
                submitMove: { _, _ in
                    XCTFail("Unexpected move")
                    return false
                },
                applicationWindowIDs: { _ in [7] }
            ))
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: spaces,
            applier: applier, applicationActivator: activator
        ) { self.discovery(window: self.window()) }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.focusCount, 1)
        XCTAssertEqual(activator.count, 0)
        XCTAssertEqual(applier.raiseCount, 0)
    }

    func testNoCGIDDialogRetainsGeometryWithoutStackingOrPrivateMove() async throws {
        let applier = SpaceTestApplier()
        let spaces = coordinator(
            membership: { _ in
                XCTFail("Dialog has no CG ID to query")
                return nil
            },
            move: { _, _ in
                XCTFail("Dialog must not submit a private move")
                return false
            })
        let saved = makeWindowRecord(
            role: "AXDialog", subrole: nil,
            frame: CGRect(x: 0, y: 0, width: 32, height: 22), zOrderHint: 0)
        let result = try await restore(saved: saved, spaces: spaces, applier: applier) {
            self.discovery(window: self.window(onScreen: nil, id: nil, role: "AXDialog", subrole: nil))
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedCount, 1)
        XCTAssertEqual(applier.focusCount, 0)
        XCTAssertEqual(applier.raiseCount, 0)
    }

    func testVisibleStickyWindowRetainsGeometryFallback() async throws {
        let applier = SpaceTestApplier()
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2), spaces: coordinator(membership: { _ in [10, 22] }), applier: applier
        ) {
            self.discovery(window: self.window())
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedCount, 1)
    }

    func testUnavailableSpacesDoesNotPinCGRecoveryAcrossAnotherAppsReadinessScan() async throws {
        var scans = 0
        let applier = SpaceTestApplier()
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        let trigger = makeWindowRecord(
            bundleIdentifier: "com.example.trigger",
            openingConfiguration: WindowOpeningConfiguration(manualTargets: [target]))
        let spaces = RestoreSpaceCoordinator(
            access: RestoreSpaceAccess(
                inventory: { _ in nil },
                membership: { _ in
                    XCTFail("Unexpected private membership query")
                    return nil
                },
                submitMove: { _, _ in
                    XCTFail("Unexpected private move")
                    return false
                }
            ))
        let result = try await restore(
            saved: makeWindowRecord(), extraSaved: [trigger], spaces: spaces, applier: applier
        ) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(
                    applications: [], diagnostics: [], unexposedApplications: [self.unexposed([self.metadata(id: 7)])])
            }
            return self.discovery(window: self.window())
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.appliedCount, 1)
        XCTAssertEqual(scans, 2)
    }

    func testEngineKeepsGeometryFallbackButNeverFocusesOffscreenWindow() async throws {
        let applier = SpaceTestApplier()
        let result = try await restore(
            saved: makeWindowRecord(displayID: 2, zOrderHint: 0), spaces: RestoreSpaceCoordinator(access: .unavailable),
            applier: applier
        ) {
            self.discovery(window: self.window(onScreen: false))
        }
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertEqual(applier.focusCount, 0)
        XCTAssertEqual(applier.raiseCount, 0)
    }

    func testMatchedWindowStillOpensMissingWebTargetsForAnyApplication() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        let otherURL = URL(string: "https://example.com/other")!
        for bundleIdentifier in ["com.example.editor", "com.example.webclient"] {
            for isManual in [false, true] {
                for currentURLs in [[otherURL], []] {
                    let opener = SpaceTestTargetOpener()
                    let configuration = isManual
                        ? WindowOpeningConfiguration(manualTargets: [target])
                        : WindowOpeningConfiguration(automaticallyCapturedTargets: [target])
                    let saved = makeWindowRecord(bundleIdentifier: bundleIdentifier, openingConfiguration: configuration)
                    let result = try await restore(saved: saved, opener: opener) {
                        self.discovery(window: self.window(documentURLs: currentURLs), bundleIdentifier: bundleIdentifier)
                    }
                    XCTAssertEqual(opener.openedURLs, [target.url])
                    XCTAssertEqual(result.requestedTargetCount, 1)
                    XCTAssertEqual(result.restoredWindows, 1)
                }
            }
        }
    }

    func testMatchingWebTargetIsReusedForAnyApplication() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        for bundleIdentifier in ["com.example.editor", "com.example.webclient"] {
            for isManual in [false, true] {
                let opener = SpaceTestTargetOpener()
                let configuration = isManual
                    ? WindowOpeningConfiguration(manualTargets: [target])
                    : WindowOpeningConfiguration(automaticallyCapturedTargets: [target])
                let saved = makeWindowRecord(bundleIdentifier: bundleIdentifier, openingConfiguration: configuration)
                let result = try await restore(saved: saved, opener: opener) {
                    self.discovery(window: self.window(documentURLs: [target.url]), bundleIdentifier: bundleIdentifier)
                }
                XCTAssertTrue(opener.openedURLs.isEmpty)
                XCTAssertEqual(result.requestedTargetCount, 0)
                XCTAssertEqual(result.restoredWindows, 1)
            }
        }
    }

    func testAutomaticWebTargetsOpenOnlyMissingOccurrences() async throws {
        let present = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/present")!)
        let missing = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/missing")!)
        let opener = SpaceTestTargetOpener()
        let saved = makeWindowRecord(
            openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [present, missing, present]))
        let result = try await restore(saved: saved, opener: opener) {
            self.discovery(window: self.window(documentURLs: [present.url]))
        }
        XCTAssertEqual(opener.openedURLs, [missing.url, present.url])
        XCTAssertEqual(result.requestedTargetCount, 2)
    }

    func testRecoveredApplicationCanRestoreWindowCreatedByMissingAutomaticWebTarget() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/saved")!)
        let saved = makeWindowRecord(
            displayID: 2, openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        var memberships: [CGWindowID: Set<UInt64>] = [7: [10], 8: [22]]
        var scans = 0
        var opened = false
        var movedIDs: [CGWindowID] = []
        let opener = SpaceTestTargetOpener()
        opener.onOpen = { opened = true }
        let applier = SpaceTestApplier()
        let spaces = coordinator(membership: { memberships[$0] }, move: { id, destination in
            movedIDs.append(id)
            memberships[id] = [destination]
            return true
        })
        let result = try await restore(saved: saved, spaces: spaces, applier: applier, opener: opener) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(applications: [], diagnostics: [],
                    unexposedApplications: [self.unexposed([self.metadata(id: 7, title: nil)])])
            }
            var windows = [self.window(id: 7, documentURLs: [URL(string: "https://example.com/other")!])]
            if opened { windows.append(self.window(id: 8, documentURLs: [target.url])) }
            return WindowDiscoveryResult(applications: [DiscoveredApplication(
                bundleIdentifier: saved.bundleIdentifier, pid: 42, localizedName: nil, windows: windows)], diagnostics: [])
        }
        XCTAssertEqual(opener.openedURLs, [target.url])
        XCTAssertEqual(result.restoredWindows, 1)
        XCTAssertTrue(result.skippedItems.isEmpty)
        XCTAssertEqual(applier.appliedWindowIDs, [8])
        XCTAssertEqual(movedIDs, [7])
    }

    func testOpeningWebTargetNeverRetriesUnconfirmedMoveOfRecoveredWindow() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/saved")!)
        let saved = makeWindowRecord(
            displayID: 2, openingConfiguration: WindowOpeningConfiguration(automaticallyCapturedTargets: [target]))
        var scans = 0
        var moveCount = 0
        let opener = SpaceTestTargetOpener()
        let applier = SpaceTestApplier()
        let spaces = coordinator(membership: { _ in [10] }, move: { _, _ in
            moveCount += 1
            return true
        })
        let result = try await restore(saved: saved, spaces: spaces, applier: applier, opener: opener) {
            scans += 1
            if scans == 1 {
                return WindowDiscoveryResult(applications: [], diagnostics: [],
                    unexposedApplications: [self.unexposed([self.metadata(id: 7, title: nil)])])
            }
            return self.discovery(window: self.window(documentURLs: [target.url]))
        }
        XCTAssertEqual(opener.openedURLs, [target.url])
        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(applier.appliedCount, 0)
        XCTAssertEqual(result.skippedItems.first?.reason, RestoreSkipReason.desktopUnconfirmed)
    }

    func testExplicitManualAndBrowserTargetsKeepOpeningBehavior() async throws {
        let target = WindowOpenTarget(kind: .webURL, url: URL(string: "https://example.com/team")!)
        for bundleIdentifier in [TestFixtures.bundleIdentifier, "com.google.Chrome"] {
            let opener = SpaceTestTargetOpener()
            let configuration =
                bundleIdentifier == TestFixtures.bundleIdentifier
                ? WindowOpeningConfiguration(manualTargets: [target])
                : WindowOpeningConfiguration(automaticallyCapturedTargets: [target])
            let saved = makeWindowRecord(bundleIdentifier: bundleIdentifier, openingConfiguration: configuration)
            _ = try await restore(saved: saved, opener: opener) {
                self.discovery(window: self.window(), bundleIdentifier: bundleIdentifier)
            }
            XCTAssertEqual(opener.count, 1)
        }
    }

    private func discovery(window: DiscoveredWindow, bundleIdentifier: String = TestFixtures.bundleIdentifier)
        -> WindowDiscoveryResult
    {
        WindowDiscoveryResult(
            applications: [
                DiscoveredApplication(
                    bundleIdentifier: bundleIdentifier, pid: 42, localizedName: nil, windows: [window])
            ], diagnostics: [])
    }

    private func siblingDiscovery(resolvesIdentity: Bool = true, ownerPID: pid_t = 42)
        -> (engine: WindowDiscoveryEngine, target: AXUIElement)
    {
        let app = AXUIElementCreateApplication(42)
        let target = AXUIElementCreateApplication(42001)
        let sibling = AXUIElementCreateApplication(42002)
        let frame = TestFixtures.windowFrame
        let reader = AXAttributeReader { element, attribute in
            if CFEqual(element, app) {
                return attribute as String == kAXWindowsAttribute ? [target, sibling] as CFArray : nil
            }
            switch attribute as String {
            case kAXTitleAttribute: return (CFEqual(element, target) ? "Target" : "Sibling") as CFString
            case kAXRoleAttribute: return "AXWindow" as CFString
            case kAXSubroleAttribute: return "AXStandardWindow" as CFString
            case kAXPositionAttribute: return makeAXValue(frame.origin)
            case kAXSizeAttribute: return makeAXValue(frame.size)
            default: return nil
            }
        }
        // CG puts the visible sibling first; AX puts the off-desktop target first.
        let metadata = [8, 7].map { id in
            CGWindowMetadata(
                windowID: CGWindowID(id), processIdentifier: ownerPID, ownerName: nil, layer: 0,
                bounds: frame, title: nil, isOnScreen: id == 8, zOrderHint: id == 8 ? 0 : nil)
        }
        let engine = WindowDiscoveryEngine(
            trustChecker: AccessibilityTrustChecker { true }, attributeReader: reader,
            currentProcessIdentifier: 500,
            runningApplicationsProvider: {
                [RunningApplicationSnapshot(bundleIdentifier: TestFixtures.bundleIdentifier,
                    processIdentifier: 42, localizedName: nil)]
            },
            appElementProvider: { _ in app }, cgWindowMetadataProvider: { _ in [42: metadata] },
            windowIDProvider: { element in
                guard resolvesIdentity else { return nil }
                return CFEqual(element, target) ? 7 : 8
            }
        )
        return (engine, target)
    }

    private func restore(
        saved: WindowRecord, extraSaved: [WindowRecord] = [],
        spaces: RestoreSpaceCoordinator = RestoreSpaceCoordinator(access: .unavailable),
        applier: SpaceTestApplier = SpaceTestApplier(), opener: SpaceTestTargetOpener = SpaceTestTargetOpener(),
        applicationActivator: RestoreApplicationActivating = SpaceTestActivator(),
        discovery: @escaping () throws -> WindowDiscoveryResult
    ) async throws -> RestoreResult {
        let directory = try TestTemporaryDirectory()
        let store = SnapshotStore(snapshotsDirectoryURL: directory.url)
        let displays = [makeDisplayRecord(id: 1), makeDisplayRecord(id: 2)]
        let snapshot = Snapshot(
            name: "Spaces", sourceDisplayState: DisplayState(displays: displays, primaryDisplayID: 1),
            windows: [saved] + extraSaved)
        try store.save(snapshot)
        let resolver = DisplayResolver(screenProvider: {
            displays.map {
                DisplayResolver.ScreenSnapshot(
                    id: $0.id, localizedName: $0.localizedName, frame: $0.frameRect, visibleFrame: $0.visibleFrameRect,
                    backingScaleFactor: 1, isPrimary: $0.id == 1, vendorID: nil, productID: nil, serialNumber: nil)
            }
        })
        return try await RestoreEngine(
            snapshotStore: store,
            trustChecker: AccessibilityTrustChecker { true },
            windowApplier: applier,
            displayResolver: resolver,
            applicationLauncher: SpaceTestLauncher(),
            targetOpener: opener,
            browserTabCapturer: SpaceTestBrowserCapture(),
            applicationActivator: applicationActivator,
            spaces: spaces,
            discoveryResultProvider: discovery,
            runningApplicationBundleProvider: { Set(snapshot.windows.map(\.bundleIdentifier)) },
            launchTimeout: 0,
            launchPollSleeper: { _ in }
        ).restoreSnapshot(id: snapshot.id)
    }

    private func coordinator(
        membership: @escaping (CGWindowID) -> Set<UInt64>?,
        move: @escaping (CGWindowID, UInt64) async -> Bool = { _, _ in false },
        applicationWindowIDs: @escaping (pid_t) -> [CGWindowID]? = { _ in nil },
        windowMetadata: @escaping (pid_t, CGWindowID) -> CGWindowMetadata? = { _, _ in nil },
        inventoryProvider: (([UInt32]) -> RestoreSpaceInventory?)? = nil
    ) -> RestoreSpaceCoordinator {
        RestoreSpaceCoordinator(
            access: RestoreSpaceAccess(
                inventory: inventoryProvider ?? { _ in self.inventory }, membership: membership, submitMove: move,
                applicationWindowIDs: applicationWindowIDs, windowMetadata: windowMetadata),
            sleeper: {})
    }

    private func recovery(membership: @escaping (CGWindowID) -> Set<UInt64>? = { _ in [10] }) -> RestoreCGWindowRecovery
    {
        RestoreCGWindowRecovery(ordinarySpaceIDs: inventory.ordinarySpaceIDs, membership: membership)
    }

    private func window(
        onScreen: Bool? = true, id: CGWindowID? = 7,
        role: String = "AXWindow", subrole: String? = "AXStandardWindow", documentURLs: [URL] = [],
        title: String? = "Window", frame: CGRect = TestFixtures.windowFrame
    ) -> DiscoveredWindow {
        DiscoveredWindow(
            axElement: AXUIElementCreateSystemWide(), documentURLs: documentURLs, title: title, role: role, subrole: subrole,
            frame: frame, isMinimized: false, isFullscreen: false, isMain: false, isVisible: true,
            cgWindowID: id, ownerName: nil, cgLayer: 0, zOrderHint: nil, isOnScreen: onScreen)
    }

    private func metadata(id: CGWindowID, title: String? = "Window", pid: pid_t = 42,
                          frame: CGRect = TestFixtures.windowFrame, layer: Int = 0) -> CGWindowMetadata {
        CGWindowMetadata(
            windowID: id, processIdentifier: pid, ownerName: nil, layer: layer, bounds: frame,
            title: title, isOnScreen: false, zOrderHint: nil)
    }

    private func unexposed(_ windows: [CGWindowMetadata]) -> UnexposedApplicationWindows {
        UnexposedApplicationWindows(bundleIdentifier: TestFixtures.bundleIdentifier, pid: 42, windows: windows)
    }
}

private struct SpaceTestLauncher: RestoreApplicationLaunching {
    func requestLaunch(bundleIdentifier: String) async -> pid_t? {
        XCTFail("Unexpected launch")
        return nil
    }
}

private struct SpaceTestActivator: RestoreApplicationActivating {
    func activate(processIdentifier: pid_t) async -> Bool {
        XCTFail("Unexpected activation")
        return false
    }
}

private final class SpaceTestRecordingActivator: RestoreApplicationActivating {
    var count = 0
    var onActivate: () -> Void = {}
    func activate(processIdentifier: pid_t) async -> Bool {
        XCTAssertEqual(processIdentifier, 42)
        count += 1
        onActivate()
        return true
    }
}

private struct SpaceTestBrowserCapture: BrowserTabCapturing {
    func captureTabs(runningApplications: [RunningApplicationSnapshot]) -> BrowserTabCaptureResult { .empty }
}

private final class SpaceTestTargetOpener: RestoreTargetOpening {
    var count = 0
    var openedURLs: [URL] = []
    var onOpen: () -> Void = {}
    var result: RestoreTargetOpenResult = .opened
    func open(targets: [WindowOpenTarget], bundleIdentifier: String, disposition: RestoreTargetOpenDisposition) async
        -> RestoreTargetOpenResult
    {
        onOpen()
        count += targets.count
        openedURLs.append(contentsOf: targets.map(\.url))
        return result
    }
}

private final class SpaceTestApplier: RestoreWindowApplying {
    var appliedCount = 0
    var appliedWindowIDs: [CGWindowID] = []
    var appliedElements: [AXUIElement] = []
    var raisedWindowIDs: [CGWindowID] = []
    var focusCount = 0
    var raiseCount = 0
    var onFocus: () -> Void = {}
    func apply(savedWindow: WindowRecord, targetFrame: CGRect, to discoveredWindow: DiscoveredWindow) async throws
        -> RestoreWindowApplyResult
    {
        appliedCount += 1
        appliedElements.append(discoveredWindow.axElement)
        if let windowID = discoveredWindow.cgWindowID { appliedWindowIDs.append(windowID) }
        return .restored()
    }
    func raise(_ discoveredWindow: DiscoveredWindow) -> Bool {
        raiseCount += 1
        if let windowID = discoveredWindow.cgWindowID { raisedWindowIDs.append(windowID) }
        return true
    }
    func focus(_ discoveredWindow: DiscoveredWindow) -> RestoreWindowFocusResult {
        focusCount += 1
        onFocus()
        return RestoreWindowFocusResult(didRaise: true, didSetMain: true, didSetFocused: true)
    }
}
