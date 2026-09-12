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

    @Test func commonShortcutsSendControlCharactersWithOptionalAlt() {
        for (key, byte) in [(AgentQuickKey.controlC, UInt8(3)), (.controlA, 1), (.controlE, 5)] {
            #expect(key.bytes(applicationCursor: false) == [byte])
            #expect(key.bytes(applicationCursor: false, modifiers: .control) == [byte])
            #expect(key.bytes(applicationCursor: false, modifiers: .option) == [Self.esc, byte])
        }
    }

    @Test func editingKeysRespectCursorModeAndModifiers() {
        #expect(AgentQuickKey.home.bytes(applicationCursor: false) == Array("\u{1B}[H".utf8))
        #expect(AgentQuickKey.home.bytes(applicationCursor: true) == Array("\u{1B}OH".utf8))
        #expect(AgentQuickKey.end.bytes(applicationCursor: true) == Array("\u{1B}OF".utf8))
        #expect(AgentQuickKey.insert.bytes(applicationCursor: false) == Array("\u{1B}[2~".utf8))
        #expect(AgentQuickKey.forwardDelete.bytes(applicationCursor: false) == Array("\u{1B}[3~".utf8))
        #expect(
            AgentQuickKey.forwardDelete.bytes(applicationCursor: true, modifiers: [.control, .option])
                == Array("\u{1B}[3;7~".utf8))
    }

    @Test func functionKeysUsePcSequencesAndConsumeModifiersThroughTheControl() async {
        let expected = [
            "\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS",
            "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~", "\u{1B}[19~",
            "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~",
        ]
        for (key, sequence) in zip(TerminalFunctionKey.allCases, expected) {
            #expect(AgentQuickKey.function(key).bytes(applicationCursor: false) == Array(sequence.utf8))
        }

        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onSend: { sent.append($0) })
        terminal.setLocalInputEnabled(false)
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        control.toggleModifier(.control)
        control.toggleModifier(.option)
        control.sendQuickKey(.function(.f1))
        #expect(control.pendingModifiers.isEmpty)
        control.sendQuickKey(.function(.f12))
        await Task.yield()
        #expect(sent == Data("\u{1B}[1;7P\u{1B}[24~".utf8))
    }

    @Test func shortcutsBypassDraftInputWithoutEnablingTerminalTyping() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onSend: { sent.append($0) })
        terminal.setLocalInputEnabled(false)
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        for key in [AgentQuickKey.controlC, .controlA, .controlE] {
            control.sendQuickKey(key)
        }
        await Task.yield()
        #expect(sent == Data([3, 1, 5]))
        #expect(!terminal.isLocalInputEnabled)
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
