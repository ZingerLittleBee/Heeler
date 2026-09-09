import Foundation
import Testing

@testable import Heeler

/// Sticky one-shot ⌃/⌥ modifier keys for the terminal key surfaces (#270).
@MainActor
@Suite("Terminal key modifiers")
struct TerminalKeyModifiersTests {
    private static let esc: UInt8 = 0x1B

    @Test func controlLeftSendsXtermModifierFive() {
        let bytes = AgentQuickKey.left.bytes(
            applicationCursor: false, modifiers: .control)
        #expect(bytes == [Self.esc, 0x5B, 0x31, 0x3B, 0x35, 0x44])
    }

    @Test func optionLeftSendsXtermModifierThree() {
        let bytes = AgentQuickKey.left.bytes(
            applicationCursor: false, modifiers: .option)
        #expect(bytes == [Self.esc, 0x5B, 0x31, 0x3B, 0x33, 0x44])
    }

    @Test func bothModifiersCombineToModifierSeven() {
        let bytes = AgentQuickKey.left.bytes(
            applicationCursor: false, modifiers: [.control, .option])
        #expect(bytes == [Self.esc, 0x5B, 0x31, 0x3B, 0x37, 0x44])
    }

    @Test func optionBackspacePrefixesEscapeBeforeTheBareBytes() {
        let bare = AgentQuickKey.backspace.bytes(applicationCursor: false)
        let modified = AgentQuickKey.backspace.bytes(
            applicationCursor: false, modifiers: .option)
        #expect(modified == [Self.esc] + bare)
    }

    @Test func enterAndTabAreUnchangedUnderControl() {
        for key in [AgentQuickKey.enter, AgentQuickKey.tab] {
            let bare = key.bytes(applicationCursor: false)
            let modified = key.bytes(
                applicationCursor: false, modifiers: .control)
            #expect(modified == bare)
        }
    }

    @Test func retappingAnArmedModifierDisarmsIt() {
        let control = TerminalKeyboardControl()
        control.toggleModifier(.control)
        #expect(control.pendingModifiers == .control)
        control.toggleModifier(.control)
        #expect(control.pendingModifiers.isEmpty)
    }

    @Test func sendingAQuickKeyConsumesTheArmedModifiers() {
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: NotificationCenter())
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        control.toggleModifier(.control)
        control.toggleModifier(.option)
        #expect(control.pendingModifiers == [.control, .option])
        control.sendQuickKey(.left)
        #expect(control.pendingModifiers.isEmpty)
    }
}
