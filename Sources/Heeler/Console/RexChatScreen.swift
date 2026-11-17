import Foundation

/// Why a Rex screen read is no screen (ADR 0055). Chat never answers a prompt
/// it could not read, so each of these fails the whole read.
enum RexScreenProblem: Error, Equatable, Sendable {
    /// An answer without the fields this build reads.
    case unreadableAnswer
    /// Something no `vt` answer without extras showed: another escape
    /// sequence, a control character, a character a page boundary cut, or an
    /// SGR code outside the measured set.
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
/// `rows` lines, with the grid read before and after. Rex writes three kinds of
/// sequence there: SGR, `CSI n C` for blank cells, and `CSI n X` for cells
/// blanked in the current background, always followed by a `CSI n C` over
/// them; and it closes each row's styling. Nothing else is taken: another
/// sequence or control character, a cut character, a row that leaves a style
/// open, too few lines, or a row wider than the grid fails the read.
///
/// The read asks for the kitty keyboard flags too, which Rex appends after the
/// last row as `CSI = flags ; 1 u` when any is set, and takes only the
/// answer's tail, so a long history costs one bounded read.
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
    /// it. The last bounds what one read costs.
    static let tailBytes = [16 * 1024, 64 * 1024, 128 * 1024]
    /// Enough of the answer's end for the kitty keyboard flags.
    static let flagsTailBytes = 32

    // MARK: Reading

    /// The screen now and its kitty keyboard flags. Throws `RexScreenProblem`
    /// for an answer that does not show them with certainty, and what the
    /// requests throw.
    static func read(on requests: RexBlockRequests) async throws -> Reading {
        let grid = try Self.grid(from: await requests.read(.size))
        let first = try await requests.read(.format(maxBytes: firstPageBytes, kittyKeyboard: true))
        guard let content = first["content"]?.stringValue else { throw RexScreenProblem.unreadableAnswer }
        let reading: Reading
        if first["eof"] == .bool(true) {
            reading = try decode(content, startsAnswer: true, grid: grid)
        } else {
            guard let id = first["id"]?.screenWholeNumber, let total = first["total"]?.screenWholeNumber, total > 0
            else { throw RexScreenProblem.unreadableAnswer }
            reading = try await tail(of: id, total: total, grid: grid, on: requests)
        }
        guard try Self.grid(from: await requests.read(.size)) == grid else { throw RexScreenProblem.resized }
        return reading
    }

    /// The kitty keyboard flags of the screen showing, from the end of a short
    /// read: what a key is encoded with.
    static func kittyKeyboardFlags(on requests: RexBlockRequests) async throws -> UInt8 {
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

    /// The program's modes for typing: cursor keys, bracketed paste and the
    /// screen from `modes`, with the kitty keyboard flags read with the text.
    static func modes(from answer: JSONValue, kittyKeyboardFlags: UInt8) throws -> TerminalModeTracker {
        guard case .array(let modes)? = answer["modes"], let screen = answer["screen"]?.stringValue,
            screen == "primary" || screen == "alternate"
        else { throw RexScreenProblem.unreadableAnswer }
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
                return try decode(text, startsAnswer: offset == 0, grid: grid)
            } catch RexScreenProblem.tooFewLines where offset > 0 {
                continue
            }
        }
        throw RexScreenProblem.tooLong
    }

    /// The answer from `offset` to its end, in one page.
    private static func page(
        of id: Int, offset: Int, total: Int, on requests: RexBlockRequests
    ) async throws -> String {
        let page = try await requests.read(.blobRead(id: id, offset: offset, maxBytes: total - offset))
        guard let data = page["data"]?.stringValue, page["eof"] == .bool(true),
            page["total"]?.screenWholeNumber == total
        else { throw RexScreenProblem.unreadableAnswer }
        return data
    }

    // MARK: Decoding

    /// The screen at the end of `text`, an answer read with the kitty keyboard
    /// flags. `startsAnswer` says `text` is the answer from its start;
    /// otherwise it starts at a byte offset, inside a line or a character, and
    /// everything through its first line end is dropped.
    static func decode(_ text: String, startsAnswer: Bool, grid: Grid) throws -> Reading {
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
        // no style left open, unless the answer starts with that row.
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
        else { throw RexScreenProblem.unexpected }
        scalars.removeSubrange(escape...)
        return flags
    }

    /// One line of a `vt` answer as styled runs, starting with no style.
    private struct LineReader {
        private var style = ScreenStyle.plain
        private var isUnderlined = false
        private var isStruck = false
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
                case 0x00..<0x20, 0x7F, 0x80..<0xA0, 0xFFFD:
                    throw RexScreenProblem.unexpected
                default:
                    reader.append(scalar, style: reader.style)
                }
                index += 1
            }
            guard reader.style == .plain, !reader.isUnderlined, !reader.isStruck else {
                throw RexScreenProblem.openStyle
            }
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
            guard let sequence = Self.controlSequence(in: line, at: start) else { throw RexScreenProblem.unexpected }
            switch sequence.final {
            case "m":
                try applySGR(sequence.parameters)
                return sequence.end
            case "C":
                try appendBlank(Self.count(sequence.parameters), style: .plain)
                return sequence.end
            case "X":
                // Rex moves over the cells it blanked at once.
                let count = try Self.count(sequence.parameters)
                guard let move = Self.controlSequence(in: line, at: sequence.end), move.final == "C",
                    (try? Self.count(move.parameters)) == count
                else { throw RexScreenProblem.unexpected }
                try appendBlank(count, style: ScreenStyle(background: style.background))
                return move.end
            default:
                throw RexScreenProblem.unexpected
            }
        }

        /// `ESC [`, parameters of digits and `;` only, and a final byte; nil for
        /// anything else.
        private static func controlSequence(
            in line: ArraySlice<Unicode.Scalar>, at start: Int
        ) -> (parameters: Substring, final: Unicode.Scalar, end: Int)? {
            guard start + 1 < line.endIndex, line[start] == "\u{1B}", line[start + 1] == "[" else { return nil }
            var index = start + 2
            var parameters = ""
            while index < line.endIndex {
                let scalar = line[index]
                switch scalar.value {
                case 0x30...0x39, 0x3B:
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

        /// A cell count: one when left out.
        private static func count(_ parameters: Substring) throws -> Int {
            if parameters.isEmpty { return 1 }
            guard parameters.count <= 5, let count = Int(parameters), count > 0 else {
                throw RexScreenProblem.unexpected
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
                    isUnderlined = false
                    isStruck = false
                case 1: style.isBold = true
                case 2: style.isDim = true
                case 3: style.isItalic = true
                case 4: isUnderlined = true
                case 7: style.isReverse = true
                case 9: isStruck = true
                case 22:
                    style.isBold = false
                    style.isDim = false
                case 23: style.isItalic = false
                case 24: isUnderlined = false
                // Blink, spacing and conceal off: none of them was turned on.
                case 25, 26, 28: break
                case 27: style.isReverse = false
                case 29: isStruck = false
                case 30...37: style.foreground = .indexed(UInt8(code - 30))
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(UInt8(code - 40))
                case 49: style.background = nil
                case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
                case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
                case 38, 48:
                    let (color, used) = try Self.extendedColor(fields, after: position)
                    if code == 38 { style.foreground = color } else { style.background = color }
                    position += used
                default:
                    throw RexScreenProblem.unexpected
                }
                position += 1
            }
        }

        /// `5;n` or `2;r;g;b` after a 38 or 48, and how many fields it took.
        private static func extendedColor(_ fields: [Substring], after position: Int) throws -> (ScreenColor, Int) {
            func component(_ offset: Int) throws -> UInt8 {
                guard position + offset < fields.count, let value = UInt8(exactly: try Self.value(fields[position + offset]))
                else { throw RexScreenProblem.unexpected }
                return value
            }
            switch try component(1) {
            case 5: return (.indexed(try component(2)), 2)
            case 2: return (.rgb(try component(2), try component(3), try component(4)), 4)
            default: throw RexScreenProblem.unexpected
            }
        }

        private static func value(_ field: Substring, allowsEmpty: Bool = false) throws -> Int {
            if field.isEmpty, allowsEmpty { return 0 }
            guard !field.isEmpty, field.count <= 3, let value = Int(field) else { throw RexScreenProblem.unexpected }
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
