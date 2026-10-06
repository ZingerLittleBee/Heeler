import Foundation

/// A row that opens a numbered option, read from its text: an optional
/// pointer, the number, a period and a blank. Claude draws `❯ 1. Yes` and
/// `   2. No`; Codex draws `› 1. Yes, proceed (y)` and `    2. Green`.
struct NumberedOptionRow: Sendable, Hashable {
    let rowIndex: Int
    let number: Int
    /// The pointer's column when the row has focus.
    let pointerColumn: Int?
    /// The column of the number's first digit.
    let numberColumn: Int
    /// The column just past `N. `, where the label starts.
    let labelColumn: Int
    /// The style of the number's first digit. Claude draws option numbers
    /// in its inactive color, which is what separates an option from a
    /// numbered line in a plan or a reply.
    let numberStyle: ScreenStyle

    var isPointed: Bool { pointerColumn != nil }
}

/// How a program wraps long text, which decides whether two rows join with
/// a space.
enum TextWrapStyle: Sendable {
    /// Ink's wrap-ansi with hard breaks: soft wraps leave the separating
    /// space at the end of the row, and a word longer than the box is cut
    /// mid-word at its edge.
    case claude
    /// Rust textwrap: breaks at spaces, which it drops, or after a hyphen.
    case codex
}

/// Row-level reading shared by the Claude and Codex parsers.
enum DialogRowScanner {
    static let claudePointer: Character = "❯"
    static let codexPointer: Character = "›"

    /// Reads `[pointer] N. ` at the start of `row`. Numbers have at most two
    /// digits; a dialog never shows more options than that.
    static func numberedOption(in row: ScreenRow, pointer: Character) -> NumberedOptionRow? {
        let characters = Array(row.text)
        var index = 0
        var column = 0
        func advance() {
            column += TerminalCellWidth.width(of: characters[index])
            index += 1
        }
        func skipBlanks() {
            while index < characters.count, ScreenRow.isBlank(characters[index]) {
                advance()
            }
        }

        skipBlanks()
        var pointerColumn: Int?
        if index < characters.count, characters[index] == pointer {
            pointerColumn = column
            advance()
            guard index < characters.count, ScreenRow.isBlank(characters[index]) else { return nil }
            skipBlanks()
        }
        let numberColumn = column
        var digits = ""
        while index < characters.count, digits.count < 2, characters[index].isASCII,
            characters[index].isNumber
        {
            digits.append(characters[index])
            advance()
        }
        guard let number = Int(digits), number > 0, index < characters.count, characters[index] == "."
        else { return nil }
        advance()
        guard index < characters.count, ScreenRow.isBlank(characters[index]) else { return nil }
        advance()
        return NumberedOptionRow(
            rowIndex: row.index, number: number, pointerColumn: pointerColumn,
            numberColumn: numberColumn, labelColumn: column,
            numberStyle: row.run(at: numberColumn)?.style ?? .plain)
    }

    /// The row's runs from `column` on. A run that starts earlier is cut at
    /// the column, so `3. Type something.` drawn as one run still yields its
    /// label; a wide character straddling the column is dropped.
    static func runs(of row: ScreenRow, from column: Int) -> [ScreenRun] {
        var result: [ScreenRun] = []
        for run in row.runs where run.endColumn > column {
            if run.column >= column {
                result.append(run)
                continue
            }
            var position = run.column
            var text = ""
            for character in run.text {
                if position >= column { text.append(character) }
                position += TerminalCellWidth.width(of: character)
            }
            guard !text.isEmpty else { continue }
            let width = TerminalCellWidth.width(of: text)
            result.append(ScreenRun(text: text, style: run.style, column: run.endColumn - width, width: width))
        }
        return result
    }

    static func isBlank(_ run: ScreenRun) -> Bool {
        run.text.allSatisfy(ScreenRow.isBlank)
    }

    /// Whether `row` is a horizontal rule of `glyph` at least `minimumWidth`
    /// cells wide. Leading blanks are allowed: Claude's plan rules start at
    /// column 2.
    static func isRule(_ row: ScreenRow, of glyph: Character, minimumWidth: Int) -> Bool {
        let trimmed = row.trimmedText
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == glyph }) else { return false }
        return TerminalCellWidth.width(of: trimmed) >= minimumWidth
    }

    /// Appends the text of a wrapped row to the text it continues.
    ///
    /// Both programs drop or keep the separating space in ways the screen
    /// does not show directly. Claude cuts a word longer than its box at the
    /// box's edge (`…/prob` + `e-claude`), so two rows join without a space
    /// when the earlier one runs to the edge without a trailing blank and
    /// the two halves together would not have fit in the box anyway. Codex
    /// breaks after hyphens (`touch x5-` + `narrow-probe-file.txt`) and,
    /// like Claude, cuts words that cannot fit.
    static func join(
        _ head: String, _ tail: String, wrap: TextWrapStyle, previousRow: ScreenRow, columns: Int,
        boxColumn: Int
    ) -> String {
        let head = head.trimmingCharacters(in: .whitespaces)
        let tail = tail.trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        if wrap == .codex, head.hasSuffix("-") {
            return head + tail
        }
        let endsWithBlank = previousRow.text.last.map(ScreenRow.isBlank) ?? false
        let reachesEdge = previousRow.contentWidth >= columns - 1
        if wrap == .claude, endsWithBlank {
            return head + " " + tail
        }
        if reachesEdge {
            let lastWord = head.split(separator: " ").last.map(String.init) ?? head
            let firstWord = tail.split(separator: " ").first.map(String.init) ?? tail
            let combined = TerminalCellWidth.width(of: lastWord) + TerminalCellWidth.width(of: firstWord)
            if combined > columns - boxColumn {
                return head + tail
            }
        }
        return head + " " + tail
    }

    /// Whether the first word of `next` would have fit after `row`'s text.
    /// A program that wraps by words moves a word to the next row only when
    /// it does not fit, so a row whose first word would have fit is a line
    /// of its own rather than a wrapped continuation.
    static func wouldFit(firstWordOf next: String, after row: ScreenRow, columns: Int) -> Bool {
        let word = next.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let separator = (row.text.last.map(ScreenRow.isBlank) ?? false) ? 0 : 1
        return row.contentWidth + separator + TerminalCellWidth.width(of: word) <= columns
    }

    /// Splits a trailing key hint such as ` (y)`, ` (esc)` or
    /// ` (shift+tab)` off a permission option's label. Only single letters
    /// and key names count, so `Use defaults (recommended)` stays whole.
    static func splitShortcut(_ label: String) -> (label: String, shortcut: String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        let key = label[label.index(after: open)..<label.index(before: label.endIndex)]
        let before = label[..<open]
        guard before.hasSuffix(" "), isShortcutKey(key) else { return (label, nil) }
        return (before.trimmingCharacters(in: .whitespaces), String(key))
    }

    private static func isShortcutKey(_ key: Substring) -> Bool {
        if key.count == 1, let character = key.first, character.isASCII, character.isLowercase {
            return true
        }
        if ["esc", "enter", "tab", "space"].contains(key) { return true }
        let parts = key.split(separator: "+")
        guard parts.count == 2, ["shift", "ctrl", "alt", "meta"].contains(parts[0]) else { return false }
        return parts[1].allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    /// What a permission option does, from its label: Claude's `Yes`/`No`
    /// family and Codex's approval labels. Nil for a label outside the
    /// family, which sends the dialog to the generic card.
    static func permissionRole(for label: String, shortcut: String?) -> DialogOptionRole? {
        let folded = label.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if folded == "no" || folded.hasPrefix("no,") || folded.hasPrefix("no ") {
            return .decline
        }
        guard folded == "yes" || folded.hasPrefix("yes,") || folded.hasPrefix("yes ") else { return nil }
        if modeSwitchPhrases.contains(where: folded.contains) { return .approveModeSwitch }
        if persistentPhrases.contains(where: folded.contains) { return .approvePersistent }
        // Codex binds `a` and `p` only to options that store a rule.
        if shortcut == "a" || shortcut == "p" { return .approvePersistent }
        return .approve
    }

    private static let modeSwitchPhrases = [
        "switch to auto mode", "switch to accept edits", "use auto mode", "auto-accept edits", "bypass",
    ]
    private static let persistentPhrases = [
        "don't ask again", "always allow", "for this session", "from this project", "allow this host",
        "keep allowing", "in the future",
    ]

    /// Text in the form the fingerprint and label comparisons use: no
    /// whitespace at all, so wrapping at any width reads the same, and a
    /// typographic apostrophe read as a plain one.
    static func comparable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            scalars.append(scalar == "\u{2019}" ? "'" : scalar)
        }
        return String(scalars)
    }
}
