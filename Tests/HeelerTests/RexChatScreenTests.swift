import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What Chat reads of a Rex block's screen (ADR 0055): the last `rows` lines of
/// a `vt` answer, decoded only where every sequence is one Rex was seen to
/// write, and no screen at all otherwise. The texts are invented, in the shape
/// the lab measured.
@Suite("Rex chat screen")
struct RexChatScreenTests {
    private static let esc = "\u{1B}"
    private static let grid = RexChatScreen.Grid(columns: 40, rows: 4)
    private static let address = RexPaneAddress(sessionID: "session:studio", blockID: "block:left")

    private static func vt(_ lines: [String]) -> String { lines.joined(separator: "\r\n") }

    /// A hyperlink's opening as Rex writes it, ended by `ESC \`.
    private static func link(_ uri: String, id: String? = nil) -> String {
        "\(esc)]8;\(id.map { "id=\($0)" } ?? "");\(uri)\(esc)\\"
    }

    private static let close = "\(esc)]8;;\(esc)\\"

    /// A screen whose rows say every shape the decoder takes.
    private static let screenLines = [
        "\(esc)[0m\(esc)[38;5;1mred\(esc)[0m \(esc)[0m\(esc)[1mbold\(esc)[0m",
        "tab\(esc)[5Cstop",
        "\(esc)[0m\(esc)[48;5;4mblue\(esc)[6X\(esc)[6C\(esc)[0m",
        "",
    ]

    private static func decode(_ text: String, startsAnswer: Bool = true) throws -> RexChatScreen.Reading {
        try RexChatScreen.decode(text, startsAnswer: startsAnswer, grid: grid)
    }

    private static func problem(_ text: String, startsAnswer: Bool = true) -> RexScreenProblem? {
        do {
            _ = try decode(text, startsAnswer: startsAnswer)
            return nil
        } catch {
            return error as? RexScreenProblem
        }
    }

    // MARK: What is taken

    /// History goes; the screen keeps its colors, its blank runs and its
    /// trailing blank row, and a blanked run keeps only its background.
    @Test func theScreenIsTheLastRowsLines() throws {
        let reading = try Self.decode(Self.vt(["history one", "history two"] + Self.screenLines))
        let rows = reading.screen.rows
        #expect(rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
        #expect(rows[0].runs.map(\.style) == [
            ScreenStyle(foreground: .indexed(1)), .plain, ScreenStyle(isBold: true),
        ])
        #expect(rows[1].runs.count == 1)
        #expect(rows[2].runs == [ScreenRun(text: "blue      ", style: ScreenStyle(background: .indexed(4)), column: 0, width: 10)])
        #expect(rows[3].runs.isEmpty)
        #expect(reading.kittyKeyboardFlags == 0)
    }

    /// The alternate screen's answer is its rows alone.
    @Test func anAnswerOfOnlyTheScreen() throws {
        let reading = try Self.decode(Self.vt(Self.screenLines))
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
    }

    @Test func wideCharactersTakeTwoCells() throws {
        let reading = try Self.decode(Self.vt(["wide: 宽字 end", "", "", ""]))
        #expect(reading.screen.rows[0].width == 14)
    }

    /// Rex appends the flags after the last row, blank or not.
    @Test func theKittyKeyboardFlagsComeOffTheEnd() throws {
        let reading = try Self.decode(Self.vt(Self.screenLines) + "\(Self.esc)[=5;1u")
        #expect(reading.kittyKeyboardFlags == 5)
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
    }

    /// A tail starts inside a line, even inside a character: everything
    /// through its first line end goes, and the line above the screen stays to
    /// show nothing is left open into it.
    @Test func aTailDropsItsCutLine() throws {
        let text = "\u{FFFD}[0mcut off\r\n" + Self.vt(["above"] + Self.screenLines)
        let reading = try Self.decode(text, startsAnswer: false)
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
        #expect(Self.problem("cut\r\n" + Self.vt(Self.screenLines), startsAnswer: false) == .tooFewLines)
        #expect(Self.problem("no line end at all", startsAnswer: false) == .tooFewLines)
        #expect(Self.problem("cut\r\n\(Self.esc)[1mabove\r\n" + Self.vt(Self.screenLines), startsAnswer: false) == .openStyle)
    }

    // MARK: Hyperlinks and the styles Chat does not keep

    /// A link changes no cell's text or style: a plain one, one styled as a
    /// version number, one left open at a row's end and closed on the next
    /// row, and one Rex closes after the last cell it wrote.
    @Test func aHyperlinkChangesNothingARowReads() throws {
        let versionStyle = "\(Self.esc)[0m\(Self.esc)[4m\(Self.esc)[38;5;6m"
        let reading = try Self.decode(Self.vt([
            "see " + Self.link("https://example.test/notes") + "notes" + Self.close + " here",
            versionStyle + Self.link("https://example.test/v/1", id: "lab-a1") + "v1.2.3" + "\(Self.esc)[0m"
                + Self.close + " ok",
            "wrap " + Self.link("https://example.test/wrapped") + "start-",
            "ed" + Self.close + " and " + Self.link("https://example.test/open") + "left open" + Self.close,
        ]))
        let rows = reading.screen.rows
        #expect(rows.map(\.text) == ["see notes here", "v1.2.3 ok", "wrap start-", "ed and left open"])
        #expect(rows[0].runs == [ScreenRun(text: "see notes here", style: .plain, column: 0, width: 14)])
        #expect(rows[1].runs == [
            ScreenRun(text: "v1.2.3", style: ScreenStyle(foreground: .indexed(6)), column: 0, width: 6),
            ScreenRun(text: " ok", style: .plain, column: 6, width: 3),
        ])
    }

    /// What Rex keeps in a link's parameters and URI, up to the longest link
    /// it keeps. Each row stands in for the screen's first.
    @Test(arguments: [
        ("a URI with a query, `;` and a fragment", link("https://example.test/p?a=1&b=two;c=3#frag")),
        ("a URI in other scripts", link("https://例え.test/路/😀é")),
        ("DEL and C1 controls in a URI", link("https://example.test/a\u{7F}b\u{85}c\u{9B}d\u{9C}e")),
        ("U+FFFD in a URI", link("https://example.test/a\u{FFFD}b")),
        ("a URI of one space", link(" ")),
        ("an id with `=`, a space, `\\`, `]` and other scripts", link("https://example.test/a", id: "a=b c\\d]宽😀")),
        ("DEL, C1 controls and U+FFFD in an id", link("https://example.test/a", id: "a\u{7F}\u{80}\u{9C}\u{FFFD}b")),
        ("the longest link", link(String(repeating: "x", count: RexChatScreen.hyperlinkBytes))),
        (
            "the longest link with an id",
            link(String(repeating: "x", count: RexChatScreen.hyperlinkBytes - "id=lab".utf8.count), id: "lab")
        ),
    ])
    func aHyperlinkRexWritesIsPassedOver(_ shape: String, _ opening: String) throws {
        _ = shape
        let reading = try Self.decode(Self.vt(["s " + opening + "w" + Self.close + " t"] + Self.screenLines.dropFirst()))
        #expect(reading.screen.rows[0].runs == [ScreenRun(text: "s w t", style: .plain, column: 0, width: 5)])
    }

    /// The screen that failed for the maintainer on an iPhone (codex-cli
    /// 0.169.0 in Rex 0.1.0-preview.14, 2026-11-18), in the sequences a
    /// read of it showed: an answer whose last two rows each drew a version
    /// number as a link, opened after a whole style of bold, underline and a
    /// 24-bit color and closed right after the reset that ends that style,
    /// with `CSI n C` between words, above Codex's empty composer in rows
    /// blanked in a background with `CSI n X`. The texts, URIs, colors,
    /// widths and the rows' count are invented. A link left open into the
    /// next row is `aHyperlinkChangesNothingARowReads`'s.
    @Test func codexsAnswerWithLinksAboveItsEmptyComposer() throws {
        let reset = "\(Self.esc)[0m"
        let gap = "\(Self.esc)[1C"
        let box = "\(Self.esc)[48;2;40;40;40m"
        func bump(_ tool: String, to version: String) -> String {
            "\(Self.esc)[2C•\(gap)\(reset)\(Self.esc)[1m\(Self.esc)[38;2;200;80;120m\(tool) "
                + "\(reset)\(Self.esc)[1m\(Self.esc)[4m\(Self.esc)[38;2;120;200;80m"
                + Self.link("https://example.test/releases/\(version)") + version + reset + Self.close + " is\(gap)out"
        }
        let lines = [
            "\(reset)\(Self.esc)[2m• \(reset)Bumped\(gap)the tools:",
            "",
            bump("lab", to: "1.2.3"),
            bump("kit", to: "4.5.6"),
            "",
            "\(reset)\(Self.esc)[2m" + String(repeating: "─", count: 60) + reset,
            "",
            "\(reset)\(box) \(Self.esc)[59X\(Self.esc)[59C\(reset)",
            "\(reset)\(Self.esc)[1m\(box)›\(reset)\(box) \(reset)\(Self.esc)[2m\(box)Ask Codex to do anything"
                + "\(reset)\(box)\(Self.esc)[34X\(Self.esc)[34C\(reset)",
            "\(reset)\(box) \(Self.esc)[59X\(Self.esc)[59C\(reset)",
            "\(Self.esc)[2C\(reset)\(Self.esc)[38;2;140;140;140m? for shortcuts\(reset)",
            "",
        ]
        let reading = try RexChatScreen.decode(
            Self.vt(lines) + "\(Self.esc)[=7;1u", startsAnswer: true, grid: RexChatScreen.Grid(columns: 60, rows: 12))
        let rows = reading.screen.rows
        #expect(rows[2].text == "  • lab 1.2.3 is out")
        #expect(rows[3].text == "  • kit 4.5.6 is out")
        let version = try #require(rows[2].run(at: 8))
        #expect(version.text == "1.2.3")
        #expect(version.style == ScreenStyle(foreground: .rgb(120, 200, 80), isBold: true))
        #expect(reading.kittyKeyboardFlags == 7)
        #expect(InputBoxStateDetector.detect(reading.screen, program: .codex) == .empty(placeholder: "Ask Codex to do anything"))
    }

    /// Underline in each shape, blink, conceal, overline and the underline
    /// color change no style Chat keeps, and a row must close them.
    @Test(arguments: ["4:2", "4:3", "4:4", "4:5", "5", "8", "53", "58;5;1", "58;2;255;0;0"])
    func aStyleChatDoesNotKeepIsTracked(_ code: String) throws {
        let row = "\(Self.esc)[0m\(Self.esc)[\(code)mx\(Self.esc)[0m y"
        let reading = try Self.decode(Self.vt([row] + Self.screenLines.dropFirst()))
        #expect(reading.screen.rows[0].runs == [ScreenRun(text: "x y", style: .plain, column: 0, width: 3)])
        let leftOpen = "\(Self.esc)[0m\(Self.esc)[\(code)mx"
        #expect(Self.problem(Self.vt([leftOpen] + Self.screenLines.dropFirst())) == .openStyle)
    }

    /// Rex restates a cell's whole style, one attribute a sequence, in its
    /// order; concealed text reads as its text.
    @Test func aWholeStyleAsRexWritesIt() throws {
        let group = ["0", "1", "3", "8", "9", "53", "4:2", "38;5;208", "48;2;4;5;6", "58;2;9;8;7"]
            .map { "\(Self.esc)[\($0)m" }.joined()
        let reading = try Self.decode(Self.vt([group + "x\(Self.esc)[0m"] + Self.screenLines.dropFirst()))
        #expect(reading.screen.rows[0].runs == [
            ScreenRun(
                text: "x", style: ScreenStyle(foreground: .indexed(208), background: .rgb(4, 5, 6), isBold: true, isItalic: true),
                column: 0, width: 1)
        ])
        let turnedOff = "\(Self.esc)[5m\(Self.esc)[8mx\(Self.esc)[25m\(Self.esc)[28m"
        #expect(Self.problem(Self.vt([turnedOff] + Self.screenLines.dropFirst())) == nil)
    }

    /// A tail can start inside a link's sequence, or inside a link left open
    /// above the screen: the cut line goes, and no sequence holds a line end.
    @Test func aTailThatStartsInsideAHyperlink() throws {
        let screen = ["inside" + Self.close + " out", "", "", ""]
        for cut in ["ample.test/a\(Self.esc)\\", "\\", "8;;https://example.test/a\(Self.esc)\\"] {
            let text = cut + "linked\r\n" + Self.vt(["still linked"] + screen)
            let reading = try Self.decode(text, startsAnswer: false)
            #expect(reading.screen.rows.map(\.text) == ["inside out", "", "", ""])
        }
    }

    /// A page can end inside a link's sequence: pages are joined before
    /// anything is read.
    @Test func aPageEdgeInsideAHyperlink() async throws {
        let tail = "ut off\r\n" + Self.vt(["above", "a " + Self.link("https://example.test/a") + "link" + Self.close, "", "", ""])
        let edge = try #require(tail.range(of: "]8;;https://"))
        let (head, rest) = (String(tail[..<edge.upperBound]), String(tail[edge.upperBound...]))
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": 900_000]],
            "blob_read": [
                ["data": .string(head), "eof": false, "id": 7, "total": 900_000],
                ["data": .string(rest), "eof": true, "id": 7, "total": 900_000],
            ],
        ])
        let reading = try await RexChatScreen.read(on: block.requests)
        #expect(reading.screen.rows.map(\.text) == ["a link", "", "", ""])
    }

    /// The flags are the answer's last sequence: a link's end, or text that
    /// looks like the flags after it, is not.
    @Test func theKittyKeyboardFlagsBesideAHyperlink() async throws {
        let lookAlike = try Self.decode(Self.vt(["", "", "", Self.link("https://example.test/a") + "w" + Self.close + "[=5;1u"]))
        #expect(lookAlike.kittyKeyboardFlags == 0)
        #expect(lookAlike.screen.rows[3].text == "w[=5;1u")
        let flags = try Self.decode(
            Self.vt(["", "", "", Self.link("https://example.test/[=3;1u") + "open" + Self.close]) + "\(Self.esc)[=7;1u")
        #expect(flags.kittyKeyboardFlags == 7)

        let ends: [(String, UInt8)] = [
            (Self.link("https://example.test/[=5;1u") + "w" + Self.close, 0),
            ("w" + Self.close + "\(Self.esc)[=7;1u", 7),
        ]
        for (end, expected) in ends {
            let block = Block([
                "format": [["content": "history", "id": 3, "total": 5_000]],
                "blob_read": [["data": .string(String(end.suffix(RexChatScreen.flagsTailBytes))), "eof": true, "id": 3, "total": 5_000]],
            ])
            #expect(try await RexChatScreen.kittyKeyboardFlags(on: block.requests) == expected)
        }
    }

    // MARK: What is no screen

    /// Each row stands in for the screen's first row.
    @Test(arguments: [
        ("a cursor position", "\(esc)[2;3Hmoved"),
        ("an erase in line", "text\(esc)[K"),
        ("an erase in display", "\(esc)[2J"),
        ("a mode change", "\(esc)[?25l"),
        ("a title", "\(esc)]0;made up\u{07}"),
        ("a title ended by ST", "\(esc)]2;made up\(esc)\\"),
        ("a charset", "\(esc)(0q"),
        ("a lone escape", "\(esc)"),
        ("a bare line feed", "one\ntwo"),
        ("a bare carriage return", "one\rtwo"),
        ("a tab", "one\ttwo"),
        ("a bell", "one\u{07}"),
        ("a C1 control", "one\u{85}"),
        ("a cut character", "one\u{FFFD}"),
        ("rapid blink", "\(esc)[6mx\(esc)[0m"),
        ("double underline as 21", "\(esc)[21mx\(esc)[0m"),
        ("a colon color", "\(esc)[38:5:1mx\(esc)[0m"),
        ("a colon underline color", "\(esc)[58:2::1:2:3mx\(esc)[0m"),
        ("a colon underline Rex does not write", "\(esc)[4:1mx\(esc)[0m"),
        ("an underline shape among other codes", "\(esc)[1;4:3mx\(esc)[0m"),
        ("an empty SGR field", "\(esc)[1;;31mx\(esc)[0m"),
        ("a color past 255", "\(esc)[38;5;256mx\(esc)[0m"),
        ("an erase not moved over", "\(esc)[3Xabc"),
        ("an erase moved over less", "\(esc)[3X\(esc)[2C"),
        ("kitty flags inside a row", "\(esc)[=5;1u"),
        ("a hyperlink ended by BEL", "\(esc)]8;;https://example.test/a\u{07}w"),
        ("a hyperlink ended by C1 ST", "\(esc)]8;;https://example.test/a\u{9C}w\(esc)]8;;\(esc)\\"),
        ("a hyperlink the row ends in", "\(esc)]8;;https://example.test/a"),
        ("a C0 control in a hyperlink", "\(esc)]8;;https://example.test/a\tb\(esc)\\w"),
        ("a hyperlink without its URI field", "\(esc)]8;https://example.test/a\(esc)\\w"),
        ("a hyperlink parameter other than id", "\(esc)]8;foo=bar;https://example.test/a\(esc)\\w"),
        ("two hyperlink parameters", "\(esc)]8;id=a:foo=b;https://example.test/a\(esc)\\w"),
        ("an empty id", "\(esc)]8;id=;https://example.test/a\(esc)\\w"),
        ("a close with an id", "w\(esc)]8;id=a;\(esc)\\"),
        ("a hyperlink longer than Rex keeps", link(String(repeating: "x", count: RexChatScreen.hyperlinkBytes + 1)) + "w"),
    ])
    func anUnexpectedRowIsNoScreen(_ shape: String, _ row: String) {
        _ = shape
        #expect(Self.problem(Self.vt([row] + Self.screenLines.dropFirst())) == .unexpected)
    }

    @Test func aRowLeftStyledIsNoScreen() {
        let row = "\(Self.esc)[0m\(Self.esc)[1mbold"
        #expect(Self.problem(Self.vt([row] + Self.screenLines.dropFirst())) == .openStyle)
        let underlined = "\(Self.esc)[4munder"
        #expect(Self.problem(Self.vt([underlined] + Self.screenLines.dropFirst())) == .openStyle)
    }

    @Test func tooFewLinesIsNoScreen() {
        #expect(Self.problem(Self.vt(Array(Self.screenLines.prefix(3)))) == .tooFewLines)
    }

    /// Wider than the grid: the grid changed under the read.
    @Test func aRowWiderThanTheGridIsNoScreen() {
        #expect(Self.problem(Self.vt([String(repeating: "x", count: 41), "", "", ""])) == .resized)
        #expect(Self.problem(Self.vt(["x\(Self.esc)[40C", "", "", ""])) == .resized)
        #expect(Self.problem(Self.vt(["wide " + String(repeating: "宽", count: 18), "", "", ""])) == .resized)
    }

    // MARK: Modes

    @Test func theModesForTyping() throws {
        let answer: JSONValue = [
            "screen": "alternate",
            "modes": [
                ["name": "insert", "number": 4, "ansi": true, "set": true],
                ["name": "cursor_keys", "number": 1, "set": true],
                ["name": "bracketed_paste", "number": 2004, "set": true],
            ],
        ]
        let modes = try RexChatScreen.modes(from: answer, kittyKeyboardFlags: 1)
        #expect(modes.isAlternateScreen)
        #expect(modes.usesApplicationCursorKeys)
        #expect(modes.usesBracketedPaste)
        #expect(modes.kittyKeyboardFlags == 1)

        let plain: JSONValue = [
            "screen": "primary",
            "modes": [
                ["name": "cursor_keys", "number": 1, "set": false],
                ["name": "bracketed_paste", "number": 2004, "set": false],
                // An ANSI mode that shares a number is another mode.
                ["name": "other", "number": 1, "ansi": true, "set": true],
            ],
        ]
        let off = try RexChatScreen.modes(from: plain, kittyKeyboardFlags: 0)
        #expect(!off.isAlternateScreen)
        #expect(!off.usesApplicationCursorKeys)
        #expect(off.bracketedPasteSetting == false)
        #expect(off.kittyKeyboardFlags == 0)

        // An answer without them is Rex's answer this build cannot read, not
        // an unreadable screen.
        let unreadable = TransportError.rexAnswerUnreadable("Rex's terminal modes could not be read.")
        #expect(throws: unreadable) {
            try RexChatScreen.modes(from: ["screen": "sideways", "modes": []], kittyKeyboardFlags: 0)
        }
        #expect(throws: unreadable) { try RexChatScreen.modes(from: ["screen": "primary"], kittyKeyboardFlags: 0) }
    }

    // MARK: Reading on the control link

    /// A scripted block: what each read answers, and every read asked.
    private final class Block: Sendable {
        let asked = Mutex<[(method: String, payload: JSONValue)]>([])
        private let answers: Mutex<[String: [JSONValue]]>

        init(_ answers: [String: [JSONValue]]) {
            self.answers = Mutex(answers)
        }

        var requests: RexBlockRequests {
            RexBlockRequests(
                address: RexChatScreenTests.address, server: RexServerStatus(instanceID: "instance-a"),
                maxMessageBytes: 1_048_576, lanes: RexBlockLanes(),
                ask: { method, payload in
                    self.asked.withLock { $0.append((method, payload)) }
                    let name = String(method.split(separator: ".").last ?? "")
                    return try self.answers.withLock { answers in
                        guard var queue = answers[name], !queue.isEmpty else {
                            throw RexControlError.server(RexServerError(code: "not_found", message: "made up", status: 404))
                        }
                        let answer = queue.removeFirst()
                        answers[name] = queue.isEmpty ? [answer] : queue
                        return answer
                    }
                },
                deliver: { _, _ in .notSent })
        }

        var names: [String] {
            asked.withLock { $0.map { String($0.method.split(separator: ".").last ?? "") } }
        }

        func args(_ index: Int) -> JSONValue? {
            asked.withLock { $0[index].payload["args"] }
        }
    }

    private static let size: JSONValue = ["columns": 40, "rows": 4, "owner": .null]

    /// A short answer comes whole in the first page, with the grid read on
    /// either side of it.
    @Test func aShortAnswerIsReadWhole() async throws {
        let block = Block([
            "size": [Self.size],
            "format": [["content": .string(Self.vt(Self.screenLines) + "\(Self.esc)[=1;1u"), "eof": true]],
        ])
        let reading = try await RexChatScreen.read(on: block.requests)
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
        #expect(reading.kittyKeyboardFlags == 1)
        #expect(block.names == ["size", "format", "size"])
        #expect(block.args(1) == [
            "format": "vt", "unwrap": false, "max_bytes": .number(Double(RexChatScreen.firstPageBytes)),
            "extra_kitty_keyboard": true,
        ])
    }

    /// A long history is read from its tail, a longer tail only when the
    /// shorter one held too few lines.
    @Test func aLongAnswerIsReadFromItsTail() async throws {
        let tail = "ut off\r\n" + Self.vt(["above"] + Self.screenLines)
        let total = 900_000
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": .number(Double(total))]],
            "blob_read": [
                ["data": "\r\n\r\nnot enough", "eof": true, "id": 7, "total": .number(Double(total))],
                ["data": .string(tail), "eof": true, "id": 7, "total": .number(Double(total))],
            ],
        ])
        let reading = try await RexChatScreen.read(on: block.requests)
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
        #expect(block.names == ["size", "format", "blob_read", "blob_read", "size"])
        let first = RexChatScreen.tailBytes[0]
        let second = RexChatScreen.tailBytes[1]
        #expect(block.args(2) == [
            "id": 7, "offset": .number(Double(total - first)),
            "max_bytes": .number(Double(RexChatScreen.pageBytes(remaining: first))),
        ])
        #expect(block.args(3) == [
            "id": 7, "offset": .number(Double(total - second)),
            "max_bytes": .number(Double(RexChatScreen.pageBytes(remaining: second))),
        ])
    }

    /// The longest tail is the last read: a screen it does not hold is none.
    @Test func aScreenPastTheLongestTailIsNone() async {
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": 900_000]],
            "blob_read": [["data": "only one line", "eof": true, "id": 7, "total": 900_000]],
        ])
        await #expect(throws: RexScreenProblem.tooLong) { try await RexChatScreen.read(on: block.requests) }
        #expect(block.names.filter { $0 == "blob_read" }.count == RexChatScreen.tailBytes.count)
    }

    /// A block answering from `answer` as Rex does: the first page up to
    /// `max_bytes`, and the rest from a byte offset.
    private static func serving(_ answer: String) -> Block {
        let bytes = Data(answer.utf8)
        let total = JSONValue.number(Double(bytes.count))
        func text(from offset: Int) -> JSONValue { .string(String(decoding: bytes[offset...], as: UTF8.self)) }
        var pages: [JSONValue] = []
        for tail in RexChatScreen.tailBytes {
            pages.append(["data": text(from: max(0, bytes.count - tail)), "eof": true, "id": 7, "total": total])
        }
        return Block([
            "size": [Self.size],
            "format": [["content": text(from: bytes.count - 8), "id": 7, "total": total]],
            "blob_read": pages,
        ])
    }

    /// A row of long links holds few rows in a tail: one that starts inside
    /// a URI reads the screen below it, and a screen longer than the longest
    /// tail is too long, never a shorter one.
    @Test func longHyperlinksAndTheTails() async throws {
        func row(_ name: String, links: Int, uriBytes: Int) -> String {
            let uri = "https://example.test/" + String(repeating: "x", count: uriBytes - 21)
            return name + String(repeating: Self.link(uri) + "w", count: links) + Self.close
        }
        let history = (0..<30).map { row("h\($0) ", links: 1, uriBytes: 1_500) }
        let screen = ["s0 ", "s1 ", "s2 ", "s3 "].map { row($0, links: 1, uriBytes: 1_500) }
        let block = Self.serving(Self.vt(history + screen))
        let reading = try await RexChatScreen.read(on: block.requests)
        #expect(reading.screen.rows.map(\.text) == ["s0 w", "s1 w", "s2 w", "s3 w"])
        #expect(block.names.filter { $0 == "blob_read" }.count == 1)

        let wide = ["s0 ", "s1 ", "s2 ", "s3 "].map { row($0, links: 30, uriBytes: RexChatScreen.hyperlinkBytes) }
        let tooLong = Self.serving(Self.vt(history + wide))
        await #expect(throws: RexScreenProblem.tooLong) { try await RexChatScreen.read(on: tooLong.requests) }
        #expect(tooLong.names.filter { $0 == "blob_read" }.count == RexChatScreen.tailBytes.count)
    }

    @Test func aGridThatChangedIsNoScreen() async {
        let block = Block([
            "size": [Self.size, ["columns": 40, "rows": 5]],
            "format": [["content": .string(Self.vt(Self.screenLines)), "eof": true]],
        ])
        await #expect(throws: RexScreenProblem.resized) { try await RexChatScreen.read(on: block.requests) }
    }

    /// `max_bytes` counts the escaped text, so a tail can come in more than
    /// one page, each from where the last one's text ended.
    @Test func aTailComesInPages() async throws {
        let tail = "ut off\r\n" + Self.vt(["above"] + Self.screenLines)
        let cut = tail.index(tail.startIndex, offsetBy: 20)
        let (head, rest) = (String(tail[..<cut]), String(tail[cut...]))
        let total = 900_000
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": .number(Double(total))]],
            "blob_read": [
                ["data": .string(head), "eof": false, "id": 7, "total": .number(Double(total))],
                ["data": .string(rest), "eof": true, "id": 7, "total": .number(Double(total))],
            ],
        ])
        let reading = try await RexChatScreen.read(on: block.requests)
        #expect(reading.screen.rows.map(\.text) == ["red bold", "tab     stop", "blue      ", ""])
        let start = total - RexChatScreen.tailBytes[0]
        #expect(block.args(3)?["offset"] == .number(Double(start + head.utf8.count)))
    }

    /// A page that brings nothing, or cuts a character between two pages, is
    /// no answer.
    @Test(arguments: [
        ["", "more"],
        ["ut off\r\nab\u{FFFD}", "\u{FFFD}ove"],
        ["ut off\r\nab", "\u{FFFD}ove"],
    ])
    func aPageThatStopsWrongIsNoScreen(_ pages: [String]) async {
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": 900_000]],
            "blob_read": [
                ["data": .string(pages[0]), "eof": false, "id": 7, "total": 900_000],
                ["data": .string(pages[1] + "\r\n" + Self.vt(Self.screenLines)), "eof": true, "id": 7, "total": 900_000],
            ],
        ])
        await #expect(throws: RexScreenProblem.unreadableAnswer) { try await RexChatScreen.read(on: block.requests) }
    }

    /// Keys need only the flags: a short read of the answer's end.
    @Test func theFlagsAloneComeFromTheEnd() async throws {
        let block = Block([
            "format": [["content": "history", "id": 3, "total": 5_000]],
            "blob_read": [["data": .string("\u{FFFD}last row\(Self.esc)[=31;1u"), "eof": true, "id": 3, "total": 5_000]],
        ])
        #expect(try await RexChatScreen.kittyKeyboardFlags(on: block.requests) == 31)
        #expect(block.args(1) == [
            "id": 3, "offset": .number(Double(5_000 - RexChatScreen.flagsTailBytes)),
            "max_bytes": .number(Double(RexChatScreen.pageBytes(remaining: RexChatScreen.flagsTailBytes))),
        ])

        let none = Block(["format": [["content": "a short screen", "eof": true]]])
        #expect(try await RexChatScreen.kittyKeyboardFlags(on: none.requests) == 0)
    }
}
