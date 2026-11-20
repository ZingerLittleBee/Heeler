import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The open Composer grows to five lines and scrolls past them. Chinese
// lays out taller than the body font's own line height, so a cap counted
// in body lines cut the last line off, and the caret's line stopped short
// of the bottom inset, under the edge fade.

// On a hardware keyboard Return sends the draft and Shift-Return starts a new
// line (#512). The input method keeps Return while it is composing, and ⌘↩
// stays with the scene's Send Composer Draft command.

@MainActor
@Suite("Composer hardware Return")
struct ComposerHardwareReturnTests {
    struct Press: Sendable, CustomTestStringConvertible {
        let keyCode: UIKeyboardHIDUsage
        let modifiers: UIKeyModifierFlags
        let hasMarkedText: Bool
        let sends: Bool
        let testDescription: String
    }

    nonisolated static let presses: [Press] = [
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [], hasMarkedText: false,
              sends: true, testDescription: "Return"),
        Press(keyCode: .keypadEnter, modifiers: [.numericPad], hasMarkedText: false,
              sends: true, testDescription: "keypad Enter"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [.alphaShift], hasMarkedText: false,
              sends: true, testDescription: "Return with Caps Lock"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [.shift], hasMarkedText: false,
              sends: false, testDescription: "Shift-Return"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [.alternate], hasMarkedText: false,
              sends: false, testDescription: "Option-Return"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [.control], hasMarkedText: false,
              sends: false, testDescription: "Control-Return"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [.command], hasMarkedText: false,
              sends: false, testDescription: "Command-Return"),
        Press(keyCode: .keyboardReturnOrEnter, modifiers: [], hasMarkedText: true,
              sends: false, testDescription: "Return while composing"),
        Press(keyCode: .keyboardA, modifiers: [], hasMarkedText: false,
              sends: false, testDescription: "a letter"),
    ]

    @Test(arguments: presses)
    func onlyAPlainReturnSends(press: Press) {
        #expect(ComposerHardwareReturn.sends(
            keyCode: press.keyCode,
            modifierFlags: press.modifiers,
            hasMarkedText: press.hasMarkedText) == press.sends)
    }
}
