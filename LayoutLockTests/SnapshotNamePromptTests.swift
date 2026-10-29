import AppKit
import XCTest
@testable import LayoutLock

@MainActor
final class SnapshotNamePromptTests: XCTestCase {
    func testUpdateConfirmationIsNonModalAndCancelDoesNotConfirm() async throws {
        var result: Bool?
        SnapshotNamePrompt.confirmUpdate(currentName: "Test Layout") { result = $0 }
        let window = try await confirmationWindow(named: "Test Layout")
        defer { window.close() }

        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(window.defaultButtonCell?.title, "Cancel")
        try XCTUnwrap(button("Cancel", in: window.contentView)).performClick(nil)

        XCTAssertEqual(result, false)
        XCTAssertFalse(window.isVisible)
    }

    func testUpdateConfirmationOnlyConfirmsExplicitUpdate() async throws {
        var result: Bool?
        SnapshotNamePrompt.confirmUpdate(currentName: "Test Layout") { result = $0 }
        let window = try await confirmationWindow(named: "Test Layout")
        defer { window.close() }

        XCTAssertNil(result)
        try XCTUnwrap(button("Update", in: window.contentView)).performClick(nil)
        XCTAssertEqual(result, true)
        XCTAssertFalse(window.isVisible)
    }

    func testMenuSelectionRefocusesSameWindowAndConfirmsLatestTarget() async throws {
        var confirmedTargets: [String] = []
        SnapshotNamePrompt.confirmUpdate(currentName: "Layout 1") { _ in
            confirmedTargets.append("Layout 1")
        }
        let originalWindow = try await confirmationWindow(named: "Layout 1")
        defer { originalWindow.close() }
        originalWindow.orderOut(nil)

        let target = MenuSelectionTarget {
            SnapshotNamePrompt.confirmUpdate(currentName: "personal") { confirmed in
                XCTAssertTrue(confirmed)
                confirmedTargets.append("personal")
            }
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: "personal", action: #selector(MenuSelectionTarget.select), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        XCTAssertNil(NSApp.modalWindow, "An app-modal alert would block ordinary menu actions.")
        menu.performActionForItem(at: 0)

        let updatedWindow = try await confirmationWindow(named: "personal")
        XCTAssertTrue(updatedWindow === originalWindow)
        XCTAssertTrue(updatedWindow.isKeyWindow)
        XCTAssertFalse(containsText("\"Layout 1\"", in: updatedWindow.contentView))
        try XCTUnwrap(button("Update", in: updatedWindow.contentView)).performClick(nil)
        XCTAssertEqual(confirmedTargets, ["personal"])
        XCTAssertFalse(updatedWindow.isVisible)
    }

    func testRepeatedUpdateBeforePresentationConfirmsLatestTarget() async throws {
        var confirmedTargets: [String] = []
        SnapshotNamePrompt.confirmUpdate(currentName: "Original Layout") { _ in
            confirmedTargets.append("Original Layout")
        }
        SnapshotNamePrompt.confirmUpdate(currentName: "Latest Layout") { confirmed in
            XCTAssertTrue(confirmed)
            confirmedTargets.append("Latest Layout")
        }
        let window = try await confirmationWindow(named: "Latest Layout")
        defer { window.close() }
        try XCTUnwrap(button("Update", in: window.contentView)).performClick(nil)
        XCTAssertEqual(confirmedTargets, ["Latest Layout"])
    }

    func testClosingConfirmationCancelsAndAllowsAnotherRequest() async throws {
        var result: Bool?
        SnapshotNamePrompt.confirmUpdate(currentName: "First Layout") { result = $0 }
        let firstWindow = try await confirmationWindow(named: "First Layout")
        firstWindow.close()
        XCTAssertEqual(result, false)

        SnapshotNamePrompt.confirmUpdate(currentName: "Next Layout") { _ in }
        let nextWindow = try await confirmationWindow(named: "Next Layout")
        defer { nextWindow.close() }
        XCTAssertFalse(firstWindow === nextWindow)
    }

    private func confirmationWindow(named name: String) async throws -> NSWindow {
        for _ in 0..<40 {
            if let window = NSApp.windows.first(where: {
                $0.isVisible && containsText("Update \"\(name)\"?", in: $0.contentView)
            }) {
                return window
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return try XCTUnwrap(nil as NSWindow?, "Confirmation for \(name) did not appear.")
    }

    private func containsText(_ text: String, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
        return view.subviews.contains { containsText(text, in: $0) }
    }

    private func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }
}

@MainActor
private final class MenuSelectionTarget: NSObject {
    private let selection: () -> Void

    init(selection: @escaping () -> Void) { self.selection = selection }
    @objc func select() { selection() }
}
