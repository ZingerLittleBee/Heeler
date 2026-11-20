import Foundation

/// One piece of what a Rex terminal's view sends, as it leaves (ADR 0052).
enum RexTerminalInputPiece: Sendable, Equatable {
    /// Text for the terminal's `write` method: always valid UTF-8, made of
    /// whole characters and whole escape sequences.
    case text(String)
    /// A paste, for a `block.event` the server frames as its terminal's modes
    /// say.
    case paste(String)
    /// A focus change, or a mouse report `write` cannot carry, for `block.event`.
    case event(type: String, payload: JSONValue)
}

/// Reads what Heeler's view writes for a Rex terminal into what leaves for it
/// (ADR 0052), one write at a time: Ghostty writes a key, a report or an answer
/// in one piece, so each write is read whole.
///
/// - Answers to a program's queries are dropped, since Rex's server answers
///   every query itself (0.1.0-preview.14, API revision 12) and the view's
///   answer would reach the program a second time, as typed input. Dropped:
///   device attributes (`CSI … c`), status and cursor reports (`CSI … n`,
///   `CSI … R`), mode reports (`CSI … $ y`), window reports (`CSI … t`), the
///   terminal parameters report (`CSI … x`), the kitty keyboard flags report
///   (`CSI ? … u`), and every OSC, DCS, APC, PM and SOS string with its
///   terminator. A legacy Shift+F3 (`CSI 1 ; 2 R`) reads as a cursor report and
///   is dropped too, as `TmuxKeyReader` drops it.
/// - Focus reports (`CSI I`, `CSI O`) become focus events, and a bracketed
///   paste in the bytes becomes a paste, unframed.
/// - A legacy X10 mouse report (`CSI M` and three bytes) whose bytes are not
///   all ASCII, as past column or row 95, is not valid text: it becomes the
///   mouse or wheel event it reports. Every other mouse report is text and goes
///   as written, so the program gets the encoding it asked for: one in the
///   UTF-8 encoding (DECSET 1005), whose values past 95 take two bytes each,
///   is valid text whole.
/// - A byte that is not part of valid UTF-8 is an 8-bit Meta key: it goes as
///   ESC and the byte without its high bit, the form programs read as Alt.
///   Text is never sent with invalid UTF-8, which closes the control
///   connection.
/// - Everything else goes as text: keys in every encoding Ghostty writes, and
///   an Alt key such as `ESC ]` or `ESC P` with no terminator after it.
///
/// Text is cut into pieces of at most `budget` bytes once written as JSON,
/// only between characters and never inside an escape sequence.
struct RexTerminalKeyReader {
    /// The most JSON one text piece may take.
    let budget: Int
    /// The button of the last legacy press, which its release does not name.
    private var pressed = "left"

    init(budget: Int) {
        self.budget = max(budget, 64)
    }

    mutating func read(_ data: Data) -> [RexTerminalInputPiece] {
        let bytes = [UInt8](data)
        var run = Run(budget: budget)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Self.escape {
                index = readEscape(bytes, at: index, into: &run)
            } else if byte < 0x80 {
                run.add(bytes[index..<(index + 1)])
                index += 1
            } else if let length = Self.scalarLength(in: bytes, at: index) {
                run.add(bytes[index..<(index + length)])
                index += length
            } else {
                run.add([Self.escape, byte & 0x7F])
                index += 1
            }
        }
        run.flush()
        return run.pieces
    }

    /// Reads the sequence that starts at an ESC, and returns where the next begins.
    private mutating func readEscape(_ bytes: [UInt8], at start: Int, into run: inout Run) -> Int {
        guard start + 1 < bytes.count else {
            run.add([Self.escape])
            return start + 1
        }
        let next = bytes[start + 1]
        switch next {
        case UInt8(ascii: "["):
            guard let sequence = Self.controlSequence(in: bytes, at: start) else {
                // No final byte: an Alt key, then what follows.
                run.add(bytes[start..<(start + 2)])
                return start + 2
            }
            if sequence.isPasteStart {
                let (body, end) = Self.pasteBody(in: bytes, from: sequence.end)
                run.add(.paste(String(decoding: body, as: UTF8.self)))
                return end
            }
            if let focus = sequence.focus {
                run.add(.event(type: "focus", payload: .object(["action": .string(focus)])))
                return sequence.end
            }
            if sequence.isLegacyMouse, let end = Self.utf8MouseReportEnd(in: bytes, from: sequence.end) {
                // Valid text as it stands: the program reads the encoding it asked for.
                run.add(bytes[start..<end])
                return end
            }
            if sequence.isLegacyMouse, sequence.end + 3 <= bytes.count {
                let report = bytes[sequence.end..<(sequence.end + 3)]
                if report.allSatisfy({ $0 < 0x80 }) {
                    run.add(bytes[start..<(sequence.end + 3)])
                } else if let event = mouseEvent(report) {
                    run.add(event)
                }
                return sequence.end + 3
            }
            if !sequence.isAnswer { run.add(bytes[start..<sequence.end]) }
            return sequence.end
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            // A terminated string is an answer. Without its terminator it is
            // an Alt key, then what follows.
            if let end = Self.stringEnd(in: bytes, from: start + 2, bell: next == UInt8(ascii: "]")) {
                return end
            }
            run.add(bytes[start..<(start + 2)])
            return start + 2
        case UInt8(ascii: "O") where start + 2 < bytes.count && (0x40...0x7E).contains(bytes[start + 2]):
            run.add(bytes[start..<(start + 3)])
            return start + 3
        case 0x00..<0x80:
            // An Alt key: ESC and its key stay together.
            run.add(bytes[start..<(start + 2)])
            return start + 2
        default:
            run.add([Self.escape])
            return start + 1
        }
    }

    // MARK: Mouse

    /// Just past a legacy mouse report in the UTF-8 encoding (DECSET 1005)
    /// that starts at `start`, or nil when there is none. There each value is
    /// one character, two bytes from 95 up, so the report runs four to six
    /// bytes. One whose values are all one byte reads the same as an X10
    /// report, which is exactly three bytes and ends its write, so it is left
    /// to that reading.
    private static func utf8MouseReportEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var at = start
        var wide = false
        for _ in 0..<3 {
            guard at < bytes.count else { return nil }
            if bytes[at] < 0x80 {
                at += 1
            } else if scalarLength(in: bytes, at: at) == 2 {
                at += 2
                wide = true
            } else {
                return nil
            }
        }
        return wide ? at : nil
    }

    /// The event a legacy mouse report stands for: button and modifiers, then
    /// column and row, each offset by 32 and counted from 1. Extra buttons
    /// have no event and are dropped.
    private mutating func mouseEvent(_ report: ArraySlice<UInt8>) -> RexTerminalInputPiece? {
        let values = report.map { Int($0) - 32 }
        let code = values[0]
        let column = values[1] - 1
        let row = values[2] - 1
        guard code >= 0, column >= 0, row >= 0, code & 128 == 0 else { return nil }
        var payload: [String: JSONValue] = ["x": .number(Double(column)), "y": .number(Double(row))]
        let button = code & 3
        if code & 64 != 0 {
            payload["delta_mode"] = .string("line")
            switch button {
            case 0: payload["delta_y"] = .number(-1)
            case 1: payload["delta_y"] = .number(1)
            case 2: payload["delta_x"] = .number(-1)
            default: payload["delta_x"] = .number(1)
            }
            return .event(type: "wheel", payload: .object(payload))
        }
        let names = ["left", "middle", "right"]
        let mods = [(4, "shift"), (16, "ctrl"), (8, "alt")].filter { code & $0.0 != 0 }.map(\.1)
        if !mods.isEmpty { payload["mods"] = .string(mods.joined(separator: "+")) }
        if code & 32 != 0 {
            payload["action"] = .string("motion")
            if button < 3 { payload["buttons"] = .object([names[button]: .bool(true)]) }
        } else if button == 3 {
            payload["action"] = .string("release")
            payload["button"] = .string(pressed)
        } else {
            pressed = names[button]
            payload["action"] = .string("press")
            payload["button"] = .string(pressed)
        }
        return .event(type: "mouse", payload: .object(payload))
    }

    // MARK: Pieces

    /// Text gathered unit by unit, a unit being a character or an escape
    /// sequence, and cut between units when the next would pass the budget.
    private struct Run {
        let budget: Int
        var pieces: [RexTerminalInputPiece] = []
        private var text: [UInt8] = []
        private var cost = 0

        init(budget: Int) {
            self.budget = budget
        }

        /// One unit of valid UTF-8.
        mutating func add<Bytes: Collection<UInt8>>(_ unit: Bytes) {
            let unitCost = RexTerminalKeyReader.jsonCost(of: unit)
            if cost + unitCost > budget { flush() }
            text.append(contentsOf: unit)
            cost += unitCost
        }

        mutating func add(_ piece: RexTerminalInputPiece) {
            flush()
            pieces.append(piece)
        }

        mutating func flush() {
            guard !text.isEmpty else { return }
            pieces.append(.text(String(decoding: text, as: UTF8.self)))
            text = []
            cost = 0
        }
    }

    /// Joins neighboring text pieces while they fit `budget` together, so what
    /// was typed while a request was out leaves as one write. Pastes and
    /// events stay where they are, and nothing is joined across them.
    static func merged(_ pieces: [RexTerminalInputPiece], budget: Int) -> [RexTerminalInputPiece] {
        var merged: [RexTerminalInputPiece] = []
        var cost = 0
        for piece in pieces {
            guard case .text(let text) = piece else {
                merged.append(piece)
                continue
            }
            let pieceCost = jsonCost(of: text.utf8)
            if case .text(let previous)? = merged.last, cost + pieceCost <= budget {
                merged[merged.count - 1] = .text(previous + text)
                cost += pieceCost
            } else {
                merged.append(piece)
                cost = pieceCost
            }
        }
        return merged
    }

    /// At most what `bytes` of valid UTF-8 take written in a JSON string:
    /// a quote or backslash two bytes, other ASCII controls six, and every
    /// other byte of a character beyond ASCII three, which covers a `\u`
    /// escape of any character.
    static func jsonCost<Bytes: Collection<UInt8>>(of bytes: Bytes) -> Int {
        bytes.reduce(0) { total, byte in
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): total + 2
            case 0x00..<0x20, 0x7F: total + 6
            case 0x80...: total + 3
            default: total + 1
            }
        }
    }

    // MARK: Bytes

    private static let escape: UInt8 = 0x1B

    private struct ControlSequence {
        let parameters: ArraySlice<UInt8>
        let intermediates: ArraySlice<UInt8>
        let final: UInt8
        /// Just past the final byte.
        let end: Int

        var isPasteStart: Bool {
            final == UInt8(ascii: "~") && intermediates.isEmpty && parameters.elementsEqual("200".utf8)
        }

        /// `in` or `out` for a focus report.
        var focus: String? {
            guard parameters.isEmpty, intermediates.isEmpty else { return nil }
            switch final {
            case UInt8(ascii: "I"): return "in"
            case UInt8(ascii: "O"): return "out"
            default: return nil
            }
        }

        var isLegacyMouse: Bool {
            final == UInt8(ascii: "M") && parameters.isEmpty && intermediates.isEmpty
        }

        var isAnswer: Bool {
            switch final {
            case UInt8(ascii: "c"), UInt8(ascii: "n"), UInt8(ascii: "R"), UInt8(ascii: "t"), UInt8(ascii: "x"):
                true
            case UInt8(ascii: "y"):
                intermediates.contains(UInt8(ascii: "$"))
            case UInt8(ascii: "u"):
                parameters.first == UInt8(ascii: "?")
            default:
                false
            }
        }
    }

    /// The control sequence at `start`, or nil when it has no final byte.
    private static func controlSequence(in bytes: [UInt8], at start: Int) -> ControlSequence? {
        var at = start + 2
        let parametersStart = at
        while at < bytes.count, (0x30...0x3F).contains(bytes[at]) { at += 1 }
        let intermediatesStart = at
        while at < bytes.count, (0x20...0x2F).contains(bytes[at]) { at += 1 }
        guard at < bytes.count, (0x40...0x7E).contains(bytes[at]) else { return nil }
        return ControlSequence(
            parameters: bytes[parametersStart..<intermediatesStart], intermediates: bytes[intermediatesStart..<at],
            final: bytes[at], end: at + 1)
    }

    /// A bracketed paste's text and just past its end marker, or the rest of
    /// the bytes when it has none.
    private static func pasteBody(in bytes: [UInt8], from start: Int) -> (ArraySlice<UInt8>, Int) {
        let marker: [UInt8] = [escape] + Array("[201~".utf8)
        var at = start
        while at + marker.count <= bytes.count {
            if bytes[at..<(at + marker.count)].elementsEqual(marker) {
                return (bytes[start..<at], at + marker.count)
            }
            at += 1
        }
        return (bytes[start...], bytes.count)
    }

    /// Just past a string's terminator, or nil when it has none.
    private static func stringEnd(in bytes: [UInt8], from start: Int, bell: Bool) -> Int? {
        var at = start
        while at < bytes.count {
            if bell, bytes[at] == 0x07 { return at + 1 }
            if bytes[at] == escape, at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "\\") { return at + 2 }
            at += 1
        }
        return nil
    }

    /// The length of the well-formed UTF-8 character beyond ASCII at `start`,
    /// or nil when there is none there.
    private static func scalarLength(in bytes: [UInt8], at start: Int) -> Int? {
        let lead = bytes[start]
        let length: Int
        var second: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0:
            length = 3
            second = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED:
            length = 3
            second = 0x80...0x9F
        case 0xF0:
            length = 4
            second = 0x90...0xBF
        case 0xF1...0xF3: length = 4
        case 0xF4:
            length = 4
            second = 0x80...0x8F
        default: return nil
        }
        guard start + length <= bytes.count, second.contains(bytes[start + 1]) else { return nil }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[start + offset]) {
            return nil
        }
        return length
    }
}
