import Foundation

/// A color an SGR sequence set: one of the 256 indexed colors (the first 16
/// follow the terminal's theme) or a 24-bit value.
enum ScreenColor: Hashable, Sendable {
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// The SGR attributes in effect for a cell. Only the attributes the Agents
/// draw meaning with are kept; underline, blink and the rest are dropped.
struct ScreenStyle: Hashable, Sendable {
    var foreground: ScreenColor?
    var background: ScreenColor?
    var isBold = false
    var isDim = false
    var isItalic = false
    var isReverse = false

    static let plain = ScreenStyle()

    init(
        foreground: ScreenColor? = nil, background: ScreenColor? = nil, isBold: Bool = false,
        isDim: Bool = false, isItalic: Bool = false, isReverse: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isDim = isDim
        self.isItalic = isItalic
        self.isReverse = isReverse
    }
}

/// Consecutive cells of one row that share a style.
struct ScreenRun: Hashable, Sendable {
    let text: String
    let style: ScreenStyle
    /// The zero-based display column of the run's first cell.
    let column: Int
    /// How many cells the run covers; a wide character counts two.
    let width: Int

    /// The column just past the run.
    var endColumn: Int { column + width }
}

/// One row of the screen as styled runs.
struct ScreenRow: Hashable, Sendable {
    /// Zero-based. Line N of a capture's `.visible.txt` is index N − 1.
    let index: Int
    let runs: [ScreenRun]
    /// The row's characters with styling removed, trailing spaces included.
    let text: String
    /// The row's width in cells, trailing spaces included: herdr keeps the
    /// spaces a program painted (Codex pads its selected option to the full
    /// width), so this can exceed where the visible text ends.
    let width: Int

    init(index: Int, runs: [ScreenRun]) {
        self.index = index
        self.runs = runs
        text = runs.map(\.text).joined()
        width = runs.last?.endColumn ?? 0
    }
}

/// A decoded `agent.read` of the visible screen.
struct ANSIScreen: Sendable {
    let rows: [ScreenRow]
    /// The pane's width as far as the screen shows it: the widest row.
    /// herdr reports no pane size with a read, and a program that fills its
    /// last column is rare, so this can be a cell or two short of the pane.
    let columns: Int

    init(rows: [ScreenRow]) {
        self.rows = rows
        columns = rows.map(\.width).max() ?? 0
    }
}

/// Turns the text of an ANSI screen read into rows of styled runs.
///
/// herdr renders each row on its own, separated by CRLF, and closes every
/// row's styling; only SGR sequences occur. The decoder still carries the
/// style across rows, as a terminal would, and skips any other escape
/// sequence instead of trusting that shape.
enum ANSIScreenDecoder {
    static func decode(_ ansi: String) -> ANSIScreen {
        var builder = Builder()
        let scalars = Array(ansi.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                index = builder.consumeEscape(scalars, from: index)
                continue
            case 0x0A:
                builder.endRow()
            case 0x0D:
                // Rows end with CRLF; a carriage return on its own would move
                // the cursor, which a screen read never asks for.
                break
            case 0x09:
                builder.appendTab()
            case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                break
            default:
                builder.append(scalar)
            }
            index += 1
        }
        return ANSIScreen(rows: builder.finish(endsWithNewline: scalars.last?.value == 0x0A))
    }

    private struct Builder {
        var style = ScreenStyle.plain
        var rows: [ScreenRow] = []
        var runs: [ScreenRun] = []
        var pending = String.UnicodeScalarView()
        var pendingStyle = ScreenStyle.plain
        var column = 0

        mutating func append(_ scalar: Unicode.Scalar) {
            if pendingStyle != style {
                flush()
                pendingStyle = style
            }
            pending.append(scalar)
        }

        mutating func appendTab() {
            flush()
            let stop = (columnAfterPending / 8 + 1) * 8
            for _ in columnAfterPending..<stop {
                append(" ")
            }
        }

        private var columnAfterPending: Int {
            column + TerminalCellWidth.width(of: String(pending))
        }

        mutating func flush() {
            guard !pending.isEmpty else { return }
            let text = String(pending)
            let width = TerminalCellWidth.width(of: text)
            runs.append(ScreenRun(text: text, style: pendingStyle, column: column, width: width))
            column += width
            pending = String.UnicodeScalarView()
        }

        mutating func endRow() {
            flush()
            rows.append(ScreenRow(index: rows.count, runs: runs))
            runs = []
            column = 0
        }

        mutating func finish(endsWithNewline: Bool) -> [ScreenRow] {
            flush()
            // A read that ends with a line break has no row after it.
            if !(endsWithNewline && runs.isEmpty) {
                endRow()
            }
            return rows
        }

        /// Skips one escape sequence starting at `start` and applies it when
        /// it is SGR. Returns the index just past the sequence.
        mutating func consumeEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
            var index = start + 1
            guard index < scalars.count else { return index }
            switch scalars[index] {
            case "[":
                index += 1
                var parameters = ""
                while index < scalars.count {
                    let value = scalars[index].value
                    if (0x40...0x7E).contains(value) {
                        if scalars[index] == "m" {
                            applySGR(parameters)
                        }
                        return index + 1
                    }
                    if (0x30...0x3F).contains(value) {
                        parameters.unicodeScalars.append(scalars[index])
                    } else if !(0x20...0x2F).contains(value) {
                        // Not a CSI byte: the sequence was cut off. Leave the
                        // scalar to be read as text.
                        return index
                    }
                    index += 1
                }
                return index
            case "]", "P", "_", "^", "X":
                // OSC and the other string sequences end with BEL or ST.
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 { return index + 1 }
                    if scalars[index].value == 0x1B {
                        return index + 1 < scalars.count && scalars[index + 1] == "\\"
                            ? index + 2 : index + 1
                    }
                    index += 1
                }
                return index
            default:
                // Two- and three-byte sequences such as a charset selection.
                while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) {
                    index += 1
                }
                return min(index + 1, scalars.count)
            }
        }

        mutating func applySGR(_ parameters: String) {
            let fields = parameters.isEmpty ? [""] : parameters.split(separator: ";", omittingEmptySubsequences: false)
            var position = 0
            while position < fields.count {
                let field = fields[position]
                if field.contains(":") {
                    applyColonForm(field)
                    position += 1
                    continue
                }
                let code = Int(field) ?? 0
                switch code {
                case 0: style = .plain
                case 1: style.isBold = true
                case 2: style.isDim = true
                case 3: style.isItalic = true
                case 7: style.isReverse = true
                case 22:
                    style.isBold = false
                    style.isDim = false
                case 23: style.isItalic = false
                case 27: style.isReverse = false
                case 30...37: style.foreground = .indexed(UInt8(code - 30))
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(UInt8(code - 40))
                case 49: style.background = nil
                case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
                case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
                case 38, 48, 58:
                    // 58 is the underline color: its values are skipped.
                    let (color, used) = Self.extendedColor(fields[(position + 1)...].map { Int($0) })
                    if code == 38 { style.foreground = color }
                    if code == 48 { style.background = color }
                    position += used
                default:
                    break
                }
                position += 1
            }
        }

        /// `38:2::r:g:b`, `38:2:r:g:b` and `38:5:n`, the ITU T.416 spelling.
        mutating func applyColonForm(_ field: Substring) {
            let parts = field.split(separator: ":", omittingEmptySubsequences: false)
            guard let code = parts.first.flatMap({ Int($0) }), code == 38 || code == 48 else { return }
            var values = parts.dropFirst().map { Int($0) }
            if values.first == 2, values.count == 5 {
                // The optional color-space id sits between the 2 and red.
                values.remove(at: 1)
            }
            let (color, _) = Self.extendedColor(values)
            if code == 38 { style.foreground = color } else { style.background = color }
        }

        /// Reads `5;n` or `2;r;g;b` after a 38 or 48. Returns the color, if
        /// the values form one, and how many values were consumed.
        static func extendedColor(_ values: [Int?]) -> (ScreenColor?, Int) {
            switch values.first {
            case 5:
                guard values.count >= 2, let index = values[1] else { return (nil, values.count) }
                return (.indexed(UInt8(clamping: index)), 2)
            case 2:
                guard values.count >= 4, let red = values[1], let green = values[2], let blue = values[3]
                else { return (nil, values.count) }
                return (.rgb(UInt8(clamping: red), UInt8(clamping: green), UInt8(clamping: blue)), 4)
            default:
                return (nil, values.count)
            }
        }
    }
}

/// How many terminal cells a character covers, by the rules a terminal grid
/// such as herdr's applies: East Asian wide and fullwidth characters and
/// emoji with emoji presentation take two, combining marks and format
/// characters none, everything else, ambiguous-width characters included,
/// one.
enum TerminalCellWidth {
    static func width<S: StringProtocol>(of text: S) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let base = scalars.first else { return 0 }
        let baseWidth = width(of: base)
        if baseWidth == 1, base.properties.isEmoji, scalars.contains("\u{FE0F}") {
            return 2
        }
        return baseWidth
    }

    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
        if value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if (0x1160...0x11FF).contains(value) { return 0 }
        if isWide(value) || scalar.properties.isEmojiPresentation { return 2 }
        return 1
    }

    /// East Asian Wide and Fullwidth blocks (UAX #11), coarsened to whole
    /// blocks where that changes nothing a TUI draws.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF,
        0x1B000...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isWide(_ value: UInt32) -> Bool {
        var low = 0
        var high = wideRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = wideRanges[middle]
            if value < range.lowerBound {
                high = middle - 1
            } else if value > range.upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}

extension ScreenRow {
    /// True for a space or a no-break space: Claude draws its prompt with
    /// U+00A0 after the pointer.
    static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}"
    }

    var isBlank: Bool { text.allSatisfy(Self.isBlank) }

    /// The column of the first non-blank cell, or nil for a blank row.
    var indent: Int? {
        var column = 0
        for character in text {
            if !Self.isBlank(character) { return column }
            column += TerminalCellWidth.width(of: character)
        }
        return nil
    }

    /// Where the visible text ends: the width without trailing blanks.
    var contentWidth: Int {
        var trailing = 0
        for character in text.reversed() {
            guard Self.isBlank(character) else { break }
            trailing += TerminalCellWidth.width(of: character)
        }
        return width - trailing
    }

    /// The text without leading and trailing blanks, a no-break space read
    /// as a space.
    var trimmedText: String {
        Self.normalizedSpaces(text).trimmingCharacters(in: .whitespaces)
    }

    /// The run covering `column`, if any.
    func run(at column: Int) -> ScreenRun? {
        runs.first { $0.column <= column && column < $0.endColumn }
    }

    /// The runs that are not only blanks.
    var visibleRuns: [ScreenRun] {
        runs.filter { !$0.text.allSatisfy(Self.isBlank) }
    }

    /// The text from `column` on. A wide character straddling the column
    /// is dropped.
    func text(from column: Int) -> String {
        var result = ""
        var position = 0
        for character in text {
            if position >= column { result.append(character) }
            position += TerminalCellWidth.width(of: character)
        }
        return result
    }

    static func normalizedSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
