import Foundation

/// The structure of a Grok Build screen in its full-screen view (1.0.62):
/// the composer box, the footer's hints, the turn status row and dock above
/// the composer, and the overlays and views that take the composer's place.
///
/// It reads structure only. Grok's colors are 24-bit and follow its theme,
/// so the one style it reads is the italic attribute of ghost text, never a
/// color. Every reader of a Grok screen goes through it, so a rule changes
/// in one place.
struct GrokScreen: Sendable {
    /// The input box: a `╭─╮` top border, `│ ❯ text │` rows and a `╰─╯`
    /// bottom border carrying the model.
    struct Composer: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            /// `❯`: a message or a `/` command.
            case prompt
            /// `!`: Bash mode runs the text as a shell command.
            case bash
            /// `#`: Remember mode saves the text as a memory note.
            case remember
        }

        var mode: Mode
        /// The typed text, rows trimmed and joined by newlines. Grok never
        /// draws typed text italic.
        var draft: String
        /// The italic text Grok draws at the cursor: a prompt suggestion,
        /// the rest of one after typed text, or a shell completion. Enter
        /// never sends it.
        var ghost: String
        /// The text set into the top border, such as `Stashed` or a
        /// `/rename` title.
        var topBorderLabel: String?
        /// The text set into the bottom border: the model and its flags, or
        /// `editing queued #N` or `Run shell command` in the model's place,
        /// and `multiline` at the right while that mode is on.
        var bottomBorder: String
        /// The index of the top border's row.
        var topRow: Int
        /// The index of the bottom border's row.
        var bottomRow: Int

        /// Enter adds a line instead of sending (`views/prompt_widget`
        /// `render_info_line`).
        var isMultiline: Bool { bottomBorder.hasSuffix("multiline") }

        /// Enter saves the edit to a queued message. The 1.0.45 source sets
        /// the label in the bottom border, in the model's place.
        var isEditingQueued: Bool {
            bottomBorder.contains(Self.editingQueued) || topBorderLabel?.contains(Self.editingQueued) == true
        }

        private static let editingQueued = "editing queued #"
    }

    /// The turn status row above the composer: a braille spinner, what the
    /// turn is doing, then its timers.
    struct StatusRow: Equatable, Sendable {
        var row: Int
        /// Such as `Waiting for subagent…`. A label that doesn't fit is cut
        /// to a prefix and `…`.
        var label: String
        /// The rest of the row: the phase and turn timers, tokens, buttons,
        /// and `· N queued, Enter to send now` when Grok shows it.
        var trailer: String
    }

    /// A message the user sent, as the scrollback shows it: `❯ ` and the
    /// text at the scrollback's indent, outside any box.
    struct UserRow: Equatable, Sendable {
        /// The row's text after `❯ `, without the scrollbar and the time
        /// Grok sets at the right. A long message goes on below, unmarked.
        var text: String
    }

    /// The system line Grok prints when its screen moves to a session it
    /// made or found: `Session <id>, use /dashboard to switch between
    /// sessions` after `/new` and `/clear`, `Session <id> (forked from
    /// <parent>), use …` after `/fork`, and `Session <id> found locally
    /// (originally in <dir>)`.
    struct SessionLine: Equatable, Sendable {
        /// The session the screen shows: the line's first id, lowercased.
        var sessionID: String
    }

    let composer: Composer?
    /// The shortcuts row: the last nonblank row below the composer, or on
    /// the screen when no composer shows.
    let footer: String?
    /// The footer offers `Shift+Tab:mode`, which shows only while the
    /// prompt has focus on the conversation's own view, or the suggestion
    /// hint, which shows only with prompt focus (`views/agent.rs`
    /// `build_hints`). Either survives a footer cut at 40 columns while the
    /// box is empty. A draft's send and newline hints come first and push
    /// both past a 62-column edge (1.0.62, live), so callers read the draft
    /// before focus. In compact mode, which Grok forces at 20 rows or fewer
    /// (as at a phone's 62×20 grid with the keyboard up), the footer is
    /// `Ctrl+.:shortcuts` whatever has focus (1.0.62, live), and the
    /// dashboard's view of an agent sets its own hints first, which stop
    /// before `Shift+Tab:mode` at 62 columns (1.0.62, live). Then only the
    /// box tells: Grok draws its placeholder in an empty box without focus
    /// (`views/prompt_widget`), so an empty box with no placeholder has it.
    let promptHasFocus: Bool
    /// The footer while Grok waits for a second press, such as
    /// `Ctrl+c:press again to quit`, which replaces every hint.
    let pendingDoublePress: String?
    let statusRow: StatusRow?
    /// The dock's section headers between the status row and the composer,
    /// top to bottom, such as `Queued 1` or `Subagents 1`.
    let dockSections: [String]
    /// The text after a `○ ◎ ◉` icon in the status row's place: background
    /// work running while the Agent is idle (`1 command still running`), or
    /// a turn parked in a wait a message would end (`waiting · send a
    /// message to interrupt`). Grok draws it when the dock is off.
    let cue: String?
    /// The row that shows a popup, picker or panel over the composer.
    let overlay: String?
    /// The rows of the card in the composer's place, such as a permission,
    /// a question or the subagent panel: the bottom-most run of rows that
    /// begin with `┃`, when one of them is an option row such as
    /// `┃  3 (●) Yes, proceed`, the rule herdr reports Blocked by. The
    /// rewind picker draws the same bar without options.
    let card: Range<Int>?
    /// Grok's dashboard, where a message dispatches a new agent.
    let isDashboard: Bool
    /// The dashboard's view of one agent (Grok's session overlay): that
    /// agent's own view, with `Ctrl+\:dashboard` first in the footer, and
    /// `‹ i/n ›` in the header while there are other agents to cycle to
    /// (`agent_view/render.rs`). A message or Ctrl+C reaches that agent,
    /// which may not be this conversation. Once the dashboard opened an
    /// agent, the view stayed, also after `/resume` (1.0.62, live). A
    /// card's hints replace the footer's, so under a card only the header
    /// shows the view.
    let isDashboardOverlay: Bool
    /// The Welcome view Grok opens on, whose composer sends.
    let isWelcome: Bool
    /// Minimal mode: a flush-left `❯` prompt without a box.
    let isMinimal: Bool
    /// The user rows on screen, top to bottom.
    let userRows: [UserRow]
    /// The bottom-most Session line.
    let sessionLine: SessionLine?

    init(_ screen: ANSIScreen) {
        let rows = screen.rows
        var composer = Self.composer(in: rows)
        let below = (composer?.bottomRow ?? -1) + 1
        let footer = rows.indices.reversed().first { $0 >= below && !rows[$0].isBlank }.map { rows[$0].trimmedText }
        let promptHasFocus = Self.promptHasFocus(footer: footer, composer: composer)
        // Without focus, Grok draws its placeholder in an empty box.
        if !promptHasFocus, composer?.draft == "Build anything" {
            composer?.draft = ""
        }
        self.composer = composer
        self.footer = footer
        self.promptHasFocus = promptHasFocus
        pendingDoublePress = footer.flatMap { $0.contains("press again to") ? $0 : nil }
        let area = composer.map { Self.statusArea(rows, above: $0.topRow) }
        statusRow = area?.status
        dockSections = area?.dock ?? []
        cue = area?.cue
        overlay = Self.overlay(rows, composer: composer)
        card = Self.card(in: rows)
        isDashboard =
            composer?.draft == "Dispatch a new agent" || footer?.hasPrefix("Enter:create") == true
            || rows.prefix(6).contains { $0.trimmedText.hasPrefix("+ New Agent") }
        isDashboardOverlay =
            footer?.hasPrefix("Ctrl+\\:dashboard") == true
            || rows.prefix(2).contains { $0.text.range(of: #"‹ \d+/\d+ ›"#, options: .regularExpression) != nil }
        isWelcome = Self.showsWelcome(rows)
        isMinimal = composer == nil && Self.showsMinimalPrompt(rows)
        let boxed = Self.boxedRows(rows)
        userRows = Self.userRows(rows, boxed: boxed)
        sessionLine = Self.sessionLine(rows, boxed: boxed)
    }

    /// The turn waits on something a message would end: a subagent, a
    /// background task's output, every task, or a sleep (`turn_status.rs`
    /// `is_sendable_wait`). Enter then aborts the wait and runs the message
    /// next, cancelling the rest of that turn.
    var sendableWait: Bool {
        if isParked { return true }
        guard let statusRow else { return false }
        let subagentsDocked = dockSections.contains { $0.hasPrefix("Subagents") }
        return statusRow.trailer.contains("Enter to send now")
            || Self.isSendableWait(statusRow.label, subagentsDocked: subagentsDocked)
    }

    /// The cue says a turn is parked in such a wait: `waiting · …`, or a
    /// watcher count followed by `send a message to interrupt` or `N
    /// queued`, either cut at the right edge.
    var isParked: Bool {
        guard let cue else { return false }
        if cue.hasPrefix("waiting") { return true }
        return cue.components(separatedBy: " · ").dropFirst().contains { part in
            guard !part.isEmpty else { return false }
            return Self.interruptHint.hasPrefix(part) || part.range(of: #"^\d+ q"#, options: .regularExpression) != nil
        }
    }

    var isCancelling: Bool { statusRow?.label.hasPrefix("Cancelling") == true }

    // MARK: Composer

    private static func composer(in rows: [ScreenRow]) -> Composer? {
        // The bottom-most box: popups and panels above it draw boxes too.
        for top in rows.indices.reversed() where top + 2 < rows.count {
            guard rows[top].trimmedText.hasPrefix("╭─"), let mode = promptMode(of: rows[top + 1]) else { continue }
            let closing = rows.indices[(top + 2)...].prefix(40).first { rows[$0].trimmedText.hasPrefix("╰─") }
            guard let bottom = closing, rows[(top + 1)..<bottom].allSatisfy({ $0.trimmedText.hasPrefix("│") }) else {
                continue
            }
            var typed: [String] = []
            var ghost: [String] = []
            for index in (top + 1)..<bottom {
                let row = rows[index]
                guard let left = row.indent, let right = lastColumn(of: "│", in: row), right > left else { continue }
                // `│ ❯ ` before the first row's text.
                let text = split(row, from: left + (index == top + 1 ? 4 : 1), to: right)
                typed.append(text.typed.trimmingCharacters(in: .whitespaces))
                ghost.append(text.ghost.trimmingCharacters(in: .whitespaces))
            }
            var draft = typed.filter { !$0.isEmpty }.joined(separator: "\n")
            // Bash mode names its empty box "Run shell command".
            if mode == .bash, draft == "Run shell command" { draft = "" }
            let topLabel = rows[top].trimmedText.trimmingCharacters(in: borderCharacters)
            return Composer(
                mode: mode, draft: draft, ghost: ghost.filter { !$0.isEmpty }.joined(separator: "\n"),
                topBorderLabel: topLabel.isEmpty ? nil : topLabel,
                bottomBorder: rows[bottom].trimmedText.trimmingCharacters(in: borderCharacters),
                topRow: top, bottomRow: bottom)
        }
        return nil
    }

    private static let borderCharacters = CharacterSet(charactersIn: "╭╮╰╯─ ")

    private static func promptMode(of row: ScreenRow) -> Composer.Mode? {
        let text = row.trimmedText
        if text.hasPrefix("│ ❯ ") { return .prompt }
        if text.hasPrefix("│ ! ") { return .bash }
        if text.hasPrefix("│ # ") { return .remember }
        return nil
    }

    /// The column of the last `character` on the row.
    private static func lastColumn(of character: Character, in row: ScreenRow) -> Int? {
        var column = 0
        var last: Int?
        for cell in row.text {
            if cell == character { last = column }
            column += TerminalCellWidth.width(of: cell)
        }
        return last
    }

    /// The text from `start` up to `end`, split into the typed cells and
    /// the italic ones.
    private static func split(_ row: ScreenRow, from start: Int, to end: Int) -> (typed: String, ghost: String) {
        var typed = ""
        var ghost = ""
        for run in row.runs where run.endColumn > start && run.column < end {
            var column = run.column
            for character in run.text {
                let width = TerminalCellWidth.width(of: character)
                defer { column += width }
                guard column >= start, column + width <= end else { continue }
                if run.style.isItalic {
                    ghost.append(character)
                } else {
                    typed.append(character)
                }
            }
        }
        return (typed, ghost)
    }

    // MARK: Status row and dock

    /// Scans up from the composer: blank rows, toasts and dock rows lie
    /// between it and the status row; any other row ends the scan. Rows
    /// indented deeper than a dock header above them are its wrapped items.
    private static func statusArea(_ rows: [ScreenRow], above top: Int)
        -> (status: StatusRow?, cue: String?, dock: [String])
    {
        var dock: [String] = []
        var unclaimed: [Int] = []
        for index in stride(from: top - 1, through: max(0, top - 12), by: -1) {
            let row = rows[index]
            let text = withoutScrollbar(row.trimmedText)
            guard let first = text.unicodeScalars.first, !toasts.contains(where: { text.contains($0) }) else {
                continue
            }
            let indent = row.indent ?? 0
            if first == "▾" || first == "▸" {
                let name = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
                // `▾ show N more` closes a section rather than opening one.
                if name.hasPrefix("show "), name.hasSuffix(" more") { continue }
                guard unclaimed.allSatisfy({ $0 > indent }) else { break }
                unclaimed = []
                dock.insert(name, at: 0)
                continue
            }
            if isDockItem(text) { continue }
            if unclaimed.isEmpty, (0x2800...0x28FF).contains(first.value) {
                return (statusRow(index, text), nil, dock)
            }
            if unclaimed.isEmpty, cueIcons.contains(first) {
                return (nil, String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces), dock)
            }
            unclaimed.append(indent)
        }
        return (nil, nil, dock)
    }

    private static let toasts = ["Press Ctrl+c to cancel the turn", "Input cleared · ctrl+z to undo"]
    /// The monitor icon's frames (`glyphs.rs` `monitor_icon_frames`).
    private static let cueIcons: Set<Unicode.Scalar> = ["○", "◎", "◉"]
    /// A dock item's marker: the dot spinner's frames, or `◆` once it stops
    /// (`views/dock`).
    private static let dockMarkers: Set<Unicode.Scalar> = ["⋅", ":", "⸬", "⁙", "◆"]
    private static let interruptHint = "send a message to interrupt"

    /// A queued message (`#1 …`) or a dock item (`⋅ Subagent …`).
    private static func isDockItem(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(2))
        guard scalars.count == 2 else { return false }
        if scalars[0] == "#" { return ("0"..."9").contains(scalars[1]) }
        return dockMarkers.contains(scalars[0]) && scalars[1] == " "
    }

    /// The spinner, then the label up to its `…` or the phase timer, then
    /// the rest.
    private static func statusRow(_ index: Int, _ text: String) -> StatusRow {
        let rest = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        let ellipsis = rest.firstIndex(of: "…").map { rest.index(after: $0) }
        let timer = rest.range(of: #" (?:\d+\.\ds|\d+s|\d+m\d+s|\d+h\d+m)(?= |$)|  "#, options: .regularExpression)?
            .lowerBound
        let end = [ellipsis, timer].compactMap { $0 }.min() ?? rest.endIndex
        return StatusRow(
            row: index, label: String(rest[..<end]).trimmingCharacters(in: .whitespaces),
            trailer: String(rest[end...]).trimmingCharacters(in: .whitespaces))
    }

    /// How the labels of waits a message ends begin (`acp/tracker.rs`
    /// `WaitingReason::label`), digits read as `#`.
    private static let sendableWaitStems = [
        "Waiting for subagent", "Waiting for # subagents", "Waiting on task output", "Waiting on tasks", "Sleeping",
    ]
    /// Labels of other waits that begin the same way.
    private static let otherWaitLabels = [
        "Waiting…", "Waiting for response…", "Waiting for the agent to accept the prompt…",
    ]

    /// A label a message would end. A label cut to fit counts when it can
    /// only be such a wait; one both kinds begin with, such as `Waiting
    /// for…` at 40 columns, counts while the dock lists subagents.
    private static func isSendableWait(_ label: String, subagentsDocked: Bool) -> Bool {
        let label = label.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        if sendableWaitStems.contains(where: { label.hasPrefix($0) }) { return true }
        guard label.hasSuffix("…"), !otherWaitLabels.contains(label) else { return false }
        let stem = String(label.dropLast())
        guard !stem.isEmpty, sendableWaitStems.contains(where: { $0.hasPrefix(stem) }) else { return false }
        return subagentsDocked || !otherWaitLabels.contains { $0.hasPrefix(stem) }
    }

    // MARK: Overlays and views

    private static func overlay(_ rows: [ScreenRow], composer: Composer?) -> String? {
        for row in rows {
            let text = withoutScrollbar(row.trimmedText)
            if text.hasPrefix("┌─ Resume session") || (text.contains("↑↓ nav") && text.contains("d delete"))
                || (text.hasPrefix("┃") && text.contains("Rewind to which turn?"))
                || (text.hasPrefix("╭─ /btw ") && text.hasSuffix("[Esc] ╮"))
            {
                return text
            }
        }
        // The slash, `@` and model popups sit on a rule directly above the
        // composer, and their top rule ends with a count.
        guard let composer, composer.topRow > 0 else { return nil }
        let rule = rows[composer.topRow - 1]
        let ruleText = withoutScrollbar(rule.trimmedText)
        guard ruleText.count >= 10, ruleText.allSatisfy({ $0 == "─" }), rule.indent == rows[composer.topRow].indent
        else { return nil }
        for index in stride(from: composer.topRow - 2, through: max(0, composer.topRow - 24), by: -1) {
            let text = withoutScrollbar(rows[index].trimmedText)
            if text.range(of: #"^─+(?:\d+(?:/\d+)?─)?$"#, options: .regularExpression) != nil {
                return withoutScrollbar(rows[index + 1].trimmedText)
            }
        }
        return ruleText
    }

    private static func card(in rows: [ScreenRow]) -> Range<Int>? {
        guard let bottom = rows.indices.last(where: { rows[$0].trimmedText.hasPrefix("┃") }) else { return nil }
        var top = bottom
        while top > 0, rows[top - 1].trimmedText.hasPrefix("┃") { top -= 1 }
        let card = top..<(bottom + 1)
        let offersOptions = card.contains {
            rows[$0].trimmedText.range(of: optionRow, options: .regularExpression) != nil
        }
        return offersOptions ? card : nil
    }

    /// A row key, digits or a letter such as `z` or `y`, then the radio
    /// mark (herdr's Blocked rule for Grok Build).
    private static let optionRow = #"^┃\s+[0-9a-z]+\s+\([●○]\)(?:\s|$)"#

    /// See `promptHasFocus`. With text in the box, a compact footer or the
    /// dashboard view's leaves focus unknown, so it reads as unfocused. For
    /// the dashboard's view the empty-box rule rests on 62×41 captures with
    /// the prompt focused; none shows that view without focus, or at 40 or
    /// 120 columns.
    private static func promptHasFocus(footer: String?, composer: Composer?) -> Bool {
        guard let footer else { return false }
        if footer.contains("Shift+Tab:mode") || footer.contains("accept suggestion") { return true }
        let onlyTheBoxTells = footer == "Ctrl+.:shortcuts" || footer.hasPrefix("Ctrl+\\:dashboard")
        return onlyTheBoxTells && composer?.draft.isEmpty == true
    }

    /// The Welcome menu lists `Resume session … ctrl+r` and `Quit … ctrl+q`
    /// (never matched by its version string). From about 90 columns Grok draws it
    /// in a box beside its logo; narrower, as at a phone's 40 to 62
    /// columns, it stacks the menu under the logo without the box (1.0.45
    /// `views/welcome/hero_box.rs`), each row only its label and key.
    private static func showsWelcome(_ rows: [ScreenRow]) -> Bool {
        let boxed = rows.compactMap { row -> String? in
            let text = row.trimmedText
            guard text.count > 1, text.hasPrefix("│"), text.hasSuffix("│") else { return nil }
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if boxed.contains(where: { $0.contains("Resume session") && $0.hasSuffix("ctrl+r") })
            && boxed.contains(where: { $0.contains("Quit") && $0.hasSuffix("ctrl+q") })
        {
            return true
        }
        let stacked = rows.map(\.trimmedText)
        return stacked.contains { $0.range(of: #"^Resume session\s{2,}ctrl\+r$"#, options: .regularExpression) != nil }
            && stacked.contains { $0.range(of: #"^Quit\s{2,}ctrl\+q$"#, options: .regularExpression) != nil }
    }

    // MARK: Scrollback

    /// Which rows lie inside a box: rows that begin with `│` or `┃`, and
    /// everything from a `╭` or `┌` top through its `╰` or `└` bottom.
    private static func boxedRows(_ rows: [ScreenRow]) -> [Bool] {
        var isOpen = false
        return rows.map { row in
            let text = row.trimmedText
            if text.hasPrefix("╭") || text.hasPrefix("┌") {
                isOpen = true
                return true
            }
            if text.hasPrefix("╰") || text.hasPrefix("└") {
                isOpen = false
                return true
            }
            return isOpen || text.hasPrefix("│") || text.hasPrefix("┃")
        }
    }

    /// Rows outside boxes that begin `❯ ` at a three- to six-column
    /// indent (five in every capture), never the composer's or a queued
    /// item's. The row's time comes in either form: the default `%-I:%M
    /// %p`, or `HH:MM:SS | Mon D` while hovered (1.0.45
    /// `scrollback/wrappers/entry_renderer.rs`). Compact mode, at 20 rows
    /// or fewer, draws its user rows without the `❯`, apart from replies
    /// only by a shaded band, so it shows none.
    private static func userRows(_ rows: [ScreenRow], boxed: [Bool]) -> [UserRow] {
        rows.indices.compactMap { index in
            let text = ScreenRow.normalizedSpaces(rows[index].text)
            guard !boxed[index], text.contains("❯"),
                let lead = text.range(of: #"^ {3,6}❯ "#, options: .regularExpression)
            else { return nil }
            var rest = withoutScrollbar(String(text[lead.upperBound...]))
            for time in userRowTimes {
                guard let range = rest.range(of: time, options: .regularExpression) else { continue }
                rest = String(rest[..<range.lowerBound])
                break
            }
            return UserRow(text: rest.trimmingCharacters(in: .whitespaces))
        }
    }

    private static let userRowTimes = [
        #"\s{2,}\d{1,2}:\d{2}\s?[AP]M\s*$"#, #"\s{2,}\d{2}:\d{2}:\d{2} \| [A-Z][a-z]{2} \d{1,2}\s*$"#,
    ]

    /// The bottom-most row outside boxes that, joined with the rows that
    /// wrap it, reads as a Session line. Grok wraps system lines at word
    /// ends and after an id's hyphens, keeping the indent, so a narrow
    /// screen splits the ids: at 40 columns the `/fork` form takes four
    /// rows before its `, use`. Whitespace goes before matching, so
    /// assistant text that merely starts with an id never matches. The
    /// `Session: <id>` form Grok prints without `/new` is not matched.
    private static func sessionLine(_ rows: [ScreenRow], boxed: [Bool]) -> SessionLine? {
        for index in rows.indices.reversed() where !boxed[index] && rows[index].trimmedText.hasPrefix("Session") {
            let first = withoutScrollbar(rows[index].trimmedText)
            guard first == "Session" || first.hasPrefix("Session "), let indent = rows[index].indent else { continue }
            var joined = first
            for next in rows.indices.dropFirst(index + 1).prefix(sessionLineWraps) {
                let text = withoutScrollbar(rows[next].trimmedText)
                guard !boxed[next], rows[next].indent == indent, let lead = text.first,
                    lead.isLetter || lead.isNumber || "(),-/".contains(lead), !text.hasPrefix("Session")
                else { break }
                joined += text
            }
            let squeezed = String(joined.filter { !$0.isWhitespace })
            guard squeezed.range(of: sessionLinePattern, options: .regularExpression) != nil else { continue }
            let id = squeezed.dropFirst("Session".count).prefix(36)
            return SessionLine(sessionID: id.lowercased())
        }
        return nil
    }

    /// The most rows a Session line wraps onto below its first.
    private static let sessionLineWraps = 4
    private static let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private static let sessionLinePattern = "^Session\(uuid)(\\(forkedfrom\(uuid)\\))?(,use/|foundlocally)"

    /// Minimal mode draws its prompt flush left, with `minimal · … /help`
    /// above it while idle (1.0.62, live; the 1.0.45 source). The
    /// full-screen view indents every row, its past prompts by five.
    private static func showsMinimalPrompt(_ rows: [ScreenRow]) -> Bool {
        rows.dropFirst(rows.count * 2 / 3).contains { row in
            let text = ScreenRow.normalizedSpaces(row.text)
            let trimmed = row.trimmedText
            return text.hasPrefix("❯ ") || (text.hasPrefix("❯") && trimmed == "❯")
                || (trimmed.hasPrefix("minimal · ") && trimmed.hasSuffix("/help"))
        }
    }

    /// The row without the scrollbar Grok draws at the right edge of the
    /// scrollback and of a card's long list, trimmed.
    static func withoutScrollbar(_ text: String) -> String {
        guard let range = text.range(of: #"\s*[█▐▌]+\s*$"#, options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}
