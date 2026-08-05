import Carbon
import XCTest
@testable import LayoutLock

final class HotkeyManagerTests: XCTestCase {
    func testReloadKeepsSuccessfulRegistrationsWhenOneBindingFails() {
        let firstSnapshotID = UUID()
        let blockedSnapshotID = UUID()
        let lastSnapshotID = UUID()
        let registrar = FakeHotkeyRegistrar(failingKeyCodes: [41])
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        XCTAssertThrowsError(try manager.reloadBindings(from: [
            makeSummary(id: firstSnapshotID, name: "First", hotkey: makeHotkey(keyCode: 40)),
            makeSummary(id: blockedSnapshotID, name: "Blocked", hotkey: makeHotkey(keyCode: 41)),
            makeSummary(id: lastSnapshotID, name: "Last", hotkey: makeHotkey(keyCode: 42))
        ]))

        XCTAssertEqual(manager.registeredSnapshotIDs, [firstSnapshotID, lastSnapshotID])
    }

    func testReloadSkipsDuplicateAndInvalidBindingsWithoutBlockingLaterBindings() {
        let firstSnapshotID = UUID()
        let duplicateSnapshotID = UUID()
        let invalidSnapshotID = UUID()
        let lastSnapshotID = UUID()
        let registrar = FakeHotkeyRegistrar()
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        XCTAssertThrowsError(try manager.reloadBindings(from: [
            makeSummary(id: firstSnapshotID, name: "First", hotkey: makeHotkey(keyCode: 40)),
            makeSummary(id: duplicateSnapshotID, name: "Duplicate", hotkey: makeHotkey(keyCode: 40)),
            makeSummary(
                id: invalidSnapshotID,
                name: "Invalid",
                hotkey: HotkeyBinding(
                    keyCode: 41,
                    modifiers: UInt32(shiftKey),
                    displayString: "Shift-;"
                )
            ),
            makeSummary(id: lastSnapshotID, name: "Last", hotkey: makeHotkey(keyCode: 42))
        ]))

        XCTAssertEqual(manager.registeredSnapshotIDs, [firstSnapshotID, lastSnapshotID])
        XCTAssertEqual(registrar.registeredKeyCodes, [40, 42])
    }

    func testReloadUnregistersPreviousBindingsBeforeRegisteringNewBindings() throws {
        let firstSnapshotID = UUID()
        let secondSnapshotID = UUID()
        let registrar = FakeHotkeyRegistrar()
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        try manager.reloadBindings(from: [
            makeSummary(id: firstSnapshotID, name: "First", hotkey: makeHotkey(keyCode: 40))
        ])
        try manager.reloadBindings(from: [
            makeSummary(id: secondSnapshotID, name: "Second", hotkey: makeHotkey(keyCode: 42))
        ])

        XCTAssertEqual(registrar.unregisteredTokenValues, [1])
        XCTAssertEqual(manager.registeredSnapshotIDs, [secondSnapshotID])
    }

    func testSuspendUnregistersCurrentlyRegisteredHotkeys() throws {
        let snapshotID = UUID()
        let registrar = FakeHotkeyRegistrar()
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        try manager.reloadBindings(from: [
            makeSummary(id: snapshotID, name: "First", hotkey: makeHotkey(keyCode: 40))
        ])
        XCTAssertEqual(registrar.unregisteredTokenValues, [])

        manager.suspendBindings()

        XCTAssertEqual(registrar.unregisteredTokenValues, [1])
        XCTAssertTrue(manager.registeredSnapshotIDs.isEmpty)
        XCTAssertTrue(manager.isSuspended)
    }

    func testReloadWhileSuspendedDoesNotRegisterHotkeys() throws {
        let firstSnapshotID = UUID()
        let secondSnapshotID = UUID()
        let registrar = FakeHotkeyRegistrar()
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        try manager.reloadBindings(from: [
            makeSummary(id: firstSnapshotID, name: "First", hotkey: makeHotkey(keyCode: 40))
        ])
        manager.suspendBindings()

        try manager.reloadBindings(from: [
            makeSummary(id: secondSnapshotID, name: "Second", hotkey: makeHotkey(keyCode: 42))
        ])

        XCTAssertTrue(manager.registeredSnapshotIDs.isEmpty)
        XCTAssertEqual(registrar.registeredKeyCodes, [40])
    }

    func testResumeRegistersLatestSummariesAfterSuspendedReload() throws {
        let firstSnapshotID = UUID()
        let secondSnapshotID = UUID()
        let registrar = FakeHotkeyRegistrar()
        let manager = HotkeyManager(
            callback: { _ in },
            registrar: registrar,
            eventHandlerInstaller: { _ in nil }
        )

        try manager.reloadBindings(from: [
            makeSummary(id: firstSnapshotID, name: "First", hotkey: makeHotkey(keyCode: 40))
        ])
        manager.suspendBindings()

        try manager.reloadBindings(from: [
            makeSummary(id: secondSnapshotID, name: "Second", hotkey: makeHotkey(keyCode: 42))
        ])

        try manager.resumeBindings()

        XCTAssertEqual(manager.registeredSnapshotIDs, [secondSnapshotID])
        XCTAssertEqual(registrar.registeredKeyCodes, [40, 42])
        XCTAssertFalse(manager.isSuspended)
    }

    private func makeSummary(
        id: UUID,
        name: String,
        hotkey: HotkeyBinding?
    ) -> SnapshotSummary {
        SnapshotSummary(snapshot: Snapshot(
            id: id,
            name: name,
            sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil),
            windows: [],
            hotkey: hotkey
        ))
    }

    private func makeHotkey(keyCode: UInt32) -> HotkeyBinding {
        HotkeyBinding(
            keyCode: keyCode,
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "Command-Option-\(keyCode)"
        )
    }
}

private final class FakeHotkeyRegistrar: HotkeyRegistering {
    private let failingKeyCodes: Set<UInt32>
    private var nextTokenValue = 1
    private(set) var registeredKeyCodes: [UInt32] = []
    private(set) var unregisteredTokenValues: [Int] = []

    init(failingKeyCodes: Set<UInt32> = []) {
        self.failingKeyCodes = failingKeyCodes
    }

    func register(
        hotkey: HotkeyBinding,
        hotkeyID _: EventHotKeyID
    ) throws -> EventHotKeyRef {
        registeredKeyCodes.append(hotkey.keyCode)

        if failingKeyCodes.contains(hotkey.keyCode) {
            throw HotkeyManagerError.registrationFailed("Injected", -9876)
        }

        let tokenValue = nextTokenValue
        nextTokenValue += 1
        return EventHotKeyRef(bitPattern: tokenValue)!
    }

    func unregister(_ hotkeyRef: EventHotKeyRef) {
        unregisteredTokenValues.append(Int(bitPattern: hotkeyRef))
    }
}
