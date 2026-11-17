import Foundation
import os

/// Why a Rex screen read is no screen (ADR 0055). Chat never answers a prompt
/// it could not read, so each of these fails the whole read.
enum RexScreenProblem: Error, Equatable, Sendable {
    /// An answer without the fields this build reads.
    case unreadableAnswer
    /// Something no measured `vt` answer held: another escape sequence, an
    /// SGR code or a hyperlink outside the measured forms, a control
    /// character, or a character a page boundary cut.
    case unexpected
    /// A row that leaves a style open for the row after it.
    case openStyle
    /// Fewer lines than the grid has rows.
    case tooFewLines
    /// A row wider than the grid, or a grid that changed during the read.
    case resized
    /// The screen did not fit in the longest tail read.
    case tooLong
}

/// A Rex block's screen and keyboard modes as Chat reads them on the control
/// link (ADR 0055), decoded only as far as the lab measured them
/// (0.1.0-preview.14, API revision 12).
///
/// `format` as `vt` with soft wraps kept as rows writes the history, then every
/// row of the screen, a blank one as an empty line, joined by CRLF; while the
/// alternate screen is up, only its rows. The screen is the answer's last
/// `rows` lines, with the grid read before and after. Between the cells' text
/// a row holds four kinds of sequence:
///
/// - SGR. Bold, dim, italic, reverse, and foreground and background colors by
///   index or 24-bit value are kept. Underline (`4`, or `4:2` to `4:5` for its
///   other shapes, the one place Rex writes a colon), blink, conceal,
///   strikethrough, overline and the underline color are not, and are tracked
///   only so that a row must close them; concealed text reads as its text.
/// - `CSI n C` over cells nothing was written to.
/// - `CSI n X` for cells blanked in the current background, always followed by
///   a `CSI n C` over them.
/// - A hyperlink, `OSC 8 ; params ; URI` ended by `ESC \`: no parameter or one
///   `id`, a URI without C0 controls, at most `hyperlinkBytes` of the two, and
///   neither in the close. A link changes no cell's text or style, so its
///   sequences are passed over.
///
/// Rex closes each row's styling, though not its hyperlink, which can stay
/// open into the next row. Nothing else is taken: another sequence or control
/// character, a cut character, a row that leaves a style open, too few lines,
/// or a row wider than the grid fails the read.
///
/// The read asks for the kitty keyboard flags too, which Rex appends after the
/// last row as `CSI = flags ; 1 u` when any is set, and takes only the
/// answer's tail, so a long history costs one bounded read. A read that shows
/// no screen is logged with its problem, and for something unexpected only
/// its class, never anything of the screen.
enum RexChatScreen {
    struct Grid: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    struct Reading: Sendable {
        let screen: ANSIScreen
        /// The kitty keyboard flags of the screen showing.
        let kittyKeyboardFlags: UInt8
    }

    /// The first page, which says how long the whole answer is.
    static let firstPageBytes = 1024
    /// The tails read in turn until one holds the screen and the line above
    /// it. The last bounds what one read costs: a screen longer than that, as
    /// rows of many long hyperlinks can be, is too long.
    static let tailBytes = [16 * 1024, 64 * 1024, 128 * 1024]
    /// Enough of the answer's end for the kitty keyboard flags.
    static let flagsTailBytes = 32
    /// The most pages one tail is read in.
    static let pageLimit = 8
    /// The largest `max_bytes` a page asks for, the cap Rex documents.
    static let largestPage = 983_040
    /// The longest hyperlink Rex keeps: its parameters and URI together, in
    /// UTF-8 bytes. Rex drops a longer one whole.
    static let hyperlinkBytes = 2046

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "RexChatScreen")

    /// What a page asks for to reach the end of `remaining` bytes: `max_bytes`
    /// counts the text as JSON escapes it, and one byte takes at most six
    /// escaped, so a tail usually comes in one page.
    static func pageBytes(remaining: Int) -> Int {
        min(remaining * 6, largestPage)
    }

    // MARK: Reading

    /// The screen now and its kitty keyboard flags. Throws `RexScreenProblem`
    /// for an answer that does not show them with certainty, and what the
    /// requests throw.
    static func read(on requests: RexBlockRequests) async throws -> Reading {
        try await logging("screen") {
            let grid = try Self.grid(from: await requests.read(.size))
            let first = try await requests.read(.format(maxBytes: firstPageBytes, kittyKeyboard: true))
            guard let content = first["content"]?.stringValue else { throw RexScreenProblem.unreadableAnswer }
            let reading: Reading
            if first["eof"] == .bool(true) {
                reading = try decoded(content, startsAnswer: true, grid: grid)
            } else {
                guard let id = first["id"]?.screenWholeNumber, let total = first["total"]?.screenWholeNumber, total > 0
                else { throw RexScreenProblem.unreadableAnswer }
                reading = try await tail(of: id, total: total, grid: grid, on: requests)
            }
            guard try Self.grid(from: await requests.read(.size)) == grid else { throw RexScreenProblem.resized }
            return reading
        }
    }

    /// The kitty keyboard flags of the screen showing, from the end of a short
    /// read: what a key is encoded with. Rex starts no other sequence with
    /// `ESC [ =`, and a hyperlink's URI holds no escape, so a link's end
    /// cannot read as the flags.
    static func kittyKeyboardFlags(on requests: RexBlockRequests) async throws -> UInt8 {
        try await logging("kitty keyboard flags") {
            let first = try await requests.read(.format(maxBytes: flagsTailBytes, kittyKeyboard: true))
            guard let content = first["content"]?.stringValue else { throw RexScreenProblem.unreadableAnswer }
            var end = content
            if first["eof"] != .bool(true) {
                guard let id = first["id"]?.screenWholeNumber, let total = first["total"]?.screenWholeNumber, total > 0
                else { throw RexScreenProblem.unreadableAnswer }
                let offset = max(0, total - flagsTailBytes)
                end = try await page(of: id, offset: offset, total: total, on: requests)
            }
            var scalars = Array(end.unicodeScalars)
            return try takeKittyKeyboardFlags(from: &scalars)
        }
    }

    /// Runs `read`, and logs why it showed no screen: the problem, and for
    /// something unexpected only its class. What other requests throw passes
    /// through.
    private static func logging<Value>(_ what: String, _ read: () async throws -> Value) async throws -> Value {
        do {
            return try await read()
        } catch let unexpected as Unexpected {
            log.error("A Rex \(what, privacy: .public) read met \(unexpected.found, privacy: .public)")
            throw RexScreenProblem.unexpected
        } catch let problem as RexScreenProblem {
            log.error("A Rex \(what, privacy: .public) read failed: \(String(describing: problem), privacy: .public)")
            throw problem
        }
    }

    /// The program's modes for typing: cursor keys, bracketed paste and the
    /// screen from `modes`, with the kitty keyboard flags read with the text.
    /// An answer without them throws `TransportError.rexAnswerUnreadable`:
    /// its shape is Rex's, unlike a screen's content, so it is no unreadable
    /// screen.
    static func modes(from answer: JSONValue, kittyKeyboardFlags: UInt8) throws -> TerminalModeTracker {
        guard case .array(let modes)? = answer["modes"], let screen = answer["screen"]?.stringValue,
            screen == "primary" || screen == "alternate"
        else { throw TransportError.rexAnswerUnreadable(String(localized: "Rex's terminal modes could not be read.")) }
        // A DEC private mode; an ANSI mode with the same number is another one.
        func privateMode(_ number: Int) -> Bool? {
            let mode = modes.first { $0["number"] == .number(Double(number)) && $0["ansi"] != .bool(true) }
            guard case .bool(let set)? = mode?["set"] else { return nil }
            return set
        }
        var said = ""
        // Each screen has its own kitty flags, so the screen comes first.
        if screen == "alternate" { said += "\u{1B}[?1049h" }
        if privateMode(1) == true { said += "\u{1B}[?1h" }
        if let bracketed = privateMode(2004) { said += bracketed ? "\u{1B}[?2004h" : "\u{1B}[?2004l" }
        if kittyKeyboardFlags > 0 { said += "\u{1B}[=\(kittyKeyboardFlags);1u" }
        var tracker = TerminalModeTracker()
        tracker.receive(Data(said.utf8))
        return tracker
    }

    static func grid(from answer: JSONValue) throws -> Grid {
        guard let columns = answer["columns"]?.screenWholeNumber, let rows = answer["rows"]?.screenWholeNumber,
            columns > 0, rows > 0
        else { throw RexScreenProblem.unreadableAnswer }
        return Grid(columns: columns, rows: rows)
    }

    private static func tail(
        of id: Int, total: Int, grid: Grid, on requests: RexBlockRequests
    ) async throws -> Reading {
        for bytes in tailBytes {
            let offset = max(0, total - bytes)
            let text = try await page(of: id, offset: offset, total: total, on: requests)
            do {
                return try decoded(text, startsAnswer: offset == 0, grid: grid)
            } catch RexScreenProblem.tooFewLines where offset > 0 {
                continue
            }
        }
        throw RexScreenProblem.tooLong
    }

    /// The answer from `offset` to its end, page by page, each from where the
    /// last one's text ended. A page that brings nothing short of the end, or
    /// more pages than `pageLimit`, reads as no answer. A character cut at a
    /// page's edge comes as U+FFFD, whose bytes are not the answer's, so only
    /// the first page may start with one and only the last may end with one.
    private static func page(
        of id: Int, offset: Int, total: Int, on requests: RexBlockRequests
    ) async throws -> String {
        var text = ""
        var at = offset
        for _ in 0..<pageLimit {
            let page = try await requests.read(
                .blobRead(id: id, offset: at, maxBytes: pageBytes(remaining: total - at)))
            guard let data = page["data"]?.stringValue, page["total"]?.screenWholeNumber == total,
                at == offset || data.unicodeScalars.first != "\u{FFFD}"
            else { throw RexScreenProblem.unreadableAnswer }
            text += data
            at += data.utf8.count
            if page["eof"] == .bool(true) { return text }
            guard !data.isEmpty, at < total, data.unicodeScalars.last != "\u{FFFD}" else {
                throw RexScreenProblem.unreadableAnswer
            }
        }
        throw RexScreenProblem.tooLong
    }

    // MARK: Decoding

    /// The screen at the end of `text`, an answer read with the kitty keyboard
    /// flags. `startsAnswer` says `text` is the answer from its start;
    /// otherwise it starts at a byte offset, inside a line, a character or a
    /// sequence, and everything through its first line end is dropped. No
    /// sequence holds a line end, so each one left is whole.
    static func decode(_ text: String, startsAnswer: Bool, grid: Grid) throws -> Reading {
        do {
            return try decoded(text, startsAnswer: startsAnswer, grid: grid)
        } catch is Unexpected {
            throw RexScreenProblem.unexpected
        }
    }

    /// `decode`, throwing something unexpected with its class.
    private static func decoded(_ text: String, startsAnswer: Bool, grid: Grid) throws -> Reading {
        var scalars = Array(text.unicodeScalars)
        let flags = try takeKittyKeyboardFlags(from: &scalars)
        var lines: [ArraySlice<Unicode.Scalar>] = []
        var lineStart = 0
        var index = 0
        var hasLineStart = startsAnswer
        while index < scalars.count {
            guard scalars[index] == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" else {
                index += 1
                continue
            }
            if hasLineStart { lines.append(scalars[lineStart..<index]) }
            hasLineStart = true
            index += 2
            lineStart = index
        }
        if hasLineStart { lines.append(scalars[lineStart...]) }

        // The line above the screen shows the screen's first row starts with
        // no style left open, unless the answer starts with that row. A
        // hyperlink may be open into it, which changes nothing it reads.
        let hasLineAbove = !startsAnswer || lines.count > grid.rows
        let needed = grid.rows + (hasLineAbove ? 1 : 0)
        guard lines.count >= needed else { throw RexScreenProblem.tooFewLines }
        var rows: [ScreenRow] = []
        for (position, line) in lines.suffix(needed).enumerated() {
            let runs = try LineReader.runs(of: line, columns: grid.columns)
            if hasLineAbove, position == 0 { continue }
            rows.append(ScreenRow(index: rows.count, runs: runs))
        }
        return Reading(screen: ANSIScreen(rows: rows), kittyKeyboardFlags: flags)
    }

    /// Removes the kitty keyboard flags Rex appends after the last row, and
    /// returns them: none when the answer ends otherwise.
    private static func takeKittyKeyboardFlags(from scalars: inout [Unicode.Scalar]) throws -> UInt8 {
        guard scalars.last == "u", let escape = scalars.lastIndex(of: "\u{1B}") else { return 0 }
        let sequence = String(String.UnicodeScalarView(scalars[(escape + 1)...]))
        // Any other sequence ending in `u` is the line reader's to refuse.
        guard sequence.hasPrefix("[="), sequence.hasSuffix(";1u") else { return 0 }
        let digits = sequence.dropFirst(2).dropLast(3)
        guard !digits.isEmpty, digits.count <= 2, digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
            let flags = UInt8(digits),
            (1...31).contains(flags)
        else { throw Unexpected("CSI u") }
        scalars.removeSubrange(escape...)
        return flags
    }

    /// Something no measured answer held, named for the log by its class
    /// only: an introducer and final byte, an OSC number, or a kind of control
    /// character, never text, parameters or a URI.
    private struct Unexpected: Error {
        let found: String

        init(_ found: String) {
            self.found = found
        }

        static let sgr = Unexpected("CSI m")
    }

    /// One line of a `vt` answer as styled runs, starting with no style.
    private struct LineReader {
        /// What Chat does not keep of a cell's style, tracked so that a row
        /// must close it, as Rex does.
        private enum Unkept: Hashable {
            case underline, blink, conceal, strikethrough, overline, underlineColor
        }

        /// The shapes of underline other than `4`, which Rex writes alone.
        private static let underlineShapes: Set<Substring> = ["4:2", "4:3", "4:4", "4:5"]

        private var style = ScreenStyle.plain
        private var unkept: Set<Unkept> = []
        private var runs: [ScreenRun] = []
        private var pending = String.UnicodeScalarView()
        private var pendingStyle = ScreenStyle.plain
        private var column = 0
        private var blankCells = 0
        private let columns: Int

        private init(columns: Int) {
            self.columns = columns
        }

        static func runs(of line: ArraySlice<Unicode.Scalar>, columns: Int) throws -> [ScreenRun] {
            var reader = LineReader(columns: columns)
            var index = line.startIndex
            while index < line.endIndex {
                let scalar = line[index]
                switch scalar.value {
                case 0x1B:
                    index = try reader.readSequence(in: line, at: index)
                    continue
                case 0x00..<0x20: throw Unexpected("C0 control")
                case 0x7F: throw Unexpected("DEL")
                case 0x80..<0xA0: throw Unexpected("C1 control")
                case 0xFFFD: throw Unexpected("U+FFFD")
                default:
                    reader.append(scalar, style: reader.style)
                }
                index += 1
            }
            guard reader.style == .plain, reader.unkept.isEmpty else { throw RexScreenProblem.openStyle }
            reader.flush()
            guard reader.column <= columns else { throw RexScreenProblem.resized }
            return reader.runs
        }

        private mutating func append(_ scalar: Unicode.Scalar, style: ScreenStyle) {
            if pendingStyle != style {
                flush()
                pendingStyle = style
            }
            pending.append(scalar)
        }

        private mutating func appendBlank(_ count: Int, style: ScreenStyle) throws {
            blankCells += count
            guard blankCells <= columns else { throw RexScreenProblem.resized }
            for _ in 0..<count { append(" ", style: style) }
        }

        private mutating func flush() {
            guard !pending.isEmpty else { return }
            let text = String(pending)
            let width = TerminalCellWidth.width(of: text)
            runs.append(ScreenRun(text: text, style: pendingStyle, column: column, width: width))
            column += width
            pending = String.UnicodeScalarView()
        }

        /// Reads the sequence at `start`, and returns where the next character
        /// begins.
        private mutating func readSequence(in line: ArraySlice<Unicode.Scalar>, at start: Int) throws -> Int {
            if start + 1 < line.endIndex, line[start + 1] == "]" { return try Self.hyperlinkEnd(in: line, at: start) }
            guard let sequence = Self.controlSequence(in: line, at: start) else {
                throw Unexpected(Self.sequenceClass(in: line, at: start))
            }
            switch sequence.final {
            case "m":
                if sequence.parameters.contains(":") {
                    guard Self.underlineShapes.contains(sequence.parameters) else { throw Unexpected.sgr }
                    unkept.insert(.underline)
                } else {
                    try applySGR(sequence.parameters)
                }
                return sequence.end
            case "C":
                try appendBlank(Self.count(sequence.parameters, final: "C"), style: .plain)
                return sequence.end
            case "X":
                // Rex moves over the cells it blanked at once.
                let count = try Self.count(sequence.parameters, final: "X")
                guard let move = Self.controlSequence(in: line, at: sequence.end), move.final == "C",
                    (try? Self.count(move.parameters, final: "C")) == count
                else { throw Unexpected("CSI X") }
                try appendBlank(count, style: ScreenStyle(background: style.background))
                return move.end
            default:
                throw Unexpected("CSI \(sequence.final)")
            }
        }

        /// `ESC [`, parameters of digits, `:` and `;` only, and a final byte;
        /// nil for anything else.
        private static func controlSequence(
            in line: ArraySlice<Unicode.Scalar>, at start: Int
        ) -> (parameters: Substring, final: Unicode.Scalar, end: Int)? {
            guard start + 1 < line.endIndex, line[start] == "\u{1B}", line[start + 1] == "[" else { return nil }
            var index = start + 2
            var parameters = ""
            while index < line.endIndex {
                let scalar = line[index]
                switch scalar.value {
                case 0x30...0x3B:
                    guard parameters.unicodeScalars.count < 64 else { return nil }
                    parameters.unicodeScalars.append(scalar)
                case 0x40...0x7E:
                    return (parameters[...], scalar, index + 1)
                default:
                    return nil
                }
                index += 1
            }
            return nil
        }

        /// Passes over the hyperlink sequence at `start`, `ESC ] 8 ; params ;
        /// URI ESC \`, in the forms Rex writes, and returns where the next
        /// character begins. The parameters are none, or one `id=` with a
        /// value; the URI holds no C0 control, so the first escape ends it.
        /// Only the close, which has no parameter, has no URI.
        private static func hyperlinkEnd(in line: ArraySlice<Unicode.Scalar>, at start: Int) throws -> Int {
            guard start + 3 < line.endIndex, line[start + 2] == "8", line[start + 3] == ";" else {
                throw Unexpected(sequenceClass(in: line, at: start))
            }
            var index = start + 4
            var parameters = String.UnicodeScalarView()
            var hasURIField = false
            var hasURI = false
            var bytes = 0
            while index < line.endIndex {
                let scalar = line[index]
                if scalar == "\u{1B}" {
                    guard hasURIField, index + 1 < line.endIndex, line[index + 1] == "\\",
                        isLinkParameter(parameters, opening: hasURI)
                    else { throw Unexpected("OSC 8 shape") }
                    return index + 2
                }
                guard scalar.value >= 0x20 else { throw Unexpected("OSC 8 shape") }
                index += 1
                // The first `;` parts the fields; the URI may hold more.
                if !hasURIField, scalar == ";" {
                    hasURIField = true
                    continue
                }
                bytes += UTF8.width(scalar)
                guard bytes <= hyperlinkBytes else { throw Unexpected("OSC 8 length") }
                if hasURIField { hasURI = true } else { parameters.append(scalar) }
            }
            throw Unexpected("OSC 8 end")
        }

        /// No parameter, or one `id` with a value, which only an opening has.
        private static func isLinkParameter(_ parameters: String.UnicodeScalarView, opening: Bool) -> Bool {
            if parameters.isEmpty { return true }
            return opening && parameters.count > 3 && parameters.starts(with: "id=".unicodeScalars)
                && !parameters.contains(":")
        }

        /// The class of the escape sequence at `start`, for the log: its
        /// introducer and final byte, or an OSC's number.
        private static func sequenceClass(in line: ArraySlice<Unicode.Scalar>, at start: Int) -> String {
            guard start + 1 < line.endIndex else { return "ESC" }
            let introducer = line[start + 1]
            switch introducer {
            case "[":
                var index = start + 2
                while index < line.endIndex, (0x20...0x3F).contains(line[index].value) { index += 1 }
                guard index < line.endIndex, (0x40...0x7E).contains(line[index].value) else { return "CSI" }
                return "CSI \(line[index])"
            case "]":
                let number = line[(start + 2)...].prefix { (0x30...0x39).contains($0.value) }.prefix(4)
                return number.isEmpty ? "OSC" : "OSC \(String(String.UnicodeScalarView(number)))"
            default:
                return (0x20...0x7E).contains(introducer.value) ? "ESC \(introducer)" : "ESC"
            }
        }

        /// A cell count: one when left out.
        private static func count(_ parameters: Substring, final: Unicode.Scalar) throws -> Int {
            if parameters.isEmpty { return 1 }
            guard parameters.count <= 5, let count = Int(parameters), count > 0 else {
                throw Unexpected("CSI \(final)")
            }
            return count
        }

        private mutating func applySGR(_ parameters: Substring) throws {
            let fields =
                parameters.isEmpty ? [Substring("")] : parameters.split(separator: ";", omittingEmptySubsequences: false)
            var position = 0
            while position < fields.count {
                let code = try Self.value(fields[position], allowsEmpty: fields.count == 1)
                switch code {
                case 0:
                    style = .plain
                    unkept = []
                case 1: style.isBold = true
                case 2: style.isDim = true
                case 3: style.isItalic = true
                case 4: unkept.insert(.underline)
                case 5: unkept.insert(.blink)
                case 7: style.isReverse = true
                case 8: unkept.insert(.conceal)
                case 9: unkept.insert(.strikethrough)
                case 22:
                    style.isBold = false
                    style.isDim = false
                case 23: style.isItalic = false
                case 24: unkept.remove(.underline)
                case 25: unkept.remove(.blink)
                // Proportional spacing off: nothing turns it on.
                case 26: break
                case 27: style.isReverse = false
                case 28: unkept.remove(.conceal)
                case 29: unkept.remove(.strikethrough)
                case 30...37: style.foreground = .indexed(UInt8(code - 30))
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(UInt8(code - 40))
                case 49: style.background = nil
                case 53: unkept.insert(.overline)
                case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
                case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
                case 38, 48, 58:
                    let (color, used) = try Self.extendedColor(fields, after: position)
                    switch code {
                    case 38: style.foreground = color
                    case 48: style.background = color
                    default: unkept.insert(.underlineColor)
                    }
                    position += used
                default:
                    throw Unexpected.sgr
                }
                position += 1
            }
        }

        /// `5;n` or `2;r;g;b` after a 38, 48 or 58, and how many fields it took.
        private static func extendedColor(_ fields: [Substring], after position: Int) throws -> (ScreenColor, Int) {
            func component(_ offset: Int) throws -> UInt8 {
                guard position + offset < fields.count, let value = UInt8(exactly: try Self.value(fields[position + offset]))
                else { throw Unexpected.sgr }
                return value
            }
            switch try component(1) {
            case 5: return (.indexed(try component(2)), 2)
            case 2: return (.rgb(try component(2), try component(3), try component(4)), 4)
            default: throw Unexpected.sgr
            }
        }

        private static func value(_ field: Substring, allowsEmpty: Bool = false) throws -> Int {
            if field.isEmpty, allowsEmpty { return 0 }
            guard !field.isEmpty, field.count <= 3, let value = Int(field) else { throw Unexpected.sgr }
            return value
        }
    }
}

extension JSONValue {
    fileprivate var screenWholeNumber: Int? {
        guard case .number(let value) = self, value.rounded() == value, value >= 0, value <= 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }
}
