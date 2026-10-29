import Carbon
import Foundation
import XCTest
@testable import LayoutLock

@MainActor
final class SnapshotMenuControllerMonetizationTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        temporaryDirectoryURL = nil
    }

    func testFreePlanBlocksFourthNewLayoutWithoutDeletingExistingLayouts() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try saveSnapshots(count: 3, in: store)
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )

        let task = controller.captureCurrentSnapshot(named: "Fourth Layout")

        XCTAssertNil(task)
        XCTAssertEqual(controller.snapshotSummaries.count, 3)
        XCTAssertEqual(controller.status?.message, ProFeature.unlimitedLayouts.requiredPlanMessage)
        XCTAssertEqual(try store.listSummaries().count, 3)
    }

    func testProPlanAllowsFourthNewLayout() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try saveSnapshots(count: 3, in: store)
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: true)
        )

        let task = controller.captureCurrentSnapshot()
        await task?.value

        XCTAssertEqual(controller.snapshotSummaries.count, 4)
        XCTAssertEqual(controller.status?.isError, false)
    }

    func testFreePlanAllowsAssigningChangingClearingAndUsingHotkeys() throws {
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, name: "Coding"))
        let initialHotkey = makeHotkey(keyCode: 40, displayString: "Command-Option-K")
        let changedHotkey = makeHotkey(keyCode: 42, displayString: "Command-Option-L")
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false),
            hotkeyPrompt: { _, _ in initialHotkey }
        )
        controller.setSnapshotSummariesDidChange { _ in nil }

        controller.assignHotkey(to: snapshotID)
        XCTAssertEqual(try store.loadSnapshot(id: snapshotID).hotkey, initialHotkey)

        XCTAssertTrue(controller.setHotkey(changedHotkey, for: snapshotID))
        XCTAssertEqual(try store.loadSnapshot(id: snapshotID).hotkey, changedHotkey)

        let registrar = MonetizationHotkeyRegistrar()
        var triggeredSnapshotID: UUID?
        let manager = HotkeyManager(
            callback: { triggeredSnapshotID = $0 },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )
        try manager.reloadBindings(from: controller.snapshotSummaries)
        manager.handleRegisteredHotkey(id: 1)
        XCTAssertEqual(triggeredSnapshotID, snapshotID)

        controller.clearHotkey(for: snapshotID)
        XCTAssertNil(try store.loadSnapshot(id: snapshotID).hotkey)
    }

    func testFreePlanBlocksCustomRestoreOrderEditing() throws {
        let windowA = makeWindowRecord(id: UUID(), zOrderHint: 1)
        let windowB = makeWindowRecord(id: UUID(), zOrderHint: 2)
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(
            id: snapshotID,
            windows: [windowA, windowB]
        ))
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )

        XCTAssertFalse(controller.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [windowB.id, windowA.id],
            in: snapshotID
        ))
        XCTAssertEqual(controller.status?.kind, .proRequired)
        XCTAssertEqual(controller.status?.message, ProFeature.customRestoreOrder.requiredPlanMessage)
        let persistedWindows = try store.loadSnapshot(id: snapshotID).windows
        XCTAssertEqual(persistedWindows.first(where: { $0.id == windowA.id })?.zOrderHint, 1)
        XCTAssertEqual(persistedWindows.first(where: { $0.id == windowB.id })?.zOrderHint, 2)
    }

    func testProPlanAllowsCustomRestoreOrderEditing() throws {
        let windowA = makeWindowRecord(id: UUID(), zOrderHint: 1)
        let windowB = makeWindowRecord(id: UUID(), zOrderHint: 2)
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, windows: [windowA, windowB]))
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: true)
        )

        XCTAssertTrue(controller.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [windowB.id, windowA.id],
            in: snapshotID
        ))
        let persistedWindows = try store.loadSnapshot(id: snapshotID).windows
        XCTAssertEqual(persistedWindows.first(where: { $0.id == windowB.id })?.zOrderHint, 1)
        XCTAssertEqual(persistedWindows.first(where: { $0.id == windowA.id })?.zOrderHint, 2)
    }

    func testStoredCustomOrderRemainsEffectiveAfterDowngrade() throws {
        let windowA = makeWindowRecord(id: UUID(), zOrderHint: 1)
        let windowB = makeWindowRecord(id: UUID(), zOrderHint: 2)
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, windows: [windowA, windowB]))
        let proController = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: true)
        )
        XCTAssertTrue(proController.reorderWindows(
            displayID: 1,
            orderedWindowIDs: [windowB.id, windowA.id],
            in: snapshotID
        ))

        let freeController = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )
        let persistedSnapshot = try XCTUnwrap(freeController.loadSnapshot(id: snapshotID))
        let restoreItems = persistedSnapshot.windows.map {
            RestoreWindowZOrderItem(
                savedWindow: $0,
                processIdentifier: pid_t($0.pidAtCapture),
                liveWindow: makeDiscoveredWindow()
            )
        }

        XCTAssertEqual(
            RestoreWindowZOrderPlanner().frontmostItem(for: restoreItems)?.savedWindow.id,
            windowB.id
        )
    }

    func testFreePlanAllowsIndividualWindowRemoval() throws {
        let windowA = makeWindowRecord(id: UUID(), zOrderHint: 1)
        let windowB = makeWindowRecord(id: UUID(), zOrderHint: 2)
        let snapshotID = UUID()
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try store.save(makeSnapshot(id: snapshotID, windows: [windowA, windowB]))
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )

        controller.removeWindow(
            windowID: windowA.id,
            windowTitle: windowA.windowTitle,
            appName: "Editor",
            from: snapshotID
        )
        XCTAssertEqual(controller.status?.kind, .info)

        let persistedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(persistedSnapshot.windows.map(\.id), [windowB.id])
    }

    func testFreePlanStillAllowsRestoreRenameUpdateAndDeleteExistingOverLimitLayouts() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try saveSnapshots(count: 4, in: store)
        let snapshotID = try XCTUnwrap(try store.listSummaries().first?.id)
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )

        XCTAssertTrue(controller.renameSnapshotInline(id: snapshotID, newName: "Renamed"))

        let updateTask = controller.updateSnapshot(id: snapshotID)
        XCTAssertNotNil(updateTask)
        await updateTask?.value

        let updatedSnapshot = try store.loadSnapshot(id: snapshotID)
        XCTAssertEqual(updatedSnapshot.id, snapshotID)
        XCTAssertEqual(updatedSnapshot.name, "Renamed")
        XCTAssertEqual(updatedSnapshot.windows.count, 1)
        XCTAssertEqual(controller.status?.message, "Updated \"Renamed\" with 1 window.")
        XCTAssertEqual(try store.listSummaries().count, 4)

        let restoreTask = controller.restoreSnapshot(id: snapshotID)
        await restoreTask?.value

        controller.deleteSnapshot(id: snapshotID)

        XCTAssertEqual(try store.listSummaries().count, 3)
    }

    func testProRequiredStatusIsNotClassifiedAsError() async throws {
        let store = SnapshotStore(snapshotsDirectoryURL: temporaryDirectoryURL)
        try saveSnapshots(count: 3, in: store)
        let controller = makeController(
            store: store,
            entitlementProvider: StaticEntitlementProvider(isProUnlocked: false)
        )

        _ = controller.captureCurrentSnapshot()

        XCTAssertEqual(controller.status?.kind, .proRequired)
        XCTAssertEqual(controller.status?.isError, false)
        XCTAssertEqual(controller.status?.message, ProFeature.unlimitedLayouts.requiredPlanMessage)
    }

    func testStorageFailureRemainsClassifiedAsError() {
        let controller = SnapshotMenuController()

        controller.deleteSnapshot(id: UUID())

        XCTAssertEqual(controller.status?.kind, .error)
        XCTAssertEqual(controller.status?.isError, true)
    }

    func testNamedCaptureReportsUnavailableStorageWithoutStarting() {
        let controller = SnapshotMenuController()

        let task = controller.captureCurrentSnapshot(named: "Dashboard Layout")

        XCTAssertNil(task)
        XCTAssertFalse(controller.isOperating)
        XCTAssertEqual(controller.status?.message, "Layout storage is unavailable.")
        XCTAssertEqual(controller.status?.kind, .error)
    }

    private func makeController(
        store: SnapshotStore,
        entitlementProvider: EntitlementProviding,
        hotkeyPrompt: @escaping SnapshotMenuController.HotkeyPrompt = HotkeyCapturePrompt.prompt
    ) -> SnapshotMenuController {
        let trustChecker = AccessibilityTrustChecker { true }
        let restoreEngine = RestoreEngine(
            snapshotStore: store,
            windowDiscoveryEngine: WindowDiscoveryEngine(trustChecker: trustChecker),
            trustChecker: trustChecker,
            displayResolver: DisplayResolver(screenProvider: { [] }),
            applicationLauncher: NoOpRestoreApplicationLauncher(),
            applicationActivator: NoOpRestoreApplicationActivator(),
            discoveredApplicationsProvider: { [] },
            runningApplicationBundleProvider: { [] }
        )

        return SnapshotMenuController(
            snapshotStore: store,
            snapshotCaptureService: makeSnapshotCaptureService(store: store),
            restoreEngine: restoreEngine,
            hotkeyPrompt: hotkeyPrompt,
            snapshotNamePrompt: { _ in "New Layout" },
            entitlementProvider: entitlementProvider
        )
    }

    private func makeSnapshotCaptureService(store: SnapshotStore) -> SnapshotCaptureService {
        let display = makeDisplayRecord()
        return SnapshotCaptureService(
            displayResolver: DisplayResolver(screenProvider: {
                [
                    DisplayResolver.ScreenSnapshot(
                        id: display.id,
                        localizedName: display.localizedName,
                        frame: display.frameRect,
                        visibleFrame: display.visibleFrameRect,
                        backingScaleFactor: display.backingScaleFactor,
                        isPrimary: display.isPrimary,
                        vendorID: display.vendorID,
                        productID: display.productID,
                        serialNumber: display.serialNumber
                    )
                ]
            }),
            snapshotStore: store,
            discoveryResultProvider: {
                WindowDiscoveryResult(
                    applications: [
                        DiscoveredApplication(
                            bundleIdentifier: "com.example.editor",
                            pid: 42,
                            localizedName: "Editor",
                            windows: [makeDiscoveredWindow(cgWindowID: 123)]
                        )
                    ],
                    diagnostics: []
                )
            }
        )
    }

    private func saveSnapshots(count: Int, in store: SnapshotStore) throws {
        for index in 0..<count {
            try store.save(makeSnapshot(
                id: UUID(),
                name: "Layout \(index + 1)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
    }
}

private final class MonetizationHotkeyRegistrar: HotkeyRegistering {
    private var nextTokenValue = 1

    func register(
        hotkey _: HotkeyBinding,
        hotkeyID _: EventHotKeyID
    ) throws -> EventHotKeyRef {
        defer { nextTokenValue += 1 }
        return EventHotKeyRef(bitPattern: nextTokenValue)!
    }

    func unregister(_: EventHotKeyRef) {}
}

private struct NoOpRestoreApplicationLauncher: RestoreApplicationLaunching {
    func isAvailable(bundleIdentifier: String) -> Bool { true }

    func requestLaunch(bundleIdentifier _: String, preferredApplicationURL: URL?) async -> pid_t? {
        nil
    }
}

private struct NoOpRestoreApplicationActivator: RestoreApplicationActivating {
    func activate(processIdentifier _: pid_t) -> Bool {
        false
    }
}
