import Foundation
import Testing

@testable import Heeler

/// What a key named in herdr-core's `submit` grammar becomes. `TerminalKeyModifiersTests`
/// holds the same encoder against a live Ghostty surface across the whole grammar.
struct TerminalKeyEncoderTests {
    private func modes(_ output: String = "") -> TerminalModeTracker {
        var tracker = TerminalModeTracker()
        tracker.receive(Data(output.utf8))
        return tracker
    }

    private func encoded(_ spec: String, after output: String = "") -> String? {
        TerminalKeyEncoder.encode(spec, modes: modes(output)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func enterIsCarriageReturnUntilTheProgramAsksForEveryKeyAsAnEscapeCode() {
        #expect(encoded("enter") == "\r")
        #expect(encoded("enter", after: "\u{1B}[>1u") == "\r")
        #expect(encoded("enter", after: "\u{1B}[>8u") == "\u{1B}[13u")
        #expect(encoded("enter", after: "\u{1B}[>8u\u{1B}[<u") == "\r")
    }

    @Test func eachScreenHasItsOwnKeyboardMode() {
        #expect(encoded("enter", after: "\u{1B}[?1049h\u{1B}[>8u") == "\u{1B}[13u")
        #expect(encoded("enter", after: "\u{1B}[?1049h\u{1B}[>8u\u{1B}[?1049l") == "\r")
    }

    @Test func aTemplatesSubmitKeyFollowsTheCoresGrammar() {
        #expect(encoded("ctrl+s") == "\u{13}")
        #expect(encoded("CTRL+S") == "\u{13}")
        #expect(encoded("control+s") == "\u{13}")
        #expect(encoded("return") == "\r")
        #expect(encoded("ctrl+enter") == "\u{1B}[27;5;13~")
        #expect(encoded("alt+enter") == "\u{1B}\r")
        #expect(encoded("meta+enter") == "\u{1B}\r")
        #expect(encoded("opt+enter") == "\u{1B}\r")
        #expect(encoded("shift+enter") == "\u{1B}[27;2;13~")
        #expect(encoded("ctrl+enter", after: "\u{1B}[>1u") == "\u{1B}[13;5u")
        #expect(encoded("cmd+enter", after: "\u{1B}[>1u") == "\u{1B}[13;9u")
        #expect(encoded("super+enter", after: "\u{1B}[>1u") == "\u{1B}[13;9u")
        #expect(encoded("ctrl+s", after: "\u{1B}[>1u") == "\u{1B}[115;5u")
        #expect(encoded("tab") == "\t")
        #expect(encoded("backslash") == "\\")
    }

    /// The core's own test of its grammar (`keys.rs`), bytes included.
    @Test func theCoresOwnKeysEncodeAlike() {
        let keys = [
            "enter": "\r", "esc": "\u{1B}", "tab": "\t", "backspace": "\u{7F}", "a": "a", "shift+a": "A", "7": "7",
            "ctrl+c": "\u{3}", "alt+x": "\u{1B}x", "up": "\u{1B}[A", "f1": "\u{1B}OP", "space": " ",
        ]
        for (name, bytes) in keys { #expect(encoded(name) == bytes, "\(name)") }
        #expect(encoded("up", after: "\u{1B}[?1h") == "\u{1B}OA")
        #expect(encoded("left", after: "\u{1B}[?1h") == "\u{1B}OD")
        #expect(encoded("esc", after: "\u{1B}[>1u") == "\u{1B}[27u")
        #expect(encoded("ctrl+backslash", after: "\u{1B}[>1u") == "\u{1B}[92;5u")
    }

    @Test func aKeyOutsideTheGrammarEncodesToNothing() {
        for name in ["hello", "hyper+x", "f13", "f0", "ctrl+", "", "+", "é", "ctrl+é"] {
            #expect(encoded(name) == nil, "\(name)")
        }
    }

    @Test func aKeyNoTerminalSendsEncodesToNothing() {
        #expect(encoded("super+a") == nil)
    }
}
