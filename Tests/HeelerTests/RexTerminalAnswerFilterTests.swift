import Foundation
import Testing

@testable import Heeler

/// What reaches a Rex terminal of the bytes Heeler's view writes, once input
/// opens (ADR 0049): the emulator's answers to queries never, keys, text,
/// mouse reports and pastes always.
@Suite("Rex terminal answer filter")
struct RexTerminalAnswerFilterTests {
    private func kept(_ text: String) -> String {
        String(decoding: RexTerminalAnswerFilter.keystrokes(in: Data(text.utf8)), as: UTF8.self)
    }

    static let answers = [
        "\u{1B}[?62;22;52c",  // primary device attributes
        "\u{1B}[>1;10;0c",  // secondary device attributes
        "\u{1B}[0n",  // status report
        "\u{1B}[24;80R",  // cursor position
        "\u{1B}[?24;80;1R",  // cursor position with page
        "\u{1B}[?2004;2$y",  // a private mode's state
        "\u{1B}[4;2$y",  // an ANSI mode's state
        "\u{1B}[?997;1n",  // color scheme
        "\u{1B}[8;24;80t",  // text area size
        "\u{1B}[48;24;80;432;720t",  // in-band size
        "\u{1B}[2;1;1;112;112;1;0x",  // terminal parameters
        "\u{1B}[?5u",  // kitty keyboard flags
        "\u{1B}[I", "\u{1B}[O",  // focus in and out
        "\u{1B}]11;rgb:1010/1010/1010\u{1B}\\",  // background color, ST
        "\u{1B}]4;1;rgb:aaaa/2020/2020\u{07}",  // a palette color, BEL
        "\u{1B}P>|ghostty 1.2\u{1B}\\",  // terminal version
        "\u{1B}P1$r0m\u{1B}\\",  // a setting's value
        "\u{1B}_Gi=1;OK\u{1B}\\",  // a graphics answer
    ]

    @Test(arguments: Self.answers)
    func anAnswerNeverLeaves(_ answer: String) {
        #expect(kept(answer) == "")
        #expect(kept("a" + answer + "b") == "ab")
    }

    static let keys = [
        "ls -la\r", "\u{03}", "\u{1B}", "\u{7F}", "\t", "é漢",
        "\u{1B}[A", "\u{1B}OA", "\u{1B}[1;5C", "\u{1B}[15~", "\u{1B}[3;2~", "\u{1B}[Z",
        "\u{1B}OR",  // F3
        "\u{1B}[97;5u", "\u{1B}[27;5;97~", "\u{1B}[13;2u",  // kitty and modifyOtherKeys
        "\u{1B}b",  // Alt+b
        "\u{1B}]", "\u{1B}P", "\u{1B}_", "\u{1B}^", "\u{1B}X", "\u{1B}[",  // Alt with ], P, _, ^, X and [
        "\u{1B}[<0;12;5M", "\u{1B}[<64;3;4M", "\u{1B}[<0;12;5m",  // SGR mouse press, wheel, release
        "\u{1B}[M !!",  // X10 mouse
    ]

    @Test(arguments: Self.keys)
    func aKeyLeavesAsWritten(_ key: String) {
        #expect(kept(key) == key)
    }

    /// A paste goes whole, whatever it holds.
    @Test func aBracketedPasteLeavesWhole() {
        let paste = "\u{1B}[200~echo \u{1B}[6n done\u{1B}[201~"
        #expect(kept(paste + "\r") == paste + "\r")
    }

    /// Ghostty writes an answer in one piece, so a string with no terminator
    /// is an Alt key and what follows it.
    @Test func aStringWithoutItsTerminatorIsAKey() {
        #expect(kept("x\u{1B}]11") == "x\u{1B}]11")
        #expect(kept("\u{1B}[c\u{1B}P") == "\u{1B}P")
    }

    /// Legacy Shift+F3 shares its form with a cursor report, and goes with it,
    /// as tmux input reads it.
    @Test func legacyShiftF3ReadsAsACursorReport() {
        #expect(kept("\u{1B}[1;2R") == "")
    }

    @Test func inputIsShutInThisBuild() {
        #expect(!RexTerminalInput.isOpen)
    }
}
