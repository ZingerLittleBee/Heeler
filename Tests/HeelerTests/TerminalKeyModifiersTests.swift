import Foundation
import Testing
import UIKit

@testable import Heeler

/// Exercises the keyboard controls through a live Ghostty surface and its output callback.
@MainActor
@Suite("Terminal key modifiers", .serialized)
struct TerminalKeyModifiersTests {
    @Test func characterKeysSendTextAndShiftedUSCaps() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./ "
        for character in characters {
            fixture.control.sendQuickKey(.character(character))
        }
        #expect(try await fixture.drain() == Data(characters.utf8))

        let unshifted = "abcdefghijklmnopqrstuvwxyz`1234567890-=[]\\;',./ "
        let shifted = "ABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+{}|:\"<>? "
        for character in unshifted {
            fixture.send(.character(character), modifiers: .shift)
        }
        #expect(try await fixture.drain() == Data(shifted.utf8))
    }

    @Test func controlLettersUseGhosttyEncodingAndPreserveShift() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        for character in "abcdefghijklmnopqrstuvwxyz" {
            fixture.send(.character(character), modifiers: .control)
        }
        // Ghostty's default fixterms encoding distinguishes Ctrl-I from Tab
        // and Ctrl-M from Enter, even before Kitty reporting is requested.
        let expected = Data([1, 2, 3, 4, 5, 6, 7, 8])
            + Data("\u{1B}[105;5u".utf8) + Data([10, 11, 12])
            + Data("\u{1B}[109;5u".utf8) + Data(14...26)
        #expect(try await fixture.drain() == expected)

        fixture.send(.character("c"), modifiers: [.control, .shift])
        fixture.send(.character("c"), modifiers: [.control, .option, .shift])
        fixture.send(.character("j"), modifiers: [.control, .shift])
        #expect(try await fixture.drain() == Data(
            "\u{1B}[99;6u\u{1B}[99;8u\u{1B}[106;6u".utf8))
        #expect(fixture.control.pendingModifiers.isEmpty)
    }

    @Test func controlSpaceAndPunctuationUseGhosttyAliasesAndFixterms() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let aliases: [(Character, UInt8)] = [
            (" ", 0), ("2", 0), ("3", 27), ("\\", 28), ("4", 28),
            ("]", 29), ("5", 29), ("^", 30), ("~", 30), ("6", 30),
            ("_", 31), ("/", 31), ("7", 31), ("?", 127), ("8", 127),
        ]
        for (character, expected) in aliases {
            fixture.send(.character(character), modifiers: .control)
            let actual = try await fixture.drain()
            #expect(Array(actual) == [expected], "Ctrl+\(character)")
        }
        // These combinations retain their identity instead of collapsing
        // to the legacy NUL, Escape, or bracket control aliases.
        for character in "@`[{|}" {
            fixture.send(.character(character), modifiers: .control)
        }
        #expect(try await fixture.drain() == Data(
            "\u{1B}[64;5u\u{1B}[96;5u\u{1B}[91;5u\u{1B}[123;5u\u{1B}[124;5u\u{1B}[125;5u".utf8))
        fixture.send(.character("2"), modifiers: [.control, .shift])
        fixture.send(.character("/"), modifiers: [.control, .shift])
        #expect(try await fixture.drain() == Data("\u{1B}[64;5u".utf8) + Data([127]))
    }

    @Test func optionPrefixesCharactersAndBackspace() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        fixture.send(.character("b"), modifiers: .option)
        fixture.send(.character("1"), modifiers: [.option, .shift])
        fixture.send(.backspace, modifiers: .option)
        #expect(try await fixture.drain() == Data([0x1B, 98, 0x1B, 33, 0x1B, 127]))
    }

    @Test func cursorKeysFollowApplicationCursorModeAndModifiers() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        for (mode, bare) in [("\u{1B}[?1l", "\u{1B}[D\u{1B}[A\u{1B}[H\u{1B}[F"),
                             ("\u{1B}[?1h", "\u{1B}OD\u{1B}OA\u{1B}OH\u{1B}OF")] {
            fixture.receive(mode)
            for key: AgentQuickKey in [.left, .up, .home, .end] {
                fixture.control.sendQuickKey(key)
            }
            #expect(try await fixture.drain() == Data(bare.utf8))
            fixture.send(.left, modifiers: .control)
            fixture.send(.left, modifiers: .option)
            fixture.send(.left, modifiers: [.control, .option])
            fixture.send(.up, modifiers: .shift)
            fixture.send(.left, modifiers: [.control, .option, .shift])
            #expect(try await fixture.drain() == Data(
                "\u{1B}[1;5D\u{1B}[1;3D\u{1B}[1;7D\u{1B}[1;2A\u{1B}[1;8D".utf8))
        }
    }

    @Test func appearanceChangesKeepRemoteKeyRouting() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        // Configuration updates replace Ghostty's overrides. Zoom and font
        // changes must keep desktop bindings disabled and preserve each other.
        #expect(fixture.terminal.applyFontSize(18))
        _ = try await fixture.drain()
        fixture.send(.left, modifiers: .option)
        fixture.send(.character("c"), modifiers: [.control, .shift])
        #expect(try await fixture.drain() == Data("\u{1B}[1;3D\u{1B}[99;6u".utf8))

        #expect(fixture.terminal.applyFontFamily("Menlo"))
        _ = try await fixture.drain()
        fixture.send(.left, modifiers: .option)
        fixture.send(.character("j"), modifiers: [.control, .shift])
        #expect(try await fixture.drain() == Data("\u{1B}[1;3D\u{1B}[106;6u".utf8))
        #expect(fixture.terminal.appliedFontSize == 18)
        #expect(fixture.terminal.appliedFontFamily == "Menlo")
    }

    @Test func editingKeysAndRepeatedBackspaceSendOnePressPerInvocation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        for key: AgentQuickKey in [.insert, .forwardDelete, .pageUp, .pageDown] {
            fixture.control.sendQuickKey(key)
        }
        fixture.send(.forwardDelete, modifiers: [.control, .option])
        fixture.send(.pageUp, modifiers: [.control, .shift])
        #expect(try await fixture.drain() == Data(
            "\u{1B}[2~\u{1B}[3~\u{1B}[5~\u{1B}[6~\u{1B}[3;7~\u{1B}[5;6~".utf8))
        for _ in 0..<5 { fixture.control.sendQuickKey(.backspace) }
        #expect(try await fixture.drain() == Data(repeating: 127, count: 5))
    }

    @Test func functionKeysSendF1ThroughF12AndConsumeModifiers() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let expected = [
            "\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS",
            "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~", "\u{1B}[19~",
            "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~",
        ]
        for (key, sequence) in zip(TerminalFunctionKey.allCases, expected) {
            fixture.control.sendQuickKey(.function(key))
            #expect(try await fixture.drain() == Data(sequence.utf8), "\(key)")
        }
        fixture.send(.function(.f1), modifiers: [.control, .option])
        #expect(fixture.control.pendingModifiers.isEmpty)
        fixture.send(.function(.f12), modifiers: .shift)
        #expect(fixture.control.pendingModifiers.isEmpty)
        #expect(try await fixture.drain() == Data("\u{1B}[1;7P\u{1B}[24;2~".utf8))
    }

    @Test func reverseTabAndMultilineEnterKeepAgentActions() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        fixture.control.sendQuickKey(.tab)
        fixture.send(.tab, modifiers: .shift)
        fixture.control.sendQuickKey(.shiftTab)
        #expect(try await fixture.drain() == Data("\t\u{1B}[Z\u{1B}[Z".utf8))
        fixture.control.sendQuickKey(.enter)
        fixture.control.sendQuickKey(.shiftEnter)
        fixture.send(.enter, modifiers: .shift)
        fixture.send(.shiftEnter, modifiers: .shift)
        fixture.send(.enter, modifiers: [.option, .shift])
        #expect(try await fixture.drain() == Data([13, 10, 10, 10, 0x1B, 10]))
    }

    @Test func quickKeysConsumeModifiersOnceWithoutEnablingComposerInput() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        fixture.terminal.setLocalInputEnabled(false)
        fixture.send(.character("c"), modifiers: .control)
        #expect(fixture.control.pendingModifiers.isEmpty)
        fixture.control.sendQuickKey(.character("c"))
        fixture.send(.character("a"), modifiers: .shift)
        #expect(fixture.control.pendingModifiers.isEmpty)
        fixture.control.sendQuickKey(.character("b"))
        #expect(try await fixture.drain() == Data([3, 99, 65, 98]))
        #expect(!fixture.terminal.isLocalInputEnabled)
        #expect(!fixture.terminal.isFirstResponder)
    }

    @Test func shellKeysRequireLocalInputAndFollowTerminalReplacement() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        fixture.terminal.setLocalInputEnabled(false)
        fixture.control.toggleModifier(.control)
        fixture.control.sendTerminalKey(.character("c"))
        #expect(fixture.control.pendingModifiers == .control)
        #expect(try await fixture.drain().isEmpty)
        fixture.terminal.setLocalInputEnabled(true)
        fixture.control.sendTerminalKey(.character("c"))
        #expect(fixture.control.pendingModifiers.isEmpty)
        #expect(try await fixture.drain() == Data([3]))

        let replacement = try await Fixture.make()
        defer { replacement.close() }
        replacement.terminal.setLocalInputEnabled(true)
        fixture.control.terminal = replacement.terminal
        fixture.control.toggleModifier(.shift)
        fixture.control.sendTerminalKey(.character("a"))
        #expect(try await replacement.drain() == Data("A".utf8))
        #expect(try await fixture.drain().isEmpty)
        #expect(fixture.control.pendingModifiers.isEmpty)
    }

    @Test func missingTerminalOrSurfaceRetainsPendingModifiers() {
        let control = TerminalKeyboardControl()
        control.toggleModifier(.shift)
        control.sendQuickKey(.character("a"))
        #expect(control.pendingModifiers == .shift)
        control.sendTerminalKey(.character("a"))
        #expect(control.pendingModifiers == .shift)

        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setLocalInputEnabled(true)
        control.terminal = terminal
        control.sendQuickKey(.character("a"))
        #expect(control.pendingModifiers == .shift)
        control.sendTerminalKey(.character("a"))
        #expect(control.pendingModifiers == .shift)
    }

    @Test func retappingArmedModifiersDisarmsThem() {
        let control = TerminalKeyboardControl()
        for modifier: TerminalKeyModifiers in [.control, .option, .shift] {
            control.toggleModifier(modifier)
            #expect(control.pendingModifiers == modifier)
            control.toggleModifier(modifier)
            #expect(control.pendingModifiers.isEmpty)
        }
    }

    @Test func kittyProtocolReportsPressAndReleaseWithoutPasteFraming() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        // Disambiguate, report event types, and report all keys. Bracketed paste
        // must not turn Enter or a character into pasted text.
        fixture.receive("\u{1B}[?2004h\u{1B}[>11u")
        fixture.control.sendQuickKey(.enter)
        fixture.send(.character("c"), modifiers: .control)
        fixture.control.sendQuickKey(.character("a"))
        #expect(try await fixture.drain() == Data(
            "\u{1B}[13u\u{1B}[13;1:3u\u{1B}[99;5u\u{1B}[99;5:3u\u{1B}[97u\u{1B}[97;1:3u".utf8))
        #expect(fixture.control.pendingModifiers.isEmpty)
        fixture.receive("\u{1B}[<u")
        fixture.control.sendQuickKey(.enter)
        #expect(try await fixture.drain() == Data([13]))
    }

    @MainActor
    private final class Fixture {
        let terminal: HeelerTerminalView
        let control = TerminalKeyboardControl()
        private var sent = Data()
        private var window: UIWindow?

        private init() {
            terminal = TerminalScreenView.makeConfiguredTerminal()
            terminal.updateCallbacks(
                onSizeChanged: nil,
                onViewportTextChanged: nil,
                onSend: { [weak self] bytes in self?.sent.append(bytes) },
                onScroll: nil,
                onPaste: nil)
            control.terminal = terminal
        }

        static func make() async throws -> Fixture {
            let fixture = Fixture()
            let controller = UIViewController()
            controller.view = fixture.terminal
            fixture.window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 600),
                rootViewController: controller)
            controller.view.layoutIfNeeded()
            // A terminal reply proves the surface exists and callbacks can reach
            // the host before the test starts sending keys.
            _ = try await fixture.drain()
            return fixture
        }

        func close() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }

        func send(_ key: AgentQuickKey, modifiers: TerminalKeyModifiers) {
            for modifier: TerminalKeyModifiers in [.control, .option, .shift] where modifiers.contains(modifier) {
                control.toggleModifier(modifier)
            }
            control.sendQuickKey(key)
        }

        func receive(_ output: String) {
            terminal.receive(Data(output.utf8))
            // Ghostty processes incoming mode changes off the main actor.
            // A task yield cannot establish that the encoder has seen them.
            terminal.terminalSession.waitForPendingOutput()
        }

        func drain() async throws -> Data {
            // DA is ordered behind prior keys. Wait for its response as a
            // positive completion signal, including for an expected empty send.
            receive("\u{1B}[c")
            let marker = Data("\u{1B}[?62;22".utf8)
            let deadline = ContinuousClock.now + .seconds(2)
            while sent.range(of: marker) == nil, ContinuousClock.now < deadline {
                await Task.yield()
            }
            let reply = try #require(sent.range(of: marker), "Ghostty device attributes reply did not arrive")
            let result = Data(sent[..<reply.lowerBound])
            sent.removeAll(keepingCapacity: true)
            return result
        }
    }
}
