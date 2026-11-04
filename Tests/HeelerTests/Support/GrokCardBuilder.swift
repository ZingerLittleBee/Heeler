import Foundation

@testable import Heeler

/// A synthetic Grok Build card in the composer's place, for states and
/// widths no capture shows. Rows sit behind the `┃` bar on the card's
/// lighter background and start at the content column, two cells after
/// the bar; the cursor's row lies on a band, or in reverse video under the
/// terminal theme; the card's hints fill the footer. Rows follow the 1.0.62
/// captures, and other widths the 1.0.45 source: a row stops at the
/// card's edge two cells short of its right side, a turn status label is
/// cut to fit, and a question wraps (`views/permission_view.rs`,
/// `views/question_view.rs`, `views/turn_status.rs`). Callers give rows as
/// Grok draws them at the width; the builder clips them at the edge.
struct GrokCardBuilder {
    /// One row inside the card, from the content column.
    struct Row {
        var text: String
        /// The cursor's band, from the content column to the edge.
        var band = false
        /// Where bold starts, in characters into `text`: a question's text,
        /// the cursor's label.
        var boldFrom: Int?

        init(_ text: String, band: Bool = false, boldFrom: Int? = nil) {
            self.text = text
            self.band = band
            self.boldFrom = boldFrom
        }

        static let blank = Row("")

        static func bold(_ text: String) -> Row { Row(text, boldFrom: 0) }

        /// `<key> (○) label`: the cursor's row with its band and bold
        /// label. A card without the keyboard keeps the bold, not the band.
        static func option(_ text: String, cursor: Bool = false, band: Bool? = nil) -> Row {
            Row(text, band: band ?? cursor, boldFrom: cursor ? 6 : nil)
        }
    }

    var columns = 120
    var height = 30
    /// The turn status label after `◆ `, which Grok shows while a turn
    /// waits on the card.
    var status: String?
    var rows: [Row]
    var hints: [String]
    /// The terminal theme: default colors, and reverse video for the band.
    var terminalTheme = false
    /// The header row from column 2, such as one with the dashboard's
    /// `‹ 1/2 ›` switcher.
    var header = "master ~/s/cap-grok-b/proj"

    var screen: ANSIScreen { ANSIScreenDecoder.decode(ansi) }

    var ansi: String {
        var bottom: [String] = []
        if let status { bottom += [statusRow(status), blank] }
        bottom += ([Row.blank] + rows + [Row.blank]).map(cardRow)
        bottom += [blank, footerRow(), blank]
        let top = [blank, line([("  ", ""), (header, muted)]), blank]
        let filler = Array(repeating: blank, count: max(0, height - top.count - bottom.count))
        return (top + filler + bottom).joined(separator: "\r\n")
    }

    // MARK: Rows

    private var screenBackground: String { terminalTheme ? SGR.reset : SGR.reset + SGR.bg(20, 20, 20) }
    private var cardBackground: String { terminalTheme ? SGR.reset : SGR.reset + SGR.bg(36, 36, 36) }
    private var bandBackground: String { terminalTheme ? SGR.reset + SGR.reverse : SGR.reset + SGR.bg(54, 54, 54) }
    private var text: String { terminalTheme ? "" : SGR.fg(225, 225, 225) }
    private var muted: String { terminalTheme ? SGR.dim : SGR.fg(108, 108, 108) }

    private var blank: String { line([]) }

    /// `(text, style)` segments on the screen's background, padded to the
    /// full width.
    private func line(_ segments: [(String, String)]) -> String {
        var result = ""
        var width = 0
        for (text, style) in segments where !text.isEmpty {
            result += screenBackground + style + text
            width += TerminalCellWidth.width(of: text)
        }
        return result + screenBackground + String(repeating: " ", count: max(0, columns - width))
    }

    /// Two cells of margin, the bar, two cells of padding, the content up
    /// to the edge, two cells of padding, two cells of margin.
    private func cardRow(_ row: Row) -> String {
        let content = columns - 9
        let shown = GrokScreenBuilder.clip(row.text, to: content)
        let background = row.band ? bandBackground : cardBackground
        var result = screenBackground + "  " + cardBackground + (terminalTheme ? "" : SGR.fg(200, 200, 200)) + "┃"
            + cardBackground + "  "
        if let bold = row.boldFrom, bold < shown.count {
            result += background + text + String(shown.prefix(bold)) + background + SGR.bold + text
                + String(shown.dropFirst(bold))
        } else {
            result += background + text + shown
        }
        let fill = String(repeating: " ", count: max(0, content - TerminalCellWidth.width(of: shown)))
        return result + background + fill + cardBackground + "  " + screenBackground + "  "
    }

    /// `◆`, the label cut to fit, and the turn's timers at the right, as
    /// `GrokScreenBuilder` lays out the status row.
    private func statusRow(_ label: String) -> String {
        let area = columns - 5
        let right = "7.2s ⇣27.4k [stop]"
        let rightWidth = TerminalCellWidth.width(of: right)
        let cut = GrokScreenBuilder.cut(label, to: area - 2 - 1 - rightWidth - 2)
        let gap = area - 2 - TerminalCellWidth.width(of: cut) - rightWidth
        let spacer = String(repeating: " ", count: max(1, gap))
        return line([("   ", ""), ("◆ ", muted), (cut, text), (spacer, ""), (right, muted)])
    }

    /// Each hint's separator, key, colon and label, stopping at the first
    /// piece that doesn't fit.
    private func footerRow() -> String {
        let area = columns - 4
        var segments: [(String, String)] = [("  ", "")]
        var used = 0
        hints: for (index, hint) in hints.enumerated() {
            let parts = hint.split(separator: ":", maxSplits: 1).map(String.init)
            let pieces = [index > 0 ? "  │  " : "", parts[0], ":", parts.count > 1 ? parts[1] : ""]
            for piece in pieces where !piece.isEmpty {
                guard used + TerminalCellWidth.width(of: piece) <= area else { break hints }
                segments.append((piece, muted))
                used += TerminalCellWidth.width(of: piece)
            }
        }
        return line(segments)
    }
}

/// Grok Build cards by stem: the captures (`grok-…`), and the synthetic
/// cards below (`synthetic-…`) for states and widths no capture shows.
enum GrokCards {
    typealias Row = GrokCardBuilder.Row

    static func screen(_ stem: String) throws -> ANSIScreen {
        if let builder = synthetic(stem) { return builder.screen }
        return try ScreenFixture.screen(stem)
    }

    static func parse(_ stem: String) throws -> DialogParseResult {
        GrokDialogParser.parse(try screen(stem))
    }

    static func dialog(_ stem: String) throws -> BlockedDialog {
        let result = try parse(stem)
        guard let dialog = result.dialog else { throw Unparsed(stem: stem, result: result) }
        return dialog
    }

    struct Unparsed: Error, CustomStringConvertible {
        let stem: String
        let result: DialogParseResult
        var description: String { "\(stem) parsed as \(result)" }
    }

    static let permissionHints = [
        "1/5:select", "Tab:next option", "←/→:scope", "e:edit pattern", "Ctrl+o:always-approve", "Ctrl+c:cancel",
        "Esc:scrollback",
    ]
    static let questionHints = ["Tab:next answer", "Esc:scrollback", "Shift+x:dismiss"]

    static func synthetic(_ stem: String) -> GrokCardBuilder? {
        switch stem {
        case "synthetic-permission-40":
            permission(columns: 40)
        case "synthetic-permission-62":
            permission(columns: 62)
        case "synthetic-permission-120":
            permission(columns: 120)
        case "synthetic-permission-40-terminal-theme":
            permission(columns: 40, terminalTheme: true)
        case "synthetic-unfocused-permission":
            // Esc parked the keyboard in the scrollback: no band, and the
            // footer offers the card back, in words no capture shows yet.
            permission(columns: 120, focused: false)
        case "synthetic-permission-cursor-on-always-approve":
            permission(columns: 120, cursor: 1)
        case "synthetic-permission-cursor-on-never-allow":
            permission(columns: 120, cursor: 5)
        case "synthetic-permission-dashboard-overlay":
            // The dashboard shows another agent's card; the switcher in
            // the header is all that tells.
            permission(columns: 120, header: "master ~/s/cap-grok-b/proj  ‹ 2/3 › │ [Dashboard]")
        case "synthetic-edit-permission-session-cut":
            // No capture or source shows Grok cutting this fixed label
            // with `…`; the card checks that a session rule cut that way
            // would stay in the terminal like a cut `Always allow:`.
            GrokCardBuilder(
                columns: 40, status: "Edit notes.txt 0.1s",
                rows: [Row("›  Allow Edit to notes.txt?", boldFrom: 3), .blank]
                    + options(
                        [
                            "Yes, and don't ask again for anything (always-approve mode)", "Yes, allow all edits du…",
                            "Yes", "No, reject (type to add feedback)",
                        ], cursor: 3),
                hints: ["1/4:select", "Tab:next option", "Ctrl+o:always-approve", "Ctrl+c:cancel", "Esc:scrollback"])
        case "synthetic-subagent-permission-40":
            // grok-35's card at 40 columns: Grok cuts the card's question
            // at the edge with `…`, as it cuts a command's description
            // there (grok-36), so the question's `?` is gone.
            GrokCardBuilder(
                columns: 40, status: "Waiting for subagent…",
                rows: [Row(GrokScreenBuilder.cut("›  Allow Sleep 60 then reply done?", to: 40 - 9), boldFrom: 3), .blank]
                    + options(
                        [
                            "Yes, and don't ask again for anything (always-approve mode)", "Yes, send once",
                            "No, reject (type to add feedback)",
                        ], cursor: 2),
                hints: ["1/3:select", "Tab:next option", "Ctrl+o:always-approve", "Ctrl+c:cancel", "Esc:scrollback"])
        case "synthetic-question-40":
            // The cursor's answer wraps its label and description at 25
            // cells; the other answer shows one row, its description cut.
            GrokCardBuilder(
                columns: 40, status: "Waiting on answers for How should we handle the README rename plan?",
                rows: [
                    .bold("How should we handle the README"), .bold("rename plan?"), .blank, .blank,
                    .option("1 (○) Keep it as a todo", cursor: true),
                    Row("      (Recommended)", band: true, boldFrom: 6),
                    Row("      Leave the three-step plan", band: true),
                    Row("      in the todos and change", band: true),
                    Row("      no files.", band: true), .option("2 (○) Rename it now       Sta…"),
                    .option("z (○) Type your answer here"), .blank, Row("↑/↓ navigate · y copy"),
                ],
                hints: questionHints)
        case "synthetic-question-62":
            // The labels fit their column; the cursor's description wraps
            // under its first row.
            GrokCardBuilder(
                columns: 62, status: "Waiting on answers for How should we handle the README rename plan?",
                rows: [
                    .bold("How should we handle the README rename plan?"), .blank, .blank,
                    .option("1 (○) Keep it as a todo (Recommended)  Leave the", cursor: true),
                    Row(String(repeating: " ", count: 39) + "three-step", band: true),
                    Row(String(repeating: " ", count: 39) + "plan in the", band: true),
                    Row(String(repeating: " ", count: 39) + "todos and", band: true),
                    Row(String(repeating: " ", count: 39) + "change no", band: true),
                    Row(String(repeating: " ", count: 39) + "files.", band: true),
                    .option("2 (○) Rename it now                    Start the…"),
                    .option("z (○) Type your answer here"), .blank, Row("↑/↓ navigate · y copy"),
                ],
                hints: questionHints)
        case "synthetic-unfocused-question":
            GrokCardBuilder(
                status: "Waiting on answers for Which fruit?",
                rows: [
                    .bold("Which fruit?"), .blank, .blank, .option("1 (○) Apple", cursor: true, band: false),
                    .option("2 (○) Pear"), .option("z (○) Type your answer here"), .blank,
                    Row("↑/↓ navigate · y copy"),
                ],
                hints: ["Tab/Space:question"])
        case "synthetic-question-cursor-on-field":
            // Any key but a space on this row goes into the field.
            GrokCardBuilder(
                status: "Waiting on answers for Which fruit?",
                rows: [
                    .bold("Which fruit?"), .blank, .blank, .option("1 (○) Apple"), .option("2 (○) Pear"),
                    Row("z (○) Type your answer here", band: true), .blank, Row("↑/↓ navigate · y copy"),
                ],
                hints: questionHints)
        case "synthetic-question-cursor-unseen":
            // The card has the keyboard, but no row shows the cursor.
            GrokCardBuilder(
                status: "Waiting on answers for Which fruit?",
                rows: [
                    .bold("Which fruit?"), .blank, .blank, .option("1 (○) Apple"), .option("2 (○) Pear"),
                    .option("z (○) Type your answer here"), .blank, Row("↑/↓ navigate · y copy"),
                ],
                hints: questionHints)
        case "synthetic-question-ten-answers":
            // The tenth answer's key is `a`.
            GrokCardBuilder(
                height: 40, status: "Waiting on answers for Which number?",
                rows: [.bold("Which number?"), .blank, .blank, .option("1 (○) One", cursor: true)]
                    + ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"].enumerated().map { item in
                        Row.option("\(item.offset + 2) (○) \(item.element)")
                    }
                    + [
                        .option("a (○) Ten"), .option("z (○) Type your answer here"), .blank,
                        Row("↑/↓ navigate · y copy"),
                    ],
                hints: questionHints)
        case "synthetic-multi-question":
            // The counter and `←/→ question` show several questions.
            GrokCardBuilder(
                status: "Waiting on answers for Which fruit?",
                rows: [
                    .bold("Which fruit?"), .blank, .blank, .option("1 (○) Apple", cursor: true),
                    .option("2 (○) Pear"), .option("z (○) Type your answer here"), .blank,
                    Row("[1/2] ↑/↓ navigate · ←/→ question · y copy"),
                ],
                hints: questionHints)
        case "synthetic-unknown-card":
            // A card Heeler doesn't know, such as an MCP server's request.
            GrokCardBuilder(
                rows: [
                    .bold("github wants to open a browser window"), .blank, .option("1 (●) Accept", cursor: true),
                    .option("2 (○) Decline"),
                ],
                hints: ["Enter:accept / toggle", "d:decline", "Ctrl+c:cancel", "Tab:next field", "Esc:scrollback"])
        case "synthetic-fork-cursor-on-field":
            // Any key but a space on this row goes into the field.
            fork(cursor: "z")
        case "synthetic-fork-cursor-on-always-worktree":
            fork(cursor: "3")
        case "synthetic-fork-cursor-unseen":
            // The card has the keyboard, but no row shows the cursor.
            fork(cursor: nil)
        case "synthetic-unfocused-fork":
            fork(cursor: "1", focused: false)
        case "synthetic-subagents-40":
            subagents(columns: 40)
        case "synthetic-subagents-cursor-on-always-stop":
            subagents(columns: 120, cursor: 3)
        default:
            nil
        }
    }

    /// A command's permission like grok-12's, the cursor on the row keyed
    /// `cursor`. At 40 columns the always-approve and reject rows stop at
    /// the card's edge.
    private static func permission(
        columns: Int, focused: Bool = true, cursor: Int = 3, terminalTheme: Bool = false,
        header: String = "master ~/s/cap-grok-b/proj"
    ) -> GrokCardBuilder {
        let labels = [
            "Yes, and don't ask again for anything (always-approve mode)", "Always allow: ls -l", "Yes, proceed",
            "No, reject (type to add feedback)", "Never allow: ls",
        ]
        return GrokCardBuilder(
            columns: columns, status: "List the files… 0.1s",
            rows: [
                Row("›  List the files", boldFrom: 3), Row("│ ls -l"), Row("← → narrow scope  ·  e edit pattern"),
                .blank,
            ] + options(labels, cursor: cursor, band: focused),
            hints: focused ? permissionHints : ["Tab/Space:permission"], terminalTheme: terminalTheme, header: header)
    }

    /// `/fork`'s worktree question like grok-25's, the cursor on the row
    /// keyed `cursor`. Without the keyboard the cursor's row keeps its bold
    /// label, not the band, and the footer offers the card back.
    private static func fork(cursor: String?, focused: Bool = true) -> GrokCardBuilder {
        let answers = [
            "1 (○) Yes              Fork in a new isolated git worktree",
            "2 (○) No               Fork in the current cwd",
            "3 (○) Always worktree  Use worktree and stop asking (reset in config.toml)",
            "4 (○) Never worktree   Skip worktree and stop asking (reset in config.toml)",
        ]
        let rows = answers.map { text in
            let isCursor = text.hasPrefix("\(cursor ?? "") (")
            return Row.option(text, cursor: isCursor, band: isCursor && focused)
        }
        let field = Row("z (○) Type your answer here", band: cursor == "z" && focused)
        return GrokCardBuilder(
            rows: [.bold("Run this fork in an isolated git worktree?"), .blank, .blank] + rows
                + [field, .blank, Row("↑/↓ navigate · y copy")],
            hints: focused ? questionHints : ["Tab/Space:question"])
    }

    /// The panel Ctrl+C opens while a subagent runs, like grok-16's, the
    /// cursor on the row keyed `cursor`.
    private static func subagents(columns: Int, cursor: Int = 1) -> GrokCardBuilder {
        GrokCardBuilder(
            columns: columns,
            rows: [.bold("Subagents are still running. Stop them?"), Row("1 subagent running"), .blank]
                + options(["Stop running", "Continue to run", "Always stop", "Always continue"], cursor: cursor),
            hints: ["1/4:select", "Tab:next choice", "Enter:confirm", "Esc:keep running"])
    }

    /// Rows keyed from `1`, `(●)` and the bold label marking the cursor's,
    /// which lies on the band while the card has the keyboard.
    private static func options(_ labels: [String], cursor: Int, band: Bool = true) -> [Row] {
        labels.enumerated().map { offset, label in
            let key = offset + 1
            return Row.option(
                "\(key) (\(key == cursor ? "●" : "○")) \(label)", cursor: key == cursor, band: key == cursor && band)
        }
    }
}
