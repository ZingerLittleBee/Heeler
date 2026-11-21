import Foundation
import Testing

@testable import Heeler

/// What leaves for a Rex terminal of the bytes Heeler's view writes (ADR
/// 0051): the emulator's answers to queries never; keys, text and mouse
/// reports as valid text; focus reports, pastes and mouse reports text cannot
/// carry as events; never invalid UTF-8.
@Suite("Rex terminal key reader")
struct RexTerminalKeyReaderTests {
    private func read(_ bytes: [UInt8], budget: Int = 1 << 20) -> [RexTerminalInputPiece] {
        var reader = RexTerminalKeyReader(budget: budget)
        return reader.read(Data(bytes))
    }

    private func read(_ text: String, budget: Int = 1 << 20) -> [RexTerminalInputPiece] {
        read(Array(text.utf8), budget: budget)
    }

    /// The text of `pieces` when they are all text.
    private func text(_ pieces: [RexTerminalInputPiece]) -> String? {
        var joined = ""
        for piece in pieces {
            guard case .text(let text) = piece else { return nil }
            joined += text
        }
        return joined
    }

    // MARK: Answers

    /// The answers the query lab capture recorded from a Rex terminal (Rex
    /// 0.1.0-preview.14), which Heeler's own emulator writes in the same forms.
    static let labAnswers = [
        "\u{1B}[?62;22c",  // primary device attributes
        "\u{1B}[>1;0;0c",  // secondary device attributes
        "\u{1B}[2;1R",  // cursor position
        "\u{1B}[0n",  // status
        "\u{1B}P>|lab 1.0\u{1B}\\",  // version, a DCS string
        "\u{1B}]4;1;rgb:cccc/6666/6666\u{1B}\\",  // a palette color
        "\u{1B}[?2004;2$y",  // a mode's state
        "\u{1B}[?0u",  // kitty keyboard flags
    ]

    static let otherAnswers = [
        "\u{1B}[?62;22;52c",  // primary device attributes with more features
        "\u{1B}[>1;10;0c",  // secondary device attributes
        "\u{1B}P!|00000000\u{1B}\\",  // tertiary device attributes
        "\u{1B}[24;80R",  // cursor position
        "\u{1B}[?24;80;1R",  // cursor position with page
        "\u{1B}[4;2$y",  // an ANSI mode's state
        "\u{1B}[?997;1n",  // color scheme
        "\u{1B}[8;24;80t",  // text area size
        "\u{1B}[4;480;640t",  // text area size in pixels
        "\u{1B}[6;20;10t",  // cell size
        "\u{1B}[48;24;80;432;720t",  // in-band size
        "\u{1B}[2;1;1;112;112;1;0x",  // terminal parameters
        "\u{1B}[?5u",  // kitty keyboard flags
        "\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\",  // foreground color
        "\u{1B}]11;rgb:1010/1010/1010\u{1B}\\",  // background color, ST
        "\u{1B}]12;rgb:ffff/ffff/ffff\u{07}",  // cursor color, BEL
        "\u{1B}]4;1;rgb:aaaa/2020/2020\u{07}",  // a palette color, BEL
        "\u{1B}]52;c;aGk=\u{1B}\\",  // clipboard contents
        "\u{1B}P>|ghostty 1.2\u{1B}\\",  // terminal version
        "\u{1B}P1$r0m\u{1B}\\",  // a setting's value
        "\u{1B}P1+r544e=787465726d\u{1B}\\",  // a terminfo capability
        "\u{1B}_Gi=1;OK\u{1B}\\",  // a graphics answer
    ]

    @Test(arguments: Self.labAnswers + Self.otherAnswers)
    func anAnswerNeverLeaves(_ answer: String) {
        #expect(read(answer).isEmpty)
        #expect(read("a" + answer + "b") == [.text("ab")])
    }

    /// Legacy Shift+F3 shares its form with a cursor report, and goes with it,
    /// as tmux input reads it.
    @Test func legacyShiftF3ReadsAsACursorReport() {
        #expect(read("\u{1B}[1;2R").isEmpty)
    }

    // MARK: Keys

    static let keys = [
        "ls -la\r", "\u{03}", "\u{1B}", "\u{7F}", "\t", "é漢", "🦀",
        "\u{1B}[A", "\u{1B}OA", "\u{1B}[1;5C", "\u{1B}[15~", "\u{1B}[3;2~", "\u{1B}[Z",
        "\u{1B}OR",  // F3
        "\u{1B}[97;5u", "\u{1B}[27;5;97~", "\u{1B}[13;2u",  // kitty and modifyOtherKeys
        "\u{1B}b", "\u{1B}\r",  // Alt+b, Alt+Enter
        "\u{1B}]", "\u{1B}P", "\u{1B}_", "\u{1B}^", "\u{1B}X", "\u{1B}[",  // Alt with ], P, _, ^, X and [
        "\u{1B}[<0;12;5M", "\u{1B}[<64;3;4M", "\u{1B}[<0;12;5m",  // SGR mouse press, wheel, release
        "\u{1B}[M !!", "\u{1B}[M`&$",  // legacy mouse press and wheel inside column 95
    ]

    @Test(arguments: Self.keys)
    func aKeyLeavesAsWritten(_ key: String) {
        #expect(read(key) == [.text(key)])
    }

    /// Ghostty writes an answer in one piece, so a string with no terminator
    /// is an Alt key and what follows it.
    @Test func aStringWithoutItsTerminatorIsAKey() {
        #expect(read("x\u{1B}]11") == [.text("x\u{1B}]11")])
        #expect(read("\u{1B}[c\u{1B}P") == [.text("\u{1B}P")])
    }

    // MARK: Events and pastes

    @Test func focusReportsBecomeFocusEvents() {
        #expect(read("\u{1B}[I") == [.event(type: "focus", payload: ["action": "in"])])
        #expect(
            read("a\u{1B}[Ob") == [
                .text("a"), .event(type: "focus", payload: ["action": "out"]), .text("b"),
            ])
    }

    /// Bracket markers in the bytes never leave: the paste goes as itself, for
    /// the server to frame, whatever it holds.
    @Test func aBracketedPasteBecomesAPaste() {
        let pieces = read("\u{1B}[200~echo \u{1B}[6n done\u{1B}[201~\r")
        #expect(pieces == [.paste("echo \u{1B}[6n done"), .text("\r")])
    }

    // MARK: Invalid UTF-8

    /// A byte that is not part of valid UTF-8 is an 8-bit Meta key, and goes
    /// as ESC and the byte without its high bit.
    @Test func aStrayHighByteIsAMetaKey() {
        #expect(read([0xE1]) == [.text("\u{1B}a")])
        #expect(read([0x61, 0xC3, 0x62]) == [.text("a\u{1B}Cb")])
        #expect(read([0xFF]) == [.text("\u{1B}\u{7F}")])
        // Overlong and surrogate forms are not characters.
        #expect(read([0xC0, 0x80]) == [.text("\u{1B}@\u{1B}\u{00}")])
        #expect(read([0xED, 0xA0, 0x80]) == [.text("\u{1B}m\u{1B} \u{1B}\u{00}")])
        // Cut short at the end of a write: Ghostty never splits a character.
        #expect(read([0xE6, 0xBC]) == [.text("\u{1B}f\u{1B}<")])
    }

    /// A legacy mouse report past column or row 95 is not valid text, and
    /// becomes the event it reports; its release names the last press.
    @Test func aWideLegacyMouseReportBecomesAnEvent() {
        var reader = RexTerminalKeyReader(budget: 1 << 20)
        let press = reader.read(Data([0x1B, 0x5B, 0x4D, 0x22, 0xA0, 0x30]))
        let release = reader.read(Data([0x1B, 0x5B, 0x4D, 0x23, 0xA0, 0x30]))
        let drag = reader.read(Data([0x1B, 0x5B, 0x4D, 0x40, 0xA1, 0x30]))
        let shiftCtrlPress = reader.read(Data([0x1B, 0x5B, 0x4D, 0x34, 0xC8, 0x21]))
        #expect(press == [.event(type: "mouse", payload: ["action": "press", "button": "right", "x": 127, "y": 15])])
        #expect(
            release == [.event(type: "mouse", payload: ["action": "release", "button": "right", "x": 127, "y": 15])])
        #expect(
            drag == [
                .event(type: "mouse", payload: ["action": "motion", "buttons": ["left": true], "x": 128, "y": 15])
            ])
        #expect(
            shiftCtrlPress == [
                .event(
                    type: "mouse",
                    payload: ["action": "press", "button": "left", "x": 167, "y": 0, "mods": "shift+ctrl"])
            ])
    }

    @Test func aWideLegacyWheelReportBecomesAWheelEvent() {
        let up = read([0x1B, 0x5B, 0x4D, 0x60, 0xC8, 0x21])
        let down = read([0x1B, 0x5B, 0x4D, 0x61, 0x21, 0xB0])
        let right = read([0x1B, 0x5B, 0x4D, 0x63, 0xC8, 0x21])
        #expect(up == [.event(type: "wheel", payload: ["delta_y": -1, "delta_mode": "line", "x": 167, "y": 0])])
        #expect(down == [.event(type: "wheel", payload: ["delta_y": 1, "delta_mode": "line", "x": 0, "y": 143])])
        #expect(right == [.event(type: "wheel", payload: ["delta_x": 1, "delta_mode": "line", "x": 167, "y": 0])])
    }

    /// A mouse report in the UTF-8 encoding (DECSET 1005) is valid text,
    /// whose values past 95 take two bytes each: it goes whole, as written,
    /// and no byte of it is left over to read as a key.
    @Test func aUTF8MouseReportGoesWholeAsText() {
        // Column 100, row 5: the column is U+0085.
        #expect(read([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0x85, 0x26]) == [.text("\u{1B}[M \u{85}&")])
        #expect(read([0x1B, 0x5B, 0x4D, 0x23, 0xC2, 0x85, 0x26]) == [.text("\u{1B}[M#\u{85}&")])
        // Column 33, row 96: the row is U+0080.
        #expect(read([0x1B, 0x5B, 0x4D, 0x20, 0x41, 0xC2, 0x80]) == [.text("\u{1B}[M A\u{80}")])
        #expect(read([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0x85, 0xC2, 0x85]) == [.text("\u{1B}[M \u{85}\u{85}")])
        // A wheel report and an extra button, whose button byte is past 95 too.
        #expect(read([0x1B, 0x5B, 0x4D, 0x60, 0xC3, 0x88, 0x21]) == [.text("\u{1B}[M`\u{C8}!")])
        #expect(read([0x1B, 0x5B, 0x4D, 0xC2, 0xA0, 0x21, 0x21]) == [.text("\u{1B}[M\u{A0}!!")])
    }

    /// Whatever the bytes, each text piece stays within the budget, and
    /// bytes with no ESC among them all leave, each high byte that is not
    /// part of a character as Meta.
    @Test func anyBytesLeaveWithinTheBudget() {
        var generator = SystemRandomNumberGenerator()
        var reader = RexTerminalKeyReader(budget: 256)
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 1...64, using: &generator)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            }
            for case .text(let piece) in reader.read(Data(bytes)) {
                #expect(RexTerminalKeyReader.jsonCost(of: piece.utf8) <= 256)
            }
            let plain = bytes.filter { $0 != 0x1B }
            let sent = text(reader.read(Data(plain))) ?? ""
            #expect(sent.utf8.count >= plain.count)
        }
    }

    // MARK: Wheel by mode

    /// With no mouse tracking on the primary screen a touch scroll has no
    /// remote sequence, so it scrolls the view's own scrollback. Under
    /// tracking it is the program's wheel report: text in SGR, and an event
    /// when a legacy report runs past column 95.
    @Test func wheelReportsFollowTheProgramsMouseMode() throws {
        var tracker = TerminalModeTracker()
        #expect(tracker.remoteScrollSequence(towardOlderContent: true, columns: 80, rows: 24) == nil)

        tracker.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let sgr = try #require(tracker.remoteScrollSequence(towardOlderContent: true, columns: 80, rows: 24))
        #expect(read(Array(sgr)) == [.text("\u{1B}[<64;40;12M")])

        tracker.receive(Data("\u{1B}[?1006l".utf8))
        let narrow = try #require(tracker.remoteScrollSequence(towardOlderContent: false, columns: 80, rows: 24))
        #expect(read(Array(narrow)) == [.text(String(decoding: narrow, as: UTF8.self))])
        let wide = try #require(tracker.remoteScrollSequence(towardOlderContent: false, columns: 200, rows: 24))
        #expect(
            read(Array(wide))
                == [.event(type: "wheel", payload: ["delta_y": 1, "delta_mode": "line", "x": 99, "y": 11])])
    }

    // MARK: Budget and merging

    /// Text is cut only between characters and whole escape sequences, each
    /// piece within the budget, and nothing is lost.
    @Test func textIsCutOnlyBetweenUnits() {
        let sequence = "\u{1B}[1;5C"
        let input = String(repeating: "é", count: 30) + sequence + String(repeating: "\"", count: 30) + "漢字"
        let pieces = read(input, budget: 64)
        #expect(pieces.count > 1)
        #expect(text(pieces) == input)
        for case .text(let text) in pieces {
            #expect(RexTerminalKeyReader.jsonCost(of: text.utf8) <= 64)
            #expect(!text.hasPrefix("[1;5C"))
        }
        #expect(pieces.contains { if case .text(let text) = $0 { text.contains(sequence) } else { false } })
    }

    /// Neighboring text joins while it fits; a paste or an event between
    /// keeps what is on each side apart.
    @Test func mergingNeverCrossesAPasteOrAnEvent() {
        let focus = RexTerminalInputPiece.event(type: "focus", payload: ["action": "in"])
        let pieces: [RexTerminalInputPiece] = [.text("a"), .text("b"), focus, .text("c"), .paste("p"), .text("d")]
        #expect(
            RexTerminalKeyReader.merged(pieces, budget: 100)
                == [.text("ab"), focus, .text("c"), .paste("p"), .text("d")])
        let long = String(repeating: "x", count: 60)
        #expect(
            RexTerminalKeyReader.merged([.text(long), .text(long), .text("y")], budget: 100) == [
                .text(long), .text(long + "y"),
            ])
    }

    /// The JSON a text piece takes is never more than its cost says.
    @Test func jsonCostBoundsTheEncodedText() throws {
        let samples = ["plain", "\"quoted\\\"", "\u{01}\u{1B}[A\u{7F}\t\r\n", "é漢🦀", "\u{2028}\u{2029}"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        for sample in samples {
            let encoded = try encoder.encode(JSONValue.string(sample)).count - 2
            #expect(encoded <= RexTerminalKeyReader.jsonCost(of: sample.utf8), "\(sample.debugDescription)")
        }
    }
}
