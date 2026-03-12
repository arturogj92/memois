import Carbon.HIToolbox
import CoreGraphics
import Foundation
import AppKit

enum ShortcutFormatter {
    static let supportedModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    static let supportedEventModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]

    static func description(keyCode: Int, modifiers: CGEventFlags) -> String {
        let parts = modifierNames(for: modifiers) + [keyName(for: keyCode)]
        return parts.joined(separator: " + ")
    }

    static func modifierNames(for modifiers: CGEventFlags) -> [String] {
        let normalized = modifiers.intersection(supportedModifierMask)
        var names: [String] = []

        if normalized.contains(.maskCommand) { names.append("Command") }
        if normalized.contains(.maskControl) { names.append("Control") }
        if normalized.contains(.maskAlternate) { names.append("Option") }
        if normalized.contains(.maskShift) { names.append("Shift") }
        if normalized.contains(.maskSecondaryFn) { names.append("Fn") }

        return names
    }

    static func keyName(for keyCode: Int) -> String {
        if let mapped = keyNames[keyCode] {
            return mapped
        }

        return "Key \(keyCode)"
    }

    static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        modifierOnlyKeyCodes.contains(Int(keyCode))
    }

    private static let modifierOnlyKeyCodes: Set<Int> = [
        Int(kVK_Command),
        Int(kVK_RightCommand),
        Int(kVK_Shift),
        Int(kVK_RightShift),
        Int(kVK_Option),
        Int(kVK_RightOption),
        Int(kVK_Control),
        Int(kVK_RightControl),
        Int(kVK_Function)
    ]

    private static let keyNames: [Int: String] = [
        Int(kVK_ANSI_A): "A",
        Int(kVK_ANSI_B): "B",
        Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_D): "D",
        Int(kVK_ANSI_E): "E",
        Int(kVK_ANSI_F): "F",
        Int(kVK_ANSI_G): "G",
        Int(kVK_ANSI_H): "H",
        Int(kVK_ANSI_I): "I",
        Int(kVK_ANSI_J): "J",
        Int(kVK_ANSI_K): "K",
        Int(kVK_ANSI_L): "L",
        Int(kVK_ANSI_M): "M",
        Int(kVK_ANSI_N): "N",
        Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_P): "P",
        Int(kVK_ANSI_Q): "Q",
        Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_S): "S",
        Int(kVK_ANSI_T): "T",
        Int(kVK_ANSI_U): "U",
        Int(kVK_ANSI_V): "V",
        Int(kVK_ANSI_W): "W",
        Int(kVK_ANSI_X): "X",
        Int(kVK_ANSI_Y): "Y",
        Int(kVK_ANSI_Z): "Z",
        Int(kVK_ANSI_0): "0",
        Int(kVK_ANSI_1): "1",
        Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3",
        Int(kVK_ANSI_4): "4",
        Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6",
        Int(kVK_ANSI_7): "7",
        Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9",
        Int(kVK_ANSI_Minus): "-",
        Int(kVK_ANSI_Equal): "=",
        Int(kVK_ANSI_LeftBracket): "[",
        Int(kVK_ANSI_RightBracket): "]",
        Int(kVK_ANSI_Semicolon): ";",
        Int(kVK_ANSI_Quote): "'",
        Int(kVK_ANSI_Comma): ",",
        Int(kVK_ANSI_Period): ".",
        Int(kVK_ANSI_Slash): "/",
        Int(kVK_ANSI_Backslash): "\\",
        Int(kVK_ANSI_Grave): "`",
        Int(kVK_ANSI_Keypad0): "Keypad 0",
        Int(kVK_ANSI_Keypad1): "Keypad 1",
        Int(kVK_ANSI_Keypad2): "Keypad 2",
        Int(kVK_ANSI_Keypad3): "Keypad 3",
        Int(kVK_ANSI_Keypad4): "Keypad 4",
        Int(kVK_ANSI_Keypad5): "Keypad 5",
        Int(kVK_ANSI_Keypad6): "Keypad 6",
        Int(kVK_ANSI_Keypad7): "Keypad 7",
        Int(kVK_ANSI_Keypad8): "Keypad 8",
        Int(kVK_ANSI_Keypad9): "Keypad 9",
        Int(kVK_ANSI_KeypadDecimal): "Keypad .",
        Int(kVK_ANSI_KeypadDivide): "Keypad /",
        Int(kVK_ANSI_KeypadMultiply): "Keypad *",
        Int(kVK_ANSI_KeypadMinus): "Keypad -",
        Int(kVK_ANSI_KeypadPlus): "Keypad +",
        Int(kVK_ANSI_KeypadEnter): "Keypad Enter",
        Int(kVK_ANSI_KeypadEquals): "Keypad =",
        Int(kVK_Return): "Return",
        Int(kVK_Tab): "Tab",
        Int(kVK_Space): "Space",
        Int(kVK_Delete): "Delete",
        Int(kVK_Escape): "Escape",
        Int(kVK_ForwardDelete): "Forward Delete",
        Int(kVK_Home): "Home",
        Int(kVK_End): "End",
        Int(kVK_PageUp): "Page Up",
        Int(kVK_PageDown): "Page Down",
        Int(kVK_LeftArrow): "Left Arrow",
        Int(kVK_RightArrow): "Right Arrow",
        Int(kVK_UpArrow): "Up Arrow",
        Int(kVK_DownArrow): "Down Arrow",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12",
        Int(kVK_F13): "F13",
        Int(kVK_F14): "F14",
        Int(kVK_F15): "F15",
        Int(kVK_F16): "F16",
        Int(kVK_F17): "F17",
        Int(kVK_F18): "F18",
        Int(kVK_F19): "F19",
        Int(kVK_ISO_Section): "ISO Section"
    ]
}
