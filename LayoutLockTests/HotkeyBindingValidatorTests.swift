import Carbon
import SwiftUI
import XCTest
@testable import LayoutLock

final class HotkeyBindingValidatorTests: XCTestCase {
    func testValidateAcceptsCommandOptionControlHotkeys() throws {
        let binding = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "Command-Option-K"
        )

        XCTAssertNoThrow(try HotkeyBindingValidator.validate(binding))
    }

    func testValidateRejectsShiftOnlyHotkeys() {
        let binding = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(shiftKey),
            displayString: "Shift-K"
        )

        XCTAssertThrowsError(try HotkeyBindingValidator.validate(binding)) { error in
            XCTAssertEqual(error as? HotkeyBindingError, .invalidCombination)
        }
    }

    func testValidateRejectsUnknownModifierBits() {
        let binding = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey) | 0x8000,
            displayString: "Command-K"
        )

        XCTAssertThrowsError(try HotkeyBindingValidator.validate(binding)) { error in
            XCTAssertEqual(error as? HotkeyBindingError, .invalidCombination)
        }
    }

    func testDisplayStringUsesCarbonModifierOrder() {
        let displayString = HotkeyBindingValidator.displayString(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey | shiftKey)
        )

        XCTAssertEqual(displayString, "Command-Option-Shift-K")
    }

    func testBindingsMatchByKeyCodeAndModifiers() {
        let first = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey),
            displayString: "Command-K"
        )
        let second = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey),
            displayString: "Different Label"
        )

        XCTAssertTrue(first.matches(second))
    }

    func testShortcutRepresentationMapsCommandOptionLetter() {
        let binding = HotkeyBinding(
            keyCode: 8,
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "Command-Option-C"
        )

        let representation = binding.shortcutRepresentation
        XCTAssertEqual(representation?.0, KeyEquivalent("c"))
        XCTAssertEqual(representation?.1, [.command, .option])
    }

    func testShortcutRepresentationIncludesShiftModifier() {
        let binding = HotkeyBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            displayString: "Command-Option-Shift-K"
        )

        let representation = binding.shortcutRepresentation
        XCTAssertEqual(representation?.0, KeyEquivalent("k"))
        XCTAssertEqual(representation?.1, [.command, .option, .shift])
    }

    func testShortcutRepresentationReturnsNilForUnmappableKeys() {
        let spaceBinding = HotkeyBinding(
            keyCode: 49,
            modifiers: UInt32(cmdKey),
            displayString: "Command-Space"
        )
        let f1Binding = HotkeyBinding(
            keyCode: 122,
            modifiers: UInt32(cmdKey),
            displayString: "Command-F1"
        )
        let enterBinding = HotkeyBinding(
            keyCode: 76,
            modifiers: UInt32(cmdKey),
            displayString: "Command-Enter"
        )

        XCTAssertNil(spaceBinding.shortcutRepresentation)
        XCTAssertNil(f1Binding.shortcutRepresentation)
        XCTAssertNil(enterBinding.shortcutRepresentation)
    }
}
