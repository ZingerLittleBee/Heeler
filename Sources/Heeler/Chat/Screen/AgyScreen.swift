import Foundation

/// The structure of an Antigravity CLI screen (1.5.3): the input box between
/// two full-width rules, the footer under it, and what agy draws under the
/// box or in its place. agy draws inline on the normal screen, so a read
/// also holds scrollback above the box, and after an earlier agy exited in
/// the same terminal its last frame above its resume line, whose box is
/// never read as the current one.
///
/// agy draws in one of two palettes. By default it uses 256-color indexes,
/// which stay the same whatever the terminal's theme: rules and hints in 8
/// (grey), the prompt's `>` in 12 (bright blue), and bash mode's `!` in
/// bold 4 (blue). Under `NO_COLOR` it draws no color but keeps its text
/// attributes, bold, dim, italic and underline: plain rules, the prompt's
/// `>` plain in one run with the draft, a bold `!`, and a mode's hint as
/// plain as a draft. A box reads only when its rules and marker share one
/// palette. Past prompts in the scrollback are bold rows (blue 4, or
/// without color) under a rule at most 60 columns wide, never the full
/// width, so they never read as the box. Every reader of an agy screen
/// goes through it, so a rule changes in one place.
struct AgyScreen: Sendable {
    /// How agy colors what it draws.
    enum Palette: Equatable, Sendable {
        /// agy's 256-color indexes.
        case colored
        /// No color, bold, dim, italic and underline kept: agy 1.5.3
        /// under `NO_COLOR`, as herdr 0.9.5 reads it (2026-11-08).
        case colorless
    }

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
        /// The mode's hint in an empty box in accept-edits, auto and plan
        /// modes, which stays until a key is typed: grey, or under
        /// `NO_COLOR` one of `modeHints` over `? for shortcuts` or a
        /// running turn's footer.
        var placeholder: String?
        /// The index of the top rule's row.
        var topRule: Int
        /// The index of the bottom rule's row.
        var bottomRule: Int
        /// The palette the box's rules and marker are drawn in.
        var palette: Palette
    }

    /// agy's `/tasks` panel, under the box in the footer's place: `Tasks`,
    /// the section `Agent Backgrounded`, then a row per task, newest first,
    /// such as `> ● [02:54:02] sleep 40` with its status at the right edge,
    /// the selected row marked `> `. A key hint row and the footer follow;
    /// nothing reads the hint, which agy cuts at 62 columns and drops at 40.
    /// The time is the Host's local time, so nothing reads it either.
    struct TaskPanel: Equatable, Sendable {
        struct Row: Equatable, Sendable {
            /// The task's name: the command it runs.
            var command: String
            /// `running`, `cancelled`, `completed (exit 0)` and the like,
            /// cut at narrow widths (`completed (exit` at 40 columns).
            var status: String

            var isRunning: Bool { status == "running" }
            /// A status the task never leaves: `cancelled` after `k`, or
            /// `completed (exit 0)` and the like. `failed` is a guess from
            /// agy's statuses; no capture shows one.
            var hasEnded: Bool {
                status == "cancelled" || status.hasPrefix("completed") || status.hasPrefix("failed")
            }
        }

        var rows: [Row]
        /// The row marked `> `: the top one as the panel opens.
        var selected: Int?
    }

    /// The `/` popup's selected row under a `/` draft, such as `/tasks` and
    /// `View background tasks`.
    struct SlashSelection: Equatable, Sendable {
        var command: String
        var description: String
    }

    let composer: Composer?
    /// The `/tasks` panel under the box, when it shows.
    let taskPanel: TaskPanel?
    /// The `/` popup's selected row under a `/` draft, when it shows.
    let slashSelection: SlashSelection?
    /// The footer's left side, right under the box or under the
    /// background-task panel: `? for shortcuts` while the box is empty,
    /// `esc to cancel` while a turn runs, `Press up to edit queued messages`
    /// while a message waits, or a pending double press. Empty when only
    /// the mode, model and effort show at the right, as with a draft. Nil
    /// when something other than the footer is drawn under the box.
    let footerHint: String?
    /// The first row of what agy draws under the box in place of the
    /// footer: the `/` and `@` popups, the `?` help, the `/model` picker,
    /// the artifact review panel or the `/tasks` panel, each of which takes
    /// Enter.
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
    /// A background task runs: agy lists it under the box, or counts it at
    /// the footer's right (`· 1 task(s) · /tasks`), which a narrow footer
    /// can cut (72) and a popup keeps (176).
    let showsRunningTasks: Bool

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
        let ruleWidth = Self.ruleWidth(columns: screen.columns)
        // An agy that exited in this terminal leaves its last frame, box
        // included, above its resume line, and one started after it draws
        // below. Its dialogs draw no box, so the old one would be the
        // bottom-most (live 2026-11-09, 200).
        let live = (rows.lastIndex(where: Self.isExitLine) ?? -1) + 1
        var composer = Self.composer(in: rows, from: live, ruleWidth: ruleWidth)
        var footerHint: String?
        var below: String?
        var showsRunningTasks = false
        if let box = composer {
            var index = box.bottomRule + 1
            showsRunningTasks = rows[index...].contains(where: Self.countsTasks)
            // The background-task panel: its task rows, then a rule.
            if index < rows.count, Self.isTaskRow(rows[index]) {
                showsRunningTasks = true
                while index < rows.count, Self.isTaskRow(rows[index]) { index += 1 }
                if index < rows.count, Self.rulePalette(rows[index], width: ruleWidth) == box.palette { index += 1 }
            }
            let later = rows.indices.contains(index) ? rows[(index + 1)...].filter { !$0.isBlank } : []
            if later.isEmpty {
                footerHint = rows.indices.contains(index) ? Self.hint(of: rows[index]) : ""
            } else {
                below = rows[index...].first { !$0.isBlank }?.trimmedText
            }
        }
        // Without colors a mode's hint is as plain as a draft. It is one of
        // agy's hints over `? for shortcuts`, which a typed key clears (117,
        // 129), or over a running turn's footer, which a draft keeps (33)
        // but which holds a send either way. An armed exit's footer keeps
        // a draft too (07), so over it the same text reads as typed.
        if let box = composer, box.palette == .colorless,
            let footer = footerHint, Self.modeHintFooters.contains(footer),
            let hint = Self.modeHint(box.draft, row: rows[box.topRule + 1], ruleWidth: ruleWidth)
        {
            composer?.draft = ""
            composer?.placeholder = hint
        }
        self.composer = composer
        self.footerHint = footerHint
        self.below = below
        taskPanel = composer.flatMap { Self.taskPanel(in: rows, below: $0.bottomRule) }
        slashSelection = composer.flatMap { box in
            box.mode == .prompt && box.draft.hasPrefix("/") ? below.flatMap(Self.slashSelection) : nil
        }
        pendingDoublePress = footerHint.flatMap { hint in
            hint.hasPrefix("press ") && hint.contains(" again to ") && !Self.readyHints.contains(hint) ? hint : nil
        }
        let tail = rows.dropFirst((composer?.bottomRule ?? -1) + 1).filter { !$0.isBlank }.suffix(Self.exitTailRows)
        hasExited = tail.contains { $0.trimmedText.hasPrefix(Self.exitLine) }
        showsDialog = composer == nil && Self.showsDialog(rows)
        showsRunningTurn = footerHint.map(Self.workingHints.contains) == true || Self.showsSpinner(rows)
        self.showsRunningTasks = showsRunningTasks
    }

    // MARK: Box

    /// The width a box's rule spans at least: the screen's, which can read
    /// a cell or two short of the pane's.
    static func ruleWidth(columns: Int) -> Int {
        max(8, columns - 2)
    }

    /// The bottom-most box from row `start` on: a full-width rule with the
    /// prompt's marker right under it, and the next full-width rule below,
    /// all three in one palette.
    private static func composer(in rows: [ScreenRow], from start: Int, ruleWidth: Int) -> Composer? {
        for top in rows.indices.reversed() where top >= start && top + 2 < rows.count {
            guard let palette = rulePalette(rows[top], width: ruleWidth),
                let marker = promptMarker(of: rows[top + 1]), marker.palette == palette
            else { continue }
            let rest = rows.indices[(top + 2)...].prefix(maximumBoxRows)
            guard let bottom = rest.first(where: { rulePalette(rows[$0], width: ruleWidth) != nil }),
                rulePalette(rows[bottom], width: ruleWidth) == palette,
                rows[(top + 2)..<bottom].allSatisfy({ $0.isBlank || ($0.indent ?? 0) >= 2 })
            else { continue }
            var typed = ""
            var grey = ""
            for run in DialogRowScanner.runs(of: rows[top + 1], from: 2) {
                if palette == .colored, run.style.foreground == grey8 { grey += run.text } else { typed += run.text }
            }
            let first = ScreenRow.normalizedSpaces(typed).trimmingCharacters(in: .whitespaces)
            let more = rows[(top + 2)..<bottom].map(\.trimmedText).filter { !$0.isEmpty }
            let lines = (first.isEmpty ? [] : [first]) + more
            let hint = ScreenRow.normalizedSpaces(grey).trimmingCharacters(in: .whitespaces)
            return Composer(
                mode: marker.mode, draft: lines.joined(separator: "\n"),
                placeholder: lines.isEmpty && !hint.isEmpty ? hint : nil, topRule: top, bottomRule: bottom,
                palette: palette)
        }
        return nil
    }

    /// The most rows a box spans, rules included: agy grows it upward as a
    /// draft grows.
    private static let maximumBoxRows = 40

    private static let grey8 = ScreenColor.indexed(8)

    /// The palette of a `─` rule from column 0 at least `width` cells wide,
    /// grey or without any style, or nil for any other row. The box's rules
    /// span the screen; the rule over a past prompt is at most 60 columns,
    /// and three short of the width on narrower screens.
    static func rulePalette(_ row: ScreenRow, width: Int) -> Palette? {
        guard row.indent == 0, DialogRowScanner.isRule(row, of: "─", minimumWidth: width) else { return nil }
        let styles = row.visibleRuns.map(\.style)
        if styles.allSatisfy({ $0.foreground == grey8 }) { return .colored }
        if styles.allSatisfy({ $0 == .plain }) { return .colorless }
        return nil
    }

    /// The prompt's marker at column 0 and its palette. In agy's colors the
    /// marker is blue and the draft's blank after it uncolored, so herdr
    /// reads the marker as a run of its own. herdr-core's first paint sends
    /// no color for a blank, so there a draft agy colors as blue as the
    /// marker, such as a known command like `/tasks`, shares its run
    /// (2026-11-09). A popup's or a dialog's selected row draws `> ` and its
    /// label in one such run too, so, as without colors, where the prompt's
    /// `>` and the draft share one plain run, only the rules around it make
    /// it the box's. A past prompt's `>` is bold in both.
    private static func promptMarker(of row: ScreenRow) -> (mode: Composer.Mode, palette: Palette)? {
        guard let first = row.runs.first, first.column == 0 else { return nil }
        let marker = first.text.trimmingCharacters(in: .whitespaces)
        let style = first.style
        if marker == ">" || first.text.hasPrefix("> "), style.foreground == .indexed(12), !style.isBold {
            return (.prompt, .colored)
        }
        if marker == "!", style.foreground == .indexed(4), style.isBold { return (.bash, .colored) }
        if marker == "!", style == ScreenStyle(isBold: true) { return (.bash, .colorless) }
        if style == .plain, first.text == ">" || first.text.hasPrefix("> ") { return (.prompt, .colorless) }
        return nil
    }

    /// The hints accept-edits, auto and plan modes set in an empty box.
    static let modeHints = [
        "Accept-edits mode: file edits auto-approved (shift+tab to cycle)",
        "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)",
        "Plan mode: research & plan only (shift+tab to cycle)",
    ]

    /// The footers a colorless box's text can be a mode's hint over.
    private static let modeHintFooters = workingHints.union(["? for shortcuts"])

    /// `text` when it is one of `modeHints`, or the start of one that agy
    /// cut with `...` at the screen's edge (40 and 45 columns).
    private static func modeHint(_ text: String, row: ScreenRow, ruleWidth: Int) -> String? {
        if modeHints.contains(text) { return text }
        guard text.hasSuffix(cutMark), row.contentWidth >= ruleWidth else { return nil }
        let start = text.dropLast(cutMark.count)
        guard !start.isEmpty, modeHints.contains(where: { $0.hasPrefix(start) }) else { return nil }
        return text
    }

    private static let cutMark = "..."

    // MARK: Under the box

    /// A row of the background-task panel, such as `● [00:10:32]  sleep 30;
    /// echo probe-two  running`.
    private static func isTaskRow(_ row: ScreenRow) -> Bool {
        row.trimmedText.range(of: #"^\S \[\d{1,2}:\d{2}:\d{2}\] "#, options: .regularExpression) != nil
    }

    /// The footer's count of running background tasks.
    private static func countsTasks(_ row: ScreenRow) -> Bool {
        row.text.range(of: #"\d+ task\(s\)"#, options: .regularExpression) != nil
    }

    /// The `/tasks` panel right under the box's bottom rule: `Tasks`, then
    /// `Agent Backgrounded` and its rows. Any other section first, which no
    /// capture shows, reads as no panel.
    private static func taskPanel(in rows: [ScreenRow], below bottomRule: Int) -> TaskPanel? {
        let drawn = rows.indices.dropFirst(bottomRule + 1).filter { !rows[$0].isBlank }
        guard drawn.count >= 2, rows[drawn[0]].trimmedText == "Tasks",
            rows[drawn[1]].trimmedText == "Agent Backgrounded"
        else { return nil }
        var taskRows: [TaskPanel.Row] = []
        var marked: [Int] = []
        for index in rows.indices.dropFirst(drawn[1] + 1) {
            // `> ` or two blanks, a dot, the start time, the command, and the
            // status after the last gap of two or more blanks, which agy sets
            // at the right edge.
            let text = ScreenRow.normalizedSpaces(rows[index].text)
            guard let match = text.wholeMatch(of: #/(> |  )\S \[\d{1,2}:\d{2}:\d{2}\] (.*\S)\s{2,}(\S.*?)\s*/#)
            else { break }
            if match.1 == "> " { marked.append(taskRows.count) }
            taskRows.append(TaskPanel.Row(command: String(match.2), status: String(match.3)))
        }
        guard !taskRows.isEmpty else { return nil }
        return TaskPanel(rows: taskRows, selected: marked.count == 1 ? marked[0] : nil)
    }

    /// `> /tasks  View background tasks`: the selected row of the `/`
    /// popup, the command and its description.
    private static func slashSelection(_ row: String) -> SlashSelection? {
        guard let match = row.wholeMatch(of: #/> (/\S+)\s{2,}(\S.*)/#) else { return nil }
        return SlashSelection(command: String(match.1), description: String(match.2))
    }

    /// The footer's left side: the text up to the gap before the mode,
    /// model and effort agy sets at the right edge, or nothing when the row
    /// starts with those. The model and effort are dim; the mode is colored,
    /// or under `NO_COLOR` plain in one run with the blanks before it.
    private static func hint(of row: ScreenRow) -> String {
        guard let indent = row.indent, indent <= 2, row.run(at: indent)?.style.isDim == false else { return "" }
        let text = row.trimmedText
        let left = text.components(separatedBy: "  ").first ?? text
        return left.trimmingCharacters(in: .whitespaces)
    }

    private static let exitLine = "Resume with -c"
    /// The exit message's two rows and the shell's prompt.
    private static let exitTailRows = 4

    /// The first row of agy's exit message, at column 0, where neither a
    /// reply (column 2) nor a past prompt (`> `) starts.
    private static func isExitLine(_ row: ScreenRow) -> Bool {
        row.indent == 0 && row.trimmedText.hasPrefix(exitLine)
    }

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
