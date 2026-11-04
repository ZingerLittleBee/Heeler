import Foundation

/// Reads Grok Build's cards (1.0.62). A card takes the composer's place:
/// rows behind a `┃` bar on a lighter background, each option a row
/// `<key> (○) <label>` with any description two spaces or more after the
/// label, and the card's own hints in the footer. Heeler knows four: a
/// permission, which also asks before a subagent starts, a single question
/// the agent asks during its turn, the worktree question `/fork` asks
/// (every answer forks, and herdr's session stays on this one), and the
/// panel Ctrl+C opens while subagents run. Any other card with options
/// holds sending as an excerpt without numbers, so the generic card offers
/// only its key pad: the rewind confirmation, several questions at once,
/// the fork question too narrow to read, and the cards not captured yet.
///
/// The cursor's row lies on a band of another background, or in reverse
/// video under the terminal theme, its label bold. On a permission and on
/// the subagent panel `(●)` marks the cursor too; on a question it marks a
/// chosen answer. Esc hands the keyboard to the scrollback and leaves the
/// card drawn without its band (`key_owner.rs`), and a key would then miss
/// the card, so the cursor counts only while the footer shows the card's
/// hints. A row's key selects that row wherever the cursor is, a row Heeler
/// leaves to the terminal included (`interactions.rs`), so the hints, not
/// the cursor, say whether keys reach the card. A row too long for the
/// card stops at its edge, and a label cut there still names the option it
/// begins.
enum GrokDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        let grok = GrokScreen(screen)
        guard let rows = grok.card else { return .none }
        let card = GrokCard(rows: rows, of: screen, footer: grok.footer)
        // The card of an agent the dashboard shows, which may not be this
        // conversation's.
        if grok.isDashboardOverlay { return .unrecognized(card.excerpt(overlayReason)) }
        if let dialog = cancelPanel(card) ?? permission(card) ?? question(card, on: screen) ?? fork(card) {
            return .dialog(dialog)
        }
        return .unrecognized(card.excerpt(genericReason(card)))
    }

    /// Why a card stays generic: `/fork`'s worktree question that `fork`
    /// can't read, with or without its lasting rows in view, a question
    /// Heeler doesn't answer, or a card it doesn't know.
    private static func genericReason(_ card: GrokCard) -> String {
        if answerSheet(card)?.question == forkQuestion {
            let lasting = forkRows.filter { !$0.offered }.map { $0.label }
            let shown = lasting.allSatisfy { label in card.lines.contains { $0.option?.names(label) == true } }
            return shown ? forkReason : forkHiddenRowsReason
        }
        let asks = card.lines.contains { $0.option?.key == freeTextKey }
        return asks ? questionReason : unknownReason
    }

    private static let unknownReason =
        "Heeler doesn't know this Grok Build card. Answer it with these keys or in the terminal."
    private static let overlayReason =
        "Grok Build is showing this card for an agent from its dashboard, which may not be this conversation. "
        + "Answer it with these keys or in the terminal."
    private static let questionReason =
        "Heeler answers only a single question Grok Build asks during its turn. Answer this one with these keys "
        + "or in the terminal."
    private static let forkReason =
        "Grok Build's /fork asks this, and every answer forks. Always worktree and Never worktree also save a "
        + "lasting choice. Answer in the terminal or with these keys."
    private static let forkHiddenRowsReason =
        "Grok Build's /fork asks this, and every answer forks. Always worktree and Never worktree, which this "
        + "width hides, also save a lasting choice. Answer in the terminal or with these keys."

    // MARK: Permission

    /// `›  <description>`, the command on `│` rows, the scope hint, then the
    /// options, recognised by the reject row. A digit selects its row and
    /// submits it (`interactions.rs`). Always-approve mode and `Never
    /// allow:` stay on screen and in the body, never among the options, as
    /// does a lasting rule Grok cut to fit with `…`, whose reach the card
    /// then hides; the note says how to see it. Before a subagent starts,
    /// Grok asks `Allow <description>?` alone, and `Yes, send once`
    /// approves that subagent (1.0.62, live).
    private static func permission(_ card: GrokCard) -> BlockedDialog? {
        guard let first = card.lines.firstIndex(where: { $0.option != nil }) else { return nil }
        var options: [DialogOption] = []
        var withheld: [String] = []
        var hidesRule = false
        for index in first..<card.lines.count {
            let line = card.lines[index]
            guard let option = line.option else {
                // Only blank rows follow the options. Anything else, such
                // as feedback typed on the reject row, leaves the card to
                // the terminal.
                guard line.text.isEmpty else { return nil }
                continue
            }
            guard let number = Int(option.key), (1...9).contains(number), let row = permissionRow(option) else {
                return nil
            }
            switch row {
            case .withheld(let label):
                withheld.append(label)
            case .cutRule(let label):
                withheld.append(label)
                hidesRule = true
            case .offered(let label, let role):
                options.append(
                    DialogOption(
                        ordinal: options.count + 1, number: number, label: label,
                        detail: role == .decline ? "Ends the turn" : nil, shortcut: option.key, role: role,
                        isFocused: index == card.cursor))
            }
        }
        let roles = Set(options.map(\.role))
        guard roles.contains(.decline), roles.contains(.approve) else { return nil }

        let head = card.lines[..<first]
        let description = head.first { $0.text.hasPrefix("›") }
            .map { String($0.text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var command = head.filter { $0.text.hasPrefix("│") }
            .map { String($0.text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        // A command too long for its rows ends in ` …`.
        if command.hasSuffix("…") { command = String(command.dropLast()).trimmingCharacters(in: .whitespaces) }

        var subject = DialogSubject()
        let title: String
        if !command.isEmpty {
            title = "Allow Command"
            subject.command = command
            // Cut to fit, the description gives way to the command.
            subject.commandDescription = description?.hasSuffix("…") == true ? nil : description
        } else if let description, options.contains(where: { $0.label == sendOnce }) {
            // The subagent's own words, which may read like an edit's.
            title = description.hasSuffix("?") ? String(description.dropLast()) : description
        } else if let description, let target = description.wholeMatch(of: /Allow (\S+) to (.+)/) {
            // `Allow Edit to <path>?`. The card's edge can cut the path,
            // and then its `?` is gone.
            title = "Allow \(target.1)"
            if target.2.hasSuffix("?") { subject.filePath = String(target.2.dropLast()) }
        } else if let description, description.hasPrefix("Allow "), description.hasSuffix("?") {
            title = String(description.dropLast())
        } else {
            title = "Allow Tool"
        }
        let body = [description, subject.command].compactMap { $0 } + withheld
        return BlockedDialog(
            kind: .grokPermission, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: nil,
            options: options, rows: card.rows,
            fingerprint: DialogFingerprint(
                program: .grok, kind: .grokPermission, title: title, sourceSuffix: nil, body: body, progress: nil,
                options: options),
            focus: card.focus(of: options), subject: subject, note: hidesRule ? cutRuleNote : nil)
    }

    private enum PermissionRow {
        case offered(label: String, role: DialogOptionRole)
        case withheld(label: String)
        /// A lasting rule cut to fit with `…`.
        case cutRule(label: String)
    }

    /// A permission's row by its label, whole or as far as the card's edge
    /// let it show. A known label reads in full even where it was cut.
    private static func permissionRow(_ option: GrokCard.Option) -> PermissionRow? {
        let offered: [(String, DialogOptionRole)] = [
            ("Yes, proceed", .approve), ("Yes", .approve), (sendOnce, .approve), (sessionEdits, .approvePersistent),
            (reject, .decline),
        ]
        if let known = offered.first(where: { option.names($0.0) }) {
            return .offered(label: known.0, role: known.1)
        }
        if option.names(alwaysApprove) { return .withheld(label: alwaysApprove) }
        // The rule's scope follows the colon, cut to fit with `…`, and a
        // cut scope hides how far the rule reaches.
        if option.begins(with: "Always allow:") {
            return option.label.hasSuffix("…")
                ? .cutRule(label: option.label) : .offered(label: option.label, role: .approvePersistent)
        }
        if option.shortens(sessionEdits) { return .cutRule(label: option.label) }
        if option.begins(with: "Never allow:") { return .withheld(label: option.label) }
        return nil
    }

    private static let reject = "No, reject (type to add feedback)"
    private static let sendOnce = "Yes, send once"
    private static let sessionEdits = "Yes, allow all edits during this session"
    private static let alwaysApprove = "Yes, and don't ask again for anything (always-approve mode)"
    private static let cutRuleNote = "Widen the terminal to see the lasting rule."

    // MARK: Question

    /// One question with single-select answers keyed `1` to `9`, then `a`
    /// on, and the typed answer's `z` row last, under the turn's `◆ Waiting
    /// on answers for <question>` row. Several questions add a counter to
    /// the card's hint row, `[1/2] ↑/↓ navigate · ←/→ question`, and stay
    /// generic, as does a question with no turn waiting on it other than
    /// the fork question. A key selects its answer and submits the
    /// question. The footer's `Tab:next answer` and `Shift+x:dismiss` go
    /// while the scrollback has the keyboard, so they mark only the cursor.
    private static func question(_ card: GrokCard, on screen: ANSIScreen) -> BlockedDialog? {
        guard waitsOnAnswers(screen.rows, above: card.rows.lowerBound), let sheet = answerSheet(card) else {
            return nil
        }
        var options = sheet.answers.enumerated().map { offset, answer in
            answer.option(ordinal: offset + 1, focused: answer.line == card.cursor)
        }
        options.append(freeTextOption(ordinal: options.count + 1, focused: sheet.field == card.cursor))
        var subject = DialogSubject()
        subject.question = sheet.question
        let body = [sheet.question] + sheet.description
        return BlockedDialog(
            kind: .grokQuestion, title: sheet.question, sourceSuffix: nil, positionLabel: nil, body: body,
            progress: nil, options: options, rows: card.rows,
            fingerprint: DialogFingerprint(
                program: .grok, kind: .grokQuestion, title: sheet.question, sourceSuffix: nil, body: body,
                progress: nil, options: options),
            focus: card.focus(of: options), subject: subject)
    }

    /// A question card's rows: the question's text, then any description,
    /// above the answers keyed from `1` and the typed answer's `z` row.
    private struct AnswerSheet {
        var question: String
        var description: [String]
        var answers: [Answer]
        /// The line of the `z` row.
        var field: Int
    }

    private static func answerSheet(_ card: GrokCard) -> AnswerSheet? {
        guard let first = card.lines.firstIndex(where: { $0.option != nil }) else { return nil }
        let head = card.lines[..<first].map(\.text).drop { $0.isEmpty }
        let text = head.prefix { !$0.isEmpty }
        let question = text.joined(separator: " ")
        guard !question.isEmpty else { return nil }
        let description = head.dropFirst(text.count).filter { !$0.isEmpty }

        var answers: [Answer] = []
        var field: Int?
        for index in first..<card.lines.count {
            let line = card.lines[index]
            if let option = line.option {
                guard field == nil, option.key.count == 1 else { return nil }
                if option.key == freeTextKey {
                    guard option.label == freeTextLabel, option.detail == nil, !answers.isEmpty else { return nil }
                    field = index
                    continue
                }
                guard let key = answerKeys.firstIndex(of: option.key),
                    answers.last.map({ answerKeys.firstIndex(of: $0.key) == key - 1 }) ?? true
                else { return nil }
                answers.append(
                    Answer(
                        key: option.key, label: [option.label], detail: option.detail.map { [$0] } ?? [], line: index,
                        column: line.column))
            } else if line.text.isEmpty {
                continue
            } else if field == nil, let last = answers.last, line.column > last.column {
                // The cursor's answer wraps: its label bold, its
                // description not.
                if line.isBold, answers[answers.count - 1].detail.isEmpty {
                    answers[answers.count - 1].label.append(line.text)
                } else {
                    answers[answers.count - 1].detail.append(line.text)
                }
            } else if field != nil, line.text.hasPrefix("↑/↓") {
                continue
            } else {
                // A counter for several questions, or a row Heeler doesn't
                // know.
                return nil
            }
        }
        guard let field else { return nil }
        return AnswerSheet(question: question, description: Array(description), answers: answers, field: field)
    }

    private static func freeTextOption(ordinal: Int, focused: Bool) -> DialogOption {
        DialogOption(
            ordinal: ordinal, number: nil, label: freeTextLabel, shortcut: freeTextKey, role: .otherText,
            isFocused: focused, input: .placeholder(freeTextLabel))
    }

    // MARK: Fork question

    /// `/fork`'s `Run this fork in an isolated git worktree?`, a question
    /// card with no turn waiting on it. `1 Yes` and `2 No` each fork, into
    /// a new worktree or the current directory. `3 Always worktree` and
    /// `4 Never worktree` also save the choice in Grok's config, so they
    /// stay on screen and in the body, never among the options, as a
    /// typed answer stays in the terminal. A narrow card scrolls its later
    /// rows out of view, and one without both Yes and No stays generic,
    /// saying that every answer forks and that rows out of view save a
    /// lasting choice. A key selects its row wherever the cursor is, except
    /// on the answer field, where it is typed, so with the keyboard on the
    /// card the cursor must show (1.0.62, live).
    private static func fork(_ card: GrokCard) -> BlockedDialog? {
        guard let sheet = answerSheet(card), sheet.question == forkQuestion, sheet.description.isEmpty,
            card.cursor != nil || !card.hasKeyboard, sheet.answers.count >= 2, sheet.answers.count <= forkRows.count
        else { return nil }
        var options: [DialogOption] = []
        var withheld: [String] = []
        for (answer, row) in zip(sheet.answers, forkRows) {
            guard answer.key == row.key, answer.label == [row.label] else { return nil }
            if row.offered {
                options.append(answer.option(ordinal: options.count + 1, focused: answer.line == card.cursor))
            } else {
                withheld.append(row.label)
            }
        }
        options.append(freeTextOption(ordinal: options.count + 1, focused: sheet.field == card.cursor))
        let body = [sheet.question] + withheld
        return BlockedDialog(
            kind: .grokFork, title: sheet.question, sourceSuffix: nil, positionLabel: nil, body: body, progress: nil,
            options: options, rows: card.rows,
            fingerprint: DialogFingerprint(
                program: .grok, kind: .grokFork, title: sheet.question, sourceSuffix: nil, body: body, progress: nil,
                options: options),
            focus: card.focus(of: options), subject: DialogSubject())
    }

    private static let forkQuestion = "Run this fork in an isolated git worktree?"
    private static let forkRows: [(key: String, label: String, offered: Bool)] = [
        ("1", "Yes", true), ("2", "No", true), ("3", "Always worktree", false), ("4", "Never worktree", false),
    ]

    private struct Answer {
        var key: String
        var label: [String]
        var detail: [String]
        var line: Int
        var column: Int

        func option(ordinal: Int, focused: Bool) -> DialogOption {
            DialogOption(
                ordinal: ordinal, number: Int(key), label: label.joined(separator: " "),
                detail: detail.isEmpty ? nil : detail.joined(separator: " "), shortcut: key, role: .answer,
                isFocused: focused)
        }
    }

    /// The keys Grok draws on a question's answers, in order
    /// (`question_view.rs` `option_shortcut_label`). It binds only `1` to
    /// `f`.
    private static let answerKeys = Array("123456789abcdefghijklmnopqrstuvwxy").map(String.init)
    private static let freeTextKey = "z"
    private static let freeTextLabel = "Type your answer here"
    private static let waitingLabel = "Waiting on answers for "

    /// The turn's status row above the card: `◆ Waiting on answers for
    /// <question>`, which a narrow row cuts to a prefix and `…`
    /// (`turn_status.rs`). Dock rows and blanks may lie between; the
    /// scrollback, five cells in, ends the search.
    private static func waitsOnAnswers(_ rows: [ScreenRow], above top: Int) -> Bool {
        for index in stride(from: top - 1, through: max(0, top - 12), by: -1) {
            let row = rows[index]
            guard let indent = row.indent else { continue }
            guard indent < 5 else { return false }
            let text = row.trimmedText
            guard text.hasPrefix("◆ ") else { continue }
            let label = String(text.dropFirst(2))
            if label.hasPrefix(waitingLabel) { return true }
            if let cut = label.firstIndex(of: "…") {
                let stem = label[..<cut].trimmingCharacters(in: .whitespaces)
                if stem.count >= "Waiting".count, waitingLabel.hasPrefix(stem) { return true }
            }
        }
        return false
    }

    // MARK: Subagent panel

    /// `Subagents are still running. Stop them?`, the count, then `1 Stop
    /// running`, `2 Continue to run`, and two `Always` rows, which write
    /// config and stay in the terminal. Continuing still ends the turn;
    /// only the subagents go on (`key_owner.rs`).
    private static func cancelPanel(_ card: GrokCard) -> BlockedDialog? {
        guard let top = card.lines.firstIndex(where: { !$0.text.isEmpty }), card.lines[top].option == nil,
            card.lines[top].text.hasPrefix("Subagents are still running"),
            let first = card.lines.firstIndex(where: { $0.option != nil })
        else { return nil }
        // The card's edge can cut the title at a phone's width.
        let shown = card.lines[top].text
        let title = cancelTitle.hasPrefix(shown) ? cancelTitle : shown
        let body = card.lines[(top + 1)..<first].map(\.text).filter { !$0.isEmpty }
        var options: [DialogOption] = []
        for index in first..<card.lines.count {
            let line = card.lines[index]
            guard let option = line.option else {
                guard line.text.isEmpty else { return nil }
                continue
            }
            guard let number = Int(option.key) else { return nil }
            let choice: (label: String, detail: String, role: DialogOptionRole)
            if option.names("Stop running") {
                choice = ("Stop running", "Stops the turn and its subagents", .cancel)
            } else if option.names("Continue to run") {
                choice = ("Continue to run", "Ends the turn; subagents keep running", .answer)
            } else if option.names("Always stop") || option.names("Always continue") {
                continue
            } else {
                return nil
            }
            options.append(
                DialogOption(
                    ordinal: options.count + 1, number: number, label: choice.label, detail: choice.detail,
                    shortcut: option.key, role: choice.role, isFocused: index == card.cursor))
        }
        guard options.map(\.role) == [.cancel, .answer] else { return nil }
        return BlockedDialog(
            kind: .grokCancelTurn, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: nil,
            options: options, rows: card.rows,
            fingerprint: DialogFingerprint(
                program: .grok, kind: .grokCancelTurn, title: title, sourceSuffix: nil, body: body, progress: nil,
                options: options),
            focus: card.focus(of: options), subject: DialogSubject())
    }

    private static let cancelTitle = "Subagents are still running. Stop them?"
}

/// A Grok Build card as `GrokDialogParser` reads it.
private struct GrokCard {
    struct Option {
        let key: String
        /// `(●)`: the cursor on a permission or the subagent panel, a
        /// chosen answer on a question.
        let isMarked: Bool
        let label: String
        /// The text two spaces or more after the label: an answer's
        /// description.
        let detail: String?
        /// The row reaches the card's edge, where Grok cuts what doesn't
        /// fit, a space before it included.
        let isCut: Bool

        /// `known` in full, or its start where the edge cut the label.
        func names(_ known: String) -> Bool {
            label == known || (isCut && label.count >= 8 && known.hasPrefix(label))
        }

        func begins(with stem: String) -> Bool {
            label.hasPrefix(stem) || (isCut && label.count >= 8 && stem.hasPrefix(label))
        }

        /// `known` cut short with `…`.
        func shortens(_ known: String) -> Bool {
            let shown = label.dropLast()
            return label.hasSuffix("…") && shown.count >= 8 && known.hasPrefix(shown)
        }
    }

    struct Line {
        let row: ScreenRow
        /// The text after the bar, the scrollbar dropped, trimmed.
        let text: String
        /// The column `text` starts at.
        let column: Int
        let option: Option?
        /// The cursor's band: where the text starts, the background
        /// differs from the card's, or reverse video is on.
        let hasBand: Bool
        /// The label, or a row's text, is bold.
        let isBold: Bool

        init(_ row: ScreenRow, edge: Int) {
            self.row = row
            let bar = row.indent ?? 0
            let after = row.text(from: bar + 1)
            let leading = after.prefix { ScreenRow.isBlank($0) }
            column = bar + 1 + TerminalCellWidth.width(of: String(leading))
            text = GrokScreen.withoutScrollbar(
                ScreenRow.normalizedSpaces(after).trimmingCharacters(in: .whitespaces))
            var labelColumn = column
            if let match = text.wholeMatch(of: /([0-9a-z]+)\s+\(([●○])\)(?:\s+(.*))?/) {
                let rest = match.3.map(String.init) ?? ""
                let gap = rest.range(of: #"\s{2,}"#, options: .regularExpression)
                let label = gap.map { String(rest[..<$0.lowerBound]) } ?? rest
                let detail = gap.map { rest[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
                let end = column + TerminalCellWidth.width(of: text)
                option = Option(
                    key: String(match.1), isMarked: match.2 == "●", label: label,
                    detail: detail.flatMap { $0.isEmpty ? nil : $0 }, isCut: end >= edge - 1)
                if let start = match.3?.startIndex {
                    labelColumn += TerminalCellWidth.width(of: String(text[..<start]))
                }
            } else {
                option = nil
            }
            let base = row.run(at: bar + 1)?.style
            let start = row.run(at: column)?.style
            if let base, let start, !text.isEmpty {
                hasBand = start.background != base.background || start.isReverse != base.isReverse
            } else {
                hasBand = false
            }
            isBold = row.run(at: labelColumn)?.style.isBold == true
        }
    }

    let rows: Range<Int>
    let lines: [Line]
    /// The footer shows the card's hints, so the card has the keyboard.
    let hasKeyboard: Bool
    /// The line of the cursor's option, while the card has the keyboard.
    let cursor: Int?

    init(rows: Range<Int>, of screen: ANSIScreen, footer: String?) {
        self.rows = rows
        // The card ends two cells short of the screen's edge, and its rows
        // two cells short of that.
        let edge = (rows.map { screen.rows[$0].width }.max() ?? 0) - 4
        let lines = rows.map { Line(screen.rows[$0], edge: edge) }
        self.lines = lines
        hasKeyboard = footer.map(Self.showsCardHints) ?? false
        cursor = hasKeyboard ? Self.cursor(in: lines) : nil
    }

    /// The focus of the card's `options`: the cursor's, which may lie on a
    /// row the card doesn't offer.
    func focus(of options: [DialogOption]) -> DialogFocusState {
        DialogFocusState(focusedOrdinal: options.first(where: \.isFocused)?.ordinal, keysMissOptions: !hasKeyboard)
    }

    /// The banded option; where a hovered row is banded too, the one with
    /// a bold label; with no band, the `(●)` row.
    private static func cursor(in lines: [Line]) -> Int? {
        let options = lines.indices.filter { lines[$0].option != nil }
        let banded = options.filter { lines[$0].hasBand }
        if banded.count > 1 {
            let bold = banded.filter { lines[$0].isBold }
            return bold.count == 1 ? bold.first : nil
        }
        if let line = banded.first { return line }
        let marked = options.filter { lines[$0].option?.isMarked == true }
        return marked.count == 1 ? marked.first : nil
    }

    /// The hints Grok shows while a card has the keyboard: `1/5:select`,
    /// and Tab to the next row (`agent_view/render.rs`).
    private static func showsCardHints(_ footer: String) -> Bool {
        ["Tab:next option", "Tab:next answer", "Tab:next choice"].contains { footer.contains($0) }
            || footer.range(of: #"(?:^|\s)1/\d:select"#, options: .regularExpression) != nil
    }

    /// The card's rows for the generic card: without the bar and the
    /// scrollbar, each indented as on screen. The fingerprint leaves out
    /// the cursor's mark and the key hints, so moving the cursor with the
    /// key pad keeps the card.
    func excerpt(_ reason: String) -> GenericDialogExcerpt {
        let indent = lines.filter { !$0.text.isEmpty }.map(\.column).min() ?? 0
        let display = lines.map { line in
            line.text.isEmpty ? "" : String(repeating: " ", count: max(0, line.column - indent)) + line.text
        }
        let content = lines.map(\.text).filter { !Self.isHint($0) }
            .map { $0.replacingOccurrences(of: "(●)", with: "(○)") }
        return GenericDialogExcerpt(
            rows: lines.map(\.row), numbered: [:], reason: reason,
            fingerprint: DialogFingerprint(program: .grok, excerptRows: content), displayLines: display)
    }

    /// A question's `↑/↓ navigate` row, with its counter for several
    /// questions, and a permission's scope hint.
    private static func isHint(_ text: String) -> Bool {
        text.hasPrefix("↑/↓") || text.hasPrefix("[") || text.hasPrefix("← →") || text.hasPrefix("e edit pattern")
    }
}
