import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The open Composer grows to five lines and scrolls past them. Chinese
// lays out taller than the body font's own line height, so a cap counted
// in body lines cut the last line off, and the caret's line stopped short
// of the bottom inset, under the edge fade.

@MainActor
@Suite("Agent Composer text view")
struct AgentComposerTextViewTests {
    private static let width: CGFloat = 300
    private static let lineLimit = 5

    private static func makeEditor() -> AgentComposerUITextView {
        let editor = AgentComposerUITextView(
            frame: CGRect(x: 0, y: 0, width: width, height: 100))
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return editor
    }

    private static func cap(_ editor: AgentComposerUITextView) -> CGFloat {
        editor.draftLineHeight * CGFloat(lineLimit)
            + editor.textContainerInset.top + editor.textContainerInset.bottom
    }

    @Test(arguments: ["第一行：检查配对步骤", "first line of the draft"])
    func fiveLinesOfDraftFitTheCap(line: String) {
        let editor = Self.makeEditor()
        editor.text = Array(repeating: line, count: Self.lineLimit).joined(separator: "\n")

        let measured = editor.sizeThatFits(
            CGSize(width: Self.width, height: .greatestFiniteMagnitude))

        #expect(measured.height <= Self.cap(editor) + 0.01)
    }

    @Test func caretOnTheLastLineClearsTheBottomInset() {
        let editor = Self.makeEditor()
        editor.text = (1...7).map { "第\($0)行：检查配对步骤" }.joined(separator: "\n")
        editor.frame.size.height = Self.cap(editor)
        editor.layoutIfNeeded()
        let overflow = editor.contentSize.height - editor.bounds.height
        #expect(overflow > 0)

        editor.scrollRectToVisible(editor.caretRect(for: editor.endOfDocument), animated: false)

        #expect(abs(editor.contentOffset.y - overflow) < 0.5)
    }
}

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

    @Test func aSendingReturnRefusesUIKitsNewLineUntilReleased() {
        let editor = AgentComposerUITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        var sends = 0
        editor.onHardwareReturn = { sends += 1 }
        let token = ObjectIdentifier(editor)

        editor.beginHardwareReturn(token: token)

        #expect(sends == 1)
        #expect(!editor.acceptsReplacement("\n"))
        #expect(editor.acceptsReplacement("a"))

        #expect(editor.endHardwareReturn(token: token))
        #expect(editor.acceptsReplacement("\n"))
        #expect(!editor.endHardwareReturn(token: token))
    }

    /// The release can go to another responder; a Return left pending would
    /// refuse every new line typed after the Composer is focused again.
    @Test func resigningForgetsAPendingReturn() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let editor = AgentComposerUITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        window.addSubview(editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #expect(editor.becomeFirstResponder())

        editor.beginHardwareReturn(token: ObjectIdentifier(window))
        #expect(editor.resignFirstResponder())

        #expect(editor.acceptsReplacement("\n"))
    }
}
