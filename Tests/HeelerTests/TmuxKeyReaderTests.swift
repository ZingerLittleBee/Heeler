import Foundation
import Testing

@testable import Heeler

/// The terminal view's bytes for Direct Input and the tools keyboard, read
/// back into tmux key names and text (ADR 0043). The view encodes each key the
/// way Ghostty does for its current keyboard mode, which `TerminalKeyEncoder`
/// mirrors; whichever mode that is, the same key reads as the same name.
struct TmuxKeyReaderTests {
    private static func key(_ name: String, extended: Bool = false) -> TmuxInput {
        .key(TmuxKey(name: name, isExtended: extended))
    }

    private static func text(_ text: String) -> TmuxInput { .text(text) }

    /// The view's keyboard modes: none asked for, kitty's disambiguation
    /// alone, and every kitty flag (events, alternates, all keys, text).
    private static let modes = ["legacy": "", "kitty": "\u{1B}[>1u", "kitty all": "\u{1B}[>31u"]

    /// A key in `TerminalKeyEncoder`'s grammar, the tmux input it reads as,
    /// and what it reads as where a mode's bytes say less.
    private static let keys: [(spec: String, reads: TmuxInput, except: [String: TmuxInput])] = [
        ("a", text("a"), [:]),
        ("shift+a", text("A"), [:]),
        ("1", text("1"), [:]),
        ("shift+1", text("!"), [:]),
        ("space", text(" "), [:]),
        ("enter", key("Enter"), [:]),
        ("tab", key("Tab"), [:]),
        ("shift+tab", key("BTab"), [:]),
        ("esc", key("Escape"), [:]),
        ("backspace", key("BSpace"), [:]),
        ("up", key("Up"), [:]),
        ("down", key("Down"), [:]),
        ("left", key("Left"), [:]),
        ("right", key("Right"), [:]),
        ("home", key("Home"), [:]),
        ("end", key("End"), [:]),
        ("pageup", key("PPage"), [:]),
        ("pagedown", key("NPage"), [:]),
        ("insert", key("IC"), [:]),
        ("delete", key("DC"), [:]),
        ("f1", key("F1"), [:]),
        ("f2", key("F2"), [:]),
        ("f3", key("F3"), [:]),
        ("f4", key("F4"), [:]),
        ("f5", key("F5"), [:]),
        ("f10", key("F10"), [:]),
        ("f12", key("F12"), [:]),
        ("shift+up", key("S-Up"), [:]),
        ("ctrl+left", key("C-Left"), [:]),
        ("alt+right", key("M-Right"), [:]),
        ("ctrl+shift+right", key("C-S-Right"), [:]),
        ("shift+home", key("S-Home"), [:]),
        ("ctrl+end", key("C-End"), [:]),
        ("shift+f5", key("S-F5"), [:]),
        ("ctrl+f3", key("C-F3"), [:]),
        ("alt+f1", key("M-F1"), [:]),
        ("ctrl+delete", key("C-DC"), [:]),
        ("ctrl+a", key("C-a"), [:]),
        ("ctrl+c", key("C-c"), [:]),
        ("ctrl+j", key("C-j"), [:]),
        ("ctrl+z", key("C-z"), [:]),
        ("ctrl+space", key("C-Space"), [:]),
        ("ctrl+backslash", key(#"C-\"#), [:]),
        ("ctrl+/", key("C-/"), ["legacy": key("C-_")]),
        ("alt+a", key("M-a"), [:]),
        ("alt+shift+a", key("M-A"), [:]),
        ("alt+1", key("M-1"), [:]),
        ("alt+.", key("M-."), [:]),
        ("alt+space", key("M-Space"), [:]),
        ("ctrl+alt+a", key("C-M-a"), [:]),
        ("alt+enter", key("M-Enter"), [:]),
        ("alt+tab", key("M-Tab"), [:]),
        ("alt+backspace", key("M-BSpace"), [:]),
        ("alt+esc", key("M-Escape"), [:]),
        // No legacy encoding: tmux encodes these only in an extended mode.
        ("shift+enter", key("S-Enter", extended: true), [:]),
        ("ctrl+enter", key("C-Enter", extended: true), [:]),
        ("ctrl+shift+enter", key("C-S-Enter", extended: true), [:]),
        ("shift+space", key("S-Space", extended: true), ["legacy": text(" "), "kitty": text(" ")]),
        ("ctrl+tab", key("C-Tab", extended: true), [:]),
        ("ctrl+shift+tab", key("C-BTab", extended: true), [:]),
        ("ctrl+backspace", key("C-BSpace", extended: true), ["legacy": key("C-h")]),
        ("ctrl+shift+a", key("C-S-A", extended: true), [:]),
        ("ctrl+shift+v", key("C-S-V", extended: true), [:]),
        ("ctrl+alt+shift+a", key("C-M-S-A", extended: true), [:]),
        ("ctrl+1", key("C-1", extended: true), ["legacy": text("1")]),
        ("ctrl+.", key("C-.", extended: true), [:]),
        ("ctrl+,", key("C-,", extended: true), [:]),
        ("shift+esc", key("S-Escape", extended: true), [:]),
    ]

    @Test(arguments: modes.keys.sorted())
    func eachKeyReadsAsOneNameInEveryKeyboardMode(_ mode: String) throws {
        var modes = TerminalModeTracker()
        modes.receive(Data((Self.modes[mode] ?? "").utf8))
        for (spec, reads, except) in Self.keys {
            let bytes = try #require(TerminalKeyEncoder.encode(spec, modes: modes), "\(spec)")
            #expect(TmuxKeyReader.read(bytes) == [except[mode] ?? reads], "\(spec) in \(mode)")
        }
    }

    @Test func cursorKeysReadAlikeInApplicationMode() {
        #expect(TmuxKeyReader.read(Data("\u{1B}OA\u{1B}OD\u{1B}OH\u{1B}OF".utf8))
            == ["Up", "Left", "Home", "End"].map { Self.key($0) })
    }

    /// xterm's modifyOtherKeys form, which Ghostty also writes for a key with
    /// no legacy encoding.
    @Test func modifyOtherKeysReadsAsTheKey() {
        let cases: [(String, TmuxInput)] = [
            ("\u{1B}[27;2;13~", Self.key("S-Enter", extended: true)),
            ("\u{1B}[27;6;9~", Self.key("C-BTab", extended: true)),
            ("\u{1B}[27;2;9~", Self.key("BTab")),
            ("\u{1B}[27;6;65~", Self.key("C-S-A", extended: true)),
            ("\u{1B}[27;5;97~", Self.key("C-a")),
            ("\u{1B}[27;3;97~", Self.key("M-a")),
            ("\u{1B}[27;5;47~", Self.key("C-/")),
            ("\u{1B}[27;2;32~", Self.key("S-Space", extended: true)),
            ("\u{1B}[27;5;32~", Self.key("C-Space")),
            ("\u{1B}[27;3;127~", Self.key("M-BSpace")),
        ]
        for (bytes, reads) in cases {
            #expect(TmuxKeyReader.read(Data(bytes.utf8)) == [reads], "\(bytes.debugDescription)")
        }
    }

    @Test func controlBytesReadAsControlKeys() {
        let cases: [(UInt8, String)] = [
            (0x00, "C-Space"), (0x01, "C-a"), (0x08, "C-h"), (0x09, "Tab"), (0x0A, "C-j"), (0x0D, "Enter"),
            (0x1A, "C-z"), (0x1C, #"C-\"#), (0x1D, "C-]"), (0x1E, "C-^"), (0x1F, "C-_"), (0x7F, "BSpace"),
        ]
        for (byte, name) in cases {
            #expect(TmuxKeyReader.read(Data([byte])) == [Self.key(name)], "\(byte)")
        }
    }

    @Test func textIsReadInRunsAndNeverHoldsAControlCharacter() {
        #expect(
            TmuxKeyReader.read(Data("ls -la\r中文 👍🏽\u{1B}[Aok".utf8))
                == [Self.text("ls -la"), Self.key("Enter"), Self.text("中文 👍🏽"), Self.key("Up"), Self.text("ok")])
        #expect(TmuxKeyReader.read(Data("a\tb\nc".utf8))
            == [Self.text("a"), Self.key("Tab"), Self.text("b"), Self.key("C-j"), Self.text("c")])
        #expect(TmuxKeyReader.read(Data("a\u{85}b".utf8)) == [Self.text("ab")])
        #expect(TmuxKeyReader.read(Data([0x61, 0xFF, 0x62])) == [Self.text("ab")])
    }

    @Test func aBracketedPasteIsOnePaste() {
        #expect(
            TmuxKeyReader.read(Data("x\u{1B}[200~line one\nline \"two\"\r\n\u{1B}[201~\r".utf8))
                == [Self.text("x"), .paste("line one\nline \"two\"\r\n"), Self.key("Enter")])
        #expect(TmuxKeyReader.read(Data("\u{1B}[200~unended".utf8)) == [.paste("unended")])
    }

    /// The view answers a program's queries and reports focus and the mouse;
    /// tmux answered the program itself, and none of these is a key.
    @Test func whatIsNotAKeyIsDropped() {
        let reports = [
            "\u{1B}[12;5R", "\u{1B}[?62;22c", "\u{1B}[>1;10;0c", "\u{1B}[?1u", "\u{1B}[?2004;1$y", "\u{1B}[I",
            "\u{1B}[O", "\u{1B}[<64;10;5M", "\u{1B}[M`!!", "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\",
            "\u{1B}]10;rgb:ffff/ffff/ffff\u{07}", "\u{1B}P1+r\u{1B}\\", "\u{1B}[57441;2u", "\u{1B}[97;9u",
            "\u{1B}[97;1:3u",
        ]
        for report in reports {
            #expect(TmuxKeyReader.read(Data(report.utf8)) == [], "\(report.debugDescription)")
        }
        #expect(TmuxKeyReader.read(Data("a\u{1B}[I\u{1B}[<65;1;1Mb".utf8)) == [Self.text("ab")])
    }

    /// Escape followed by what starts no sequence is Alt with that key.
    @Test func escapeBeforeAnotherKeyIsAlt() {
        #expect(TmuxKeyReader.read(Data("\u{1B}".utf8)) == [Self.key("Escape")])
        #expect(TmuxKeyReader.read(Data("\u{1B}[".utf8)) == [Self.key("M-[")])
        #expect(TmuxKeyReader.read(Data("\u{1B}O".utf8)) == [Self.key("M-O")])
        #expect(TmuxKeyReader.read(Data("\u{1B}]".utf8)) == [Self.key("M-]")])
        #expect(TmuxKeyReader.read(Data("\u{1B}é".utf8)) == [Self.key("M-é")])
        #expect(TmuxKeyReader.read(Data("\u{1B}\u{1B}[A".utf8)) == [Self.key("M-Up")])
    }
}
