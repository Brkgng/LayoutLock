import AppKit
import Carbon
import Foundation
import SwiftUI

enum HotkeyBindingError: Error, Equatable {
    case invalidCombination
    case duplicateAssignment(String)
}

extension HotkeyBindingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidCombination:
            return "Use a key with Command, Option, or Control."
        case let .duplicateAssignment(snapshotName):
            return "\"\(snapshotName)\" already uses that hotkey."
        }
    }
}

enum HotkeyBindingValidator {
    static let requiredModifierMask = UInt32(cmdKey | optionKey | controlKey)
    static let allowedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    static func validate(_ binding: HotkeyBinding) throws {
        guard binding.modifiers & requiredModifierMask != 0,
              binding.modifiers & ~allowedModifierMask == 0 else {
            throw HotkeyBindingError.invalidCombination
        }
    }

    static func binding(from event: NSEvent) throws -> HotkeyBinding {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        let displayString = displayString(
            keyCode: keyCode,
            modifiers: modifiers,
            eventCharacters: event.charactersIgnoringModifiers
        )
        let binding = HotkeyBinding(
            keyCode: keyCode,
            modifiers: modifiers,
            displayString: displayString
        )

        try validate(binding)
        return binding
    }

    static func carbonModifiers(from modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0

        if modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }

        return modifiers
    }

    static func displayString(
        keyCode: UInt32,
        modifiers: UInt32,
        eventCharacters: String? = nil
    ) -> String {
        var parts: [String] = []

        if modifiers & UInt32(cmdKey) != 0 {
            parts.append("Command")
        }
        if modifiers & UInt32(optionKey) != 0 {
            parts.append("Option")
        }
        if modifiers & UInt32(controlKey) != 0 {
            parts.append("Control")
        }
        if modifiers & UInt32(shiftKey) != 0 {
            parts.append("Shift")
        }

        parts.append(keyName(keyCode: keyCode, eventCharacters: eventCharacters))
        return parts.joined(separator: "-")
    }

    static func shortcutRepresentation(
        keyCode: UInt32,
        modifiers: UInt32
    ) -> (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard let keyName = keyCodeNames[keyCode],
              keyName.count == 1,
              let character = keyName.first else {
            return nil
        }

        let baseCharacter = character.isLetter
            ? Character(character.lowercased())
            : character

        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { eventModifiers.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { eventModifiers.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { eventModifiers.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { eventModifiers.insert(.shift) }

        return (KeyEquivalent(baseCharacter), eventModifiers)
    }

    private static func keyName(keyCode: UInt32, eventCharacters: String?) -> String {
        if let eventCharacters,
           eventCharacters.count == 1,
           let scalar = eventCharacters.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            return eventCharacters.uppercased()
        }

        return keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyCodeNames: [UInt32: String] = [
        0: "A",
        1: "S",
        2: "D",
        3: "F",
        4: "H",
        5: "G",
        6: "Z",
        7: "X",
        8: "C",
        9: "V",
        11: "B",
        12: "Q",
        13: "W",
        14: "E",
        15: "R",
        16: "Y",
        17: "T",
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        22: "6",
        23: "5",
        24: "=",
        25: "9",
        26: "7",
        27: "-",
        28: "8",
        29: "0",
        30: "]",
        31: "O",
        32: "U",
        33: "[",
        34: "I",
        35: "P",
        37: "L",
        38: "J",
        39: "'",
        40: "K",
        41: ";",
        42: "\\",
        43: ",",
        44: "/",
        45: "N",
        46: "M",
        47: ".",
        49: "Space",
        50: "`",
        65: ".",
        67: "*",
        69: "+",
        71: "Clear",
        75: "/",
        76: "Enter",
        78: "-",
        81: "=",
        82: "0",
        83: "1",
        84: "2",
        85: "3",
        86: "4",
        87: "5",
        88: "6",
        89: "7",
        91: "8",
        92: "9",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        118: "F4",
        120: "F2",
        122: "F1"
    ]
}

extension HotkeyBinding {
    func matches(_ other: HotkeyBinding) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var shortcutRepresentation: (KeyEquivalent, SwiftUI.EventModifiers)? {
        HotkeyBindingValidator.shortcutRepresentation(keyCode: keyCode, modifiers: modifiers)
    }
}
