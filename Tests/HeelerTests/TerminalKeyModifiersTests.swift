import Foundation
import GhosttyTerminal
import Testing
import UIKit

@testable import Heeler

/// Exercises the keyboard controls through a live Ghostty surface and its output callback.
@MainActor
@Suite("Terminal key modifiers", .serialized)
struct TerminalKeyModifiersTests {
    @Test func retappingArmedModifiersDisarmsThem() {
        let control = TerminalKeyboardControl()
        for modifier: TerminalKeyModifiers in [.control, .option, .shift] {
            control.toggleModifier(modifier)
            #expect(control.pendingModifiers == modifier)
            control.toggleModifier(modifier)
            #expect(control.pendingModifiers.isEmpty)
        }
    }

    @Test func commandChordsBypassGhosttyExceptZoom() {
        let route = { (characters: String, flags: UIKeyModifierFlags) in
            HeelerTerminalView.hardwarePressRoute(
                charactersIgnoringModifiers: characters, modifierFlags: flags)
        }
        for (characters, flags) in [
            ("n", UIKeyModifierFlags.command), ("e", .command), ("1", .command),
            ("h", [.command, .shift]), ("H", [.command, .shift]),
        ] as [(String, UIKeyModifierFlags)] {
            #expect(
                route(characters, flags) == .sceneCommand,
                "⌘\(flags.contains(.shift) ? "⇧" : "")\(characters)")
        }
        #expect(route("=", .command) == .zoom(1))
        #expect(route("+", [.command, .shift]) == .zoom(1))
        #expect(route("-", .command) == .zoom(-1))
        #expect(route("_", [.command, .shift]) == .zoom(-1))
        #expect(route("c", .control) == .terminal)
        #expect(route(UIKeyCommand.inputEscape, []) == .terminal)
        #expect(route(UIKeyCommand.inputUpArrow, []) == .terminal)
        #expect(route("a", []) == .terminal)
        #expect(route("=", []) == .terminal)
    }

    @Test func physicalKeyMappingKeepsShiftedIdentityAndOmitsCommand() {
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardC,
                characters: "c",
                charactersIgnoringModifiers: "c",
                modifierFlags: [])
                == ArmedModifierPhysicalKey(key: .character("c"), physicalModifiers: []))
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardC,
                characters: "C",
                charactersIgnoringModifiers: "c",
                modifierFlags: .shift)
                == ArmedModifierPhysicalKey(key: .character("C"), physicalModifiers: .shift))
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardTab,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                modifierFlags: .shift)
                == ArmedModifierPhysicalKey(key: .tab, physicalModifiers: .shift))
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardLeftArrow,
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: .control)
                == ArmedModifierPhysicalKey(key: .left, physicalModifiers: .control))
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardC,
                characters: "c",
                charactersIgnoringModifiers: "c",
                modifierFlags: [.command, .shift]) == nil)
        #expect(
            HeelerTerminalView.physicalKey(
                keyCode: .keyboardE,
                characters: "é",
                charactersIgnoringModifiers: "é",
                modifierFlags: []) == nil)
    }

    @Test func sendInterruptClearsArmedModifiersWhenTheTerminalIsMissing() {
        let control = TerminalKeyboardControl()
        control.toggleModifier(.option)
        control.sendInterrupt()
        #expect(control.pendingModifiers.isEmpty)
    }
}
