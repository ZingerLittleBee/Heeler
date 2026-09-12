import Foundation
import Testing

@testable import Heeler

/// Sticky one-shot Ctrl/Alt/Shift modifier keys for the terminal key surfaces (#270).
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

    @Test func characterKeysSendTextAndShiftedUSCaps() {
        for character in "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./ " {
            #expect(AgentQuickKey.character(character).bytes(applicationCursor: false)
                == Array(String(character).utf8))
        }
        for (base, shifted) in zip("abcdefghijklmnopqrstuvwxyz`1234567890-=[]\\;',./",
                                   "ABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+{}|:\"<>?") {
            let key = AgentQuickKey.character(base)
            #expect(key.bytes(applicationCursor: false, modifiers: .shift)
                == Array(String(shifted).utf8))
            #expect(TerminalKeyModifiers.shift.characterText(base) == String(shifted))
        }
        #expect(AgentQuickKey.character("é").bytes(applicationCursor: false) == Array("é".utf8))
        #expect(AgentQuickKey.character(" ").bytes(applicationCursor: false, modifiers: .shift) == [32])
    }

    @Test func controlLettersSendC0BytesWithOrWithoutShiftAndAlt() {
        for (index, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            let key = AgentQuickKey.character(character)
            let expected = UInt8(index + 1)
            #expect(key.bytes(applicationCursor: false, modifiers: .control) == [expected])
            #expect(key.bytes(applicationCursor: false, modifiers: [.control, .shift]) == [expected])
            #expect(key.bytes(applicationCursor: false, modifiers: [.control, .option, .shift])
                == [Self.esc, expected])
        }
    }

    @Test func controlSpaceAndPunctuationSendConventionalControlAliases() {
        let aliases: [(Character, UInt8)] = [
            (" ", 0), ("@", 0), ("`", 0), ("2", 0),
            ("[", 27), ("{", 27), ("3", 27), ("\\", 28), ("|", 28), ("4", 28),
            ("]", 29), ("}", 29), ("5", 29), ("^", 30), ("~", 30), ("6", 30),
            ("_", 31), ("/", 31), ("7", 31), ("?", 127), ("8", 127),
        ]
        for (character, byte) in aliases {
            #expect(AgentQuickKey.character(character).bytes(applicationCursor: false, modifiers: .control)
                == [byte])
        }
        #expect(AgentQuickKey.character("2").bytes(applicationCursor: false, modifiers: [.control, .shift])
            == [0])
        #expect(AgentQuickKey.character("/").bytes(applicationCursor: false, modifiers: [.control, .shift])
            == [127])
        #expect(AgentQuickKey.character("1").bytes(applicationCursor: false, modifiers: .control)
            == Array("1".utf8))
    }

    @Test func optionPrefixesCharacterAfterApplyingShift() {
        #expect(AgentQuickKey.character("b").bytes(applicationCursor: false, modifiers: .option)
            == Array("\u{1B}b".utf8))
        #expect(AgentQuickKey.character("1").bytes(applicationCursor: false, modifiers: [.option, .shift])
            == Array("\u{1B}!".utf8))
    }

    @Test func shiftCombinesWithCursorEditingAndFunctionKeyModifiers() {
        for applicationCursor in [false, true] {
            #expect(AgentQuickKey.up.bytes(applicationCursor: applicationCursor, modifiers: .shift)
                == Array("\u{1B}[1;2A".utf8))
            #expect(AgentQuickKey.left.bytes(applicationCursor: applicationCursor,
                                           modifiers: [.control, .option, .shift])
                == Array("\u{1B}[1;8D".utf8))
        }
        #expect(AgentQuickKey.pageUp.bytes(applicationCursor: false, modifiers: [.control, .shift])
            == Array("\u{1B}[5;6~".utf8))
        #expect(AgentQuickKey.pageDown.bytes(applicationCursor: false) == Array("\u{1B}[6~".utf8))
        #expect(AgentQuickKey.function(.f1).bytes(applicationCursor: false, modifiers: [.option, .shift])
            == Array("\u{1B}[1;4P".utf8))
        #expect(AgentQuickKey.function(.f12).bytes(applicationCursor: false, modifiers: .shift)
            == Array("\u{1B}[24;2~".utf8))
    }

    @Test func reverseTabIncludesShiftExactlyOnceAndEnterPreservesMultilineAction() {
        #expect(AgentQuickKey.tab.bytes(applicationCursor: false, modifiers: .shift)
            == Array("\u{1B}[Z".utf8))
        for key in [AgentQuickKey.tab, .shiftTab] {
            #expect(key.bytes(applicationCursor: false, modifiers: [.control, .shift])
                == Array("\u{1B}[1;6Z".utf8))
            #expect(key.bytes(applicationCursor: false, modifiers: [.control, .option, .shift])
                == Array("\u{1B}[1;8Z".utf8))
        }
        #expect(AgentQuickKey.shiftTab.bytes(applicationCursor: false, modifiers: .control)
            == Array("\u{1B}[1;6Z".utf8))
        for key in [AgentQuickKey.enter, .shiftEnter] {
            #expect(key.bytes(applicationCursor: false, modifiers: .shift) == [10])
            #expect(key.bytes(applicationCursor: false, modifiers: [.option, .shift]) == [Self.esc, 10])
        }
    }

    @Test func fullKeyboardSendsToTerminalAndConsumesModifiersBeforeNextCharacter() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onSend: { sent.append($0) })
        terminal.setLocalInputEnabled(false)
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        control.toggleModifier(.control)
        control.sendQuickKey(.character("c"))
        #expect(control.pendingModifiers.isEmpty)
        control.sendQuickKey(.character("c"))
        control.toggleModifier(.shift)
        control.sendQuickKey(.character("a"))
        #expect(control.pendingModifiers.isEmpty)
        control.toggleModifier(.control)
        control.toggleModifier(.option)
        control.toggleModifier(.shift)
        control.sendQuickKey(.character(" "))
        #expect(control.pendingModifiers.isEmpty)
        control.sendQuickKey(.character("b"))
        await Task.yield()
        #expect(sent == Data([3, 99, 65, Self.esc, 0, 98]))
        #expect(!terminal.isLocalInputEnabled)
    }

    @Test func characterWithoutATerminalKeepsPendingModifiers() {
        let control = TerminalKeyboardControl()
        control.toggleModifier(.shift)
        control.sendQuickKey(.character("a"))
        #expect(control.pendingModifiers == .shift)
        control.toggleModifier(.shift)
        #expect(control.pendingModifiers.isEmpty)
    }

    @Test func retappingAnArmedModifierDisarmsIt() {
        let control = TerminalKeyboardControl()
        control.toggleModifier(.control)
        #expect(control.pendingModifiers == .control)
        control.toggleModifier(.control)
        #expect(control.pendingModifiers.isEmpty)
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
