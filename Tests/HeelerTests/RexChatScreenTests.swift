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

    // MARK: What is no screen

    /// Each row stands in for the screen's first row.
    @Test(arguments: [
        ("a cursor position", "\(esc)[2;3Hmoved"),
        ("an erase in line", "text\(esc)[K"),
        ("a mode change", "\(esc)[?25l"),
        ("a title", "\(esc)]0;made up\u{07}"),
        ("a charset", "\(esc)(0q"),
        ("a lone escape", "\(esc)"),
        ("a bare line feed", "one\ntwo"),
        ("a bare carriage return", "one\rtwo"),
        ("a tab", "one\ttwo"),
        ("a bell", "one\u{07}"),
        ("a C1 control", "one\u{85}"),
        ("a cut character", "one\u{FFFD}"),
        ("blink", "\(esc)[5mblink\(esc)[0m"),
        ("a colon color", "\(esc)[38:5:1mx\(esc)[0m"),
        ("an empty SGR field", "\(esc)[1;;31mx\(esc)[0m"),
        ("a color past 255", "\(esc)[38;5;256mx\(esc)[0m"),
        ("an erase not moved over", "\(esc)[3Xabc"),
        ("an erase moved over less", "\(esc)[3X\(esc)[2C"),
        ("kitty flags inside a row", "\(esc)[=5;1u"),
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

        #expect(throws: RexScreenProblem.unreadableAnswer) {
            try RexChatScreen.modes(from: ["screen": "sideways", "modes": []], kittyKeyboardFlags: 0)
        }
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
            "id": 7, "offset": .number(Double(total - first)), "max_bytes": .number(Double(first)),
        ])
        #expect(block.args(3) == [
            "id": 7, "offset": .number(Double(total - second)), "max_bytes": .number(Double(second)),
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

    @Test func aGridThatChangedIsNoScreen() async {
        let block = Block([
            "size": [Self.size, ["columns": 40, "rows": 5]],
            "format": [["content": .string(Self.vt(Self.screenLines)), "eof": true]],
        ])
        await #expect(throws: RexScreenProblem.resized) { try await RexChatScreen.read(on: block.requests) }
    }

    @Test func aPageThatStopsShortIsNoScreen() async {
        let block = Block([
            "size": [Self.size],
            "format": [["content": "history", "id": 7, "total": 900_000]],
            "blob_read": [["data": .string(Self.vt(["above"] + Self.screenLines)), "eof": false, "id": 7, "total": 900_000]],
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
            "max_bytes": .number(Double(RexChatScreen.flagsTailBytes)),
        ])

        let none = Block(["format": [["content": "a short screen", "eof": true]]])
        #expect(try await RexChatScreen.kittyKeyboardFlags(on: none.requests) == 0)
    }
}
