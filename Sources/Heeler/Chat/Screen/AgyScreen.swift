import Foundation

/// The structure of an Antigravity CLI screen (1.5.3): the input box between
/// two full-width rules, the footer under it, and what agy draws under the
/// box or in its place. agy draws inline on the normal screen, so a read
/// also holds scrollback above the box.
///
/// It reads agy's 256-color indexes, which stay the same whatever the
/// terminal's theme: rules and hints in 8 (grey), the prompt's `>` in 12
/// (bright blue), and bash mode's `!` in bold 4 (blue). Past prompts in the
/// scrollback are bold 4 under a grey rule at most 60 columns wide, never
/// the full width, so they never read as the box. Every reader of an agy
/// screen goes through it, so a rule changes in one place.
struct AgyScreen: Sendable {
    /// The input box: a full-width rule, the row with the prompt's marker,
    /// the rows that continue it, and a second full-width rule.
    struct Composer: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            /// `>`: a message or a `/` command.
            case prompt
            /// `!`: bash mode runs the text as a shell command.
            case bash
        }

        var mode: Mode
        /// The typed text, rows trimmed and joined by newlines. A soft wrap
        /// and a typed newline both continue at column 2, so the two read
        /// the same.
        var draft: String
        /// Grey text in an empty box: the mode's hint in accept-edits, auto
        /// and plan modes, which stays until a key is typed.
        var placeholder: String?
        /// The index of the top rule's row.
        var topRule: Int
        /// The index of the bottom rule's row.
        var bottomRule: Int
    }

    let composer: Composer?
    /// The footer's left side, right under the box or under the
    /// background-task panel: `? for shortcuts` while the box is empty,
    /// `esc to cancel` while a turn runs, `Press up to edit queued messages`
    /// while a message waits, or a pending double press. Empty when only
    /// the mode, model and effort show at the right, as with a draft. Nil
    /// when something other than the footer is drawn under the box.
    let footerHint: String?
    /// The first row of what agy draws under the box in place of the
    /// footer: the `/` and `@` popups, the `?` help, the `/model` picker or
    /// the artifact review panel, each of which takes Enter.
    let below: String?
    /// The footer while agy waits for a second press other than an exit's,
    /// such as `press %s again to send command to background` in its
    /// strings.
    let pendingDoublePress: String?
    /// A permission, question or trust dialog in the box's place: no box,
    /// and a dialog's hint row or question near the bottom.
    let showsDialog: Bool
    /// agy has exited: its last frame stays above `Resume with -c (or
    /// command below):` and the shell's prompt.
    let hasExited: Bool
    /// A turn runs: the footer reads one of `workingHints`, or agy's
    /// braille spinner leads one of the bottom rows (`⡿  Generating...`,
    /// `⣾  Running command...`). These are the two cues herdr 0.9.5's agy
    /// manifest reads as Working (`esc_cancel_footer_working` and
    /// `spinner_working`).
    let showsRunningTurn: Bool

    /// Footer hints of an idle box Enter sends from. Ctrl+C or Ctrl+D on an
    /// idle box arms an exit with no timeout, and a paste disarms it before
    /// its Enter sends (agy 1.5.3 through herdr 0.9.5's `agent prompt`,
    /// live).
    static let readyHints: Set<String> = [
        "", "? for shortcuts", "press ctrl+c again to exit", "press ctrl+d again to exit",
    ]

    /// Footer hints while a turn runs: `esc to cancel`, and `Press up to
    /// edit queued messages` while a message sent during the turn waits.
    static let workingHints: Set<String> = ["esc to cancel", "Press up to edit queued messages"]

    init(_ screen: ANSIScreen) {
        let rows = screen.rows
        let ruleWidth = max(8, screen.columns - 2)
        let composer = Self.composer(in: rows, ruleWidth: ruleWidth)
        self.composer = composer
        var footerHint: String?
        var below: String?
        if let composer {
            var index = composer.bottomRule + 1
            // The background-task panel: its task rows, then a rule.
            if index < rows.count, Self.isTaskRow(rows[index]) {
                while index < rows.count, Self.isTaskRow(rows[index]) { index += 1 }
                if index < rows.count, Self.isRule(rows[index], width: ruleWidth) { index += 1 }
            }
            let later = rows.indices.contains(index) ? rows[(index + 1)...].filter { !$0.isBlank } : []
            if later.isEmpty {
                footerHint = rows.indices.contains(index) ? Self.hint(of: rows[index]) : ""
            } else {
                below = rows[index...].first { !$0.isBlank }?.trimmedText
            }
        }
        self.footerHint = footerHint
        self.below = below
        pendingDoublePress = footerHint.flatMap { hint in
            hint.hasPrefix("press ") && hint.contains(" again to ") && !Self.readyHints.contains(hint) ? hint : nil
        }
        let tail = rows.dropFirst((composer?.bottomRule ?? -1) + 1).filter { !$0.isBlank }.suffix(Self.exitTailRows)
        hasExited = tail.contains { $0.trimmedText.hasPrefix(Self.exitLine) }
        showsDialog = composer == nil && Self.showsDialog(rows)
        showsRunningTurn = footerHint.map(Self.workingHints.contains) == true || Self.showsSpinner(rows)
    }

    // MARK: Box

    /// The bottom-most box: a full-width rule with the prompt's marker
    /// right under it, and the next full-width rule below.
    private static func composer(in rows: [ScreenRow], ruleWidth: Int) -> Composer? {
        for top in rows.indices.reversed() where top + 2 < rows.count && isRule(rows[top], width: ruleWidth) {
            guard let mode = mode(of: rows[top + 1]) else { continue }
            let rest = rows.indices[(top + 2)...].prefix(maximumBoxRows)
            guard let bottom = rest.first(where: { isRule(rows[$0], width: ruleWidth) }),
                rows[(top + 2)..<bottom].allSatisfy({ $0.isBlank || ($0.indent ?? 0) >= 2 })
            else { continue }
            var typed = ""
            var grey = ""
            for run in DialogRowScanner.runs(of: rows[top + 1], from: 2) {
                if run.style.foreground == grey8 { grey += run.text } else { typed += run.text }
            }
            let first = ScreenRow.normalizedSpaces(typed).trimmingCharacters(in: .whitespaces)
            let more = rows[(top + 2)..<bottom].map(\.trimmedText).filter { !$0.isEmpty }
            let lines = (first.isEmpty ? [] : [first]) + more
            let hint = ScreenRow.normalizedSpaces(grey).trimmingCharacters(in: .whitespaces)
            return Composer(
                mode: mode, draft: lines.joined(separator: "\n"),
                placeholder: lines.isEmpty && !hint.isEmpty ? hint : nil, topRule: top, bottomRule: bottom)
        }
        return nil
    }

    /// The most rows a box spans, rules included: agy grows it upward as a
    /// draft grows.
    private static let maximumBoxRows = 40

    private static let grey8 = ScreenColor.indexed(8)

    /// A grey `─` rule from column 0 at least `width` cells wide. The box's
    /// rules span the screen; the rule over a past prompt is at most 60
    /// columns, and three short of the width on narrower screens.
    static func isRule(_ row: ScreenRow, width: Int) -> Bool {
        row.indent == 0 && DialogRowScanner.isRule(row, of: "─", minimumWidth: width)
            && row.visibleRuns.allSatisfy { $0.style.foreground == grey8 }
    }

    /// The prompt's marker at column 0, in a run of its own: a popup's or a
    /// dialog's selected row draws `> ` and its label in one run of the same
    /// blue.
    private static func mode(of row: ScreenRow) -> Composer.Mode? {
        guard let first = row.runs.first, first.column == 0 else { return nil }
        let marker = first.text.trimmingCharacters(in: .whitespaces)
        let style = first.style
        if marker == ">", style.foreground == .indexed(12), !style.isBold { return .prompt }
        if marker == "!", style.foreground == .indexed(4), style.isBold { return .bash }
        return nil
    }

    // MARK: Under the box

    /// A row of the background-task panel, such as `● [00:10:32]  sleep 30;
    /// echo probe-two  running`.
    private static func isTaskRow(_ row: ScreenRow) -> Bool {
        row.trimmedText.range(of: #"^\S \[\d{1,2}:\d{2}:\d{2}\] "#, options: .regularExpression) != nil
    }

    /// The footer's left side: the text up to the gap before the mode,
    /// model and effort agy sets at the right edge in dim text, or nothing
    /// when the row starts with those.
    private static func hint(of row: ScreenRow) -> String {
        guard let first = row.visibleRuns.first, first.column <= 2, !first.style.isDim else { return "" }
        let text = row.trimmedText
        let left = text.components(separatedBy: "  ").first ?? text
        return left.trimmingCharacters(in: .whitespaces)
    }

    private static let exitLine = "Resume with -c"
    /// The exit message's two rows and the shell's prompt.
    private static let exitTailRows = 4

    // MARK: A running turn

    /// A braille spinner (U+2801 to U+28FF), a blank and more text leading
    /// one of the bottom non-blank rows, as herdr's `spinner_working` rule
    /// reads it. agy replaces the spinner's row once the turn ends.
    private static func showsSpinner(_ rows: [ScreenRow]) -> Bool {
        rows.filter { !$0.isBlank }.suffix(spinnerRows).contains { row in
            row.trimmedText.range(of: #"^[\x{2801}-\x{28FF}]+\s+\S"#, options: .regularExpression) != nil
        }
    }

    /// How many of the bottom non-blank rows herdr's rule looks in.
    private static let spinnerRows = 12

    // MARK: Dialogs

    /// The questions agy's dialogs ask (`Do you trust the contents of this`
    /// wraps at 40 columns), read near the bottom.
    private static let dialogQuestions = [
        "Accept this file edit?", "Run this command?", "Allow creation of this file?",
        "Do you trust the contents of this",
    ]

    /// A dialog's hint row, second from the bottom: `↑/↓ Navigate · …`, or
    /// `enter Submit` in a command's Amend field. The `/` and `@` popups
    /// draw the same hint row, under the box rather than in its place.
    private static func showsDialog(_ rows: [ScreenRow]) -> Bool {
        let bottom = rows.filter { !$0.isBlank }.suffix(dialogRows).map(\.trimmedText)
        if bottom.suffix(3).contains(where: { $0.hasPrefix("↑/↓ Navigate") || $0.hasPrefix("enter Submit") }) {
            return true
        }
        return bottom.contains { text in
            dialogQuestions.contains { text.hasPrefix($0) }
                || text.range(of: #"^Question \d+/\d+: "#, options: .regularExpression) != nil
        }
    }

    /// How many of the bottom rows a dialog's question is looked for in:
    /// the options, a wrapped option's rows, the hint row and the footer.
    private static let dialogRows = 16
}
