import Foundation

/// Reads Oh My Pi's dialog panels from a visible-screen read.
///
/// OMP draws a dialog as a rounded panel titled in its top border,
/// `╭─ Allow tool: bash ─…╮`, with `├─…┤` rules between its sections and
/// its key hints in the last one. The panel is either the screen's last row
/// (a question without a draft replaces the composer, the plan review fills
/// the screen) or rests directly on the status band, whose `╰─` prompt stays
/// below it (an approval, or a question while the prompt holds a draft).
/// Tool renderings in the history are panels too, but untitled (`╭───╮`) or
/// with a rule before the title (`╭─── Ask 1 questions`), and never touch the
/// band. A tool approval and a single-select question are known dialogs; any
/// other titled panel holds sending as an excerpt for the generic card. OMP
/// binds no digits, so the excerpt offers none.
enum OMPDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        guard let panel = OMPPanel.bottom(of: screen) else { return .none }
        guard let title = panel.title else {
            return unrecognized(panel, on: screen, "The top of Oh My Pi's panel is off screen.")
        }
        if title.hasPrefix(approvalPrefix) {
            return approval(panel, title: title, on: screen)
        }
        if title == "Ask" {
            return ask(panel, on: screen)
        }
        return unrecognized(panel, on: screen, "Heeler does not know Oh My Pi's \u{201C}\(title)\u{201D} panel.")
    }

    private static let approvalPrefix = "Allow tool:"

    /// `Allow tool: <name>`, its details (`Command:`, `Reason:`, `Origin:`
    /// and per-tool rows), then `ctrl+q approve · esc deny · …`. Typing goes
    /// to the prompt below, which turns the footer's tail into `deny and
    /// send`, so the footer stays out of the fingerprint. Before 18.12 plain
    /// Enter does nothing; 18.12 lists the choices under the details, which
    /// arrow keys and Enter answer (see `approvalChoices`).
    private static func approval(_ panel: OMPPanel, title: String, on screen: ANSIScreen) -> DialogParseResult {
        guard panel.sections.count > 1, let footer = panel.sections.last else {
            return unrecognized(panel, on: screen, "The approval's keys are not on screen.")
        }
        let keys = footer.map(\.text).joined(separator: " ")
        guard keys.contains(" approve"), keys.contains(" deny") else {
            return unrecognized(panel, on: screen, "The approval's keys are not on screen.")
        }
        let details = panel.sections.dropLast().flatMap { $0 }
        let choices = approvalChoices(details)
        let body = details.dropLast(choices?.rows ?? 0).map(\.text)
        var subject = DialogSubject()
        subject.toolName = String(title.dropFirst(approvalPrefix.count)).trimmingCharacters(in: .whitespaces)
        subject.command = value(of: "Command:", in: body).map { command in
            // A command too long for its row ends in `…`.
            command.hasSuffix("…") ? String(command.dropLast()).trimmingCharacters(in: .whitespaces) : command
        }
        subject.reason = value(of: "Reason:", in: body)
        // OMP ignores ctrl+q and Enter for 500 ms after drawing the panel;
        // the store waits that out. ctrl+enter reads as Enter without kitty
        // keys. The options follow the list's order, so an ordinal is its
        // row; a draft hides the list's focus behind its Deny row.
        let isGuarded = keys.contains("deny and send")
        let focused = isGuarded ? nil : choices?.focused
        var options = [
            DialogOption(
                ordinal: 1, number: nil, label: "Approve", shortcut: "ctrl+q", role: .approve, isFocused: focused == 1)
        ]
        if let session = choices?.sessionLabel {
            options.append(
                DialogOption(
                    ordinal: 2, number: nil, label: session, role: .approvePersistent, isFocused: focused == 2))
        }
        options.append(
            DialogOption(
                ordinal: options.count + 1, number: nil, label: "Deny", shortcut: "esc", role: .decline,
                isFocused: focused == options.count + 1))
        return .dialog(
            BlockedDialog(
                kind: .ompApproval, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: nil,
                options: options, rows: panel.rows,
                fingerprint: DialogFingerprint(
                    program: .omp, kind: .ompApproval, title: title, sourceSuffix: nil, body: body, progress: nil,
                    options: options),
                focus: DialogFocusState(focusedOrdinal: focused, composerDraftGuard: isGuarded), subject: subject))
    }

    /// Oh My Pi 18.12's choices, the details' last rows: `Approve`, then
    /// `Approve <subject> for this session` when the approval policy offers
    /// it, then `Deny`, which reads `Deny and send message` while the prompt
    /// holds a draft. The pointer leads the focused row, the others are
    /// indented to its label, and ↑/↓ wrap around. While a draft is typed
    /// the pointer stays on Deny and arrow keys edit the draft.
    private static func approvalChoices(_ lines: [OMPPanel.Line]) -> ApprovalChoices? {
        for count in [3, 2] where lines.count >= count {
            let rows = Array(lines.suffix(count))
            let read = rows.compactMap { pointed($0.text) }
            guard read.count == count, let focused = read.firstIndex(where: \.isFocused),
                read.filter(\.isFocused).count == 1,
                rows.indices.allSatisfy({ $0 == focused || rows[$0].indent == rows[focused].indent + 2 }),
                read.first?.rest == "Approve", let deny = read.last?.rest, deny == "Deny" || deny == denyAndSend
            else { continue }
            guard count == 3 else { return ApprovalChoices(rows: 2, sessionLabel: nil, focused: focused + 1) }
            let session = read[1].rest
            guard session.hasPrefix("Approve "), session.hasSuffix(" for this session") else { continue }
            return ApprovalChoices(rows: 3, sessionLabel: session, focused: focused + 1)
        }
        return nil
    }

    private struct ApprovalChoices {
        /// How many of the details' last rows the list takes.
        let rows: Int
        /// The session row's label as printed.
        let sessionLabel: String?
        /// The pointer's row, 1-based.
        let focused: Int
    }

    private static let denyAndSend = "Deny and send message"

    /// `Ask`, one page per question. Several questions add a tab row above
    /// the question (`fruit    size    Submit`, the active tab bold on a
    /// fill). Below a rule, one row per option, `<pointer> <radio> label`,
    /// the pointer on the focused one and the typed `Other` last; then the
    /// key hints. Digits do nothing; arrows move and Enter answers, turning
    /// to the next tab. The Submit tab reviews the answers above a lone
    /// `Submit`. While the prompt below holds a draft, the hints ask to
    /// finish it first and keys go to the draft.
    ///
    /// Only the radio glyph seen live is read. Any other row, such as a
    /// multi-select question's or an option's description, leaves the
    /// question to the terminal.
    private static func ask(_ panel: OMPPanel, on screen: ANSIScreen) -> DialogParseResult {
        let layout = "Heeler doesn't know this question's layout. Answer it with these keys or in the terminal."
        guard panel.sections.count == 3, let footer = panel.sections[2].first?.text else {
            return unrecognized(panel, on: screen, layout)
        }
        var header = panel.sections[0]
        var tabs: [String] = []
        var activeTab: String?
        if let first = header.first, first.indent >= 2 {
            tabs = first.text.replacingOccurrences(of: #"\s{2,}"#, with: "\u{1F}", options: .regularExpression)
                .split(separator: "\u{1F}").map(String.init)
            activeTab = first.row.runs.first { $0.style.isBold && $0.style.background != nil }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
            guard let activeTab, tabs.contains(activeTab) else { return unrecognized(panel, on: screen, layout) }
            header.removeFirst()
        }
        let question = header.map(\.text).joined(separator: " ")
        guard !question.isEmpty else { return unrecognized(panel, on: screen, layout) }
        let isGuarded = footer.hasPrefix(draftGuardFooter)
        let headers = tabs.last == submitTab ? Array(tabs.dropLast()) : tabs
        if activeTab == submitTab, question == reviewTitle {
            guard isGuarded || footer.contains("submit") else { return unrecognized(panel, on: screen, layout) }
            return review(panel, headers: headers, isGuarded: isGuarded)
                ?? unrecognized(panel, on: screen, layout)
        }
        // Rows come first: a multi-select page's footer reads `toggle ·
        // submit`, never `select`, and is still a question Heeler leaves
        // to the terminal.
        var options: [DialogOption] = []
        for line in panel.sections[1] {
            guard let (label, isFocused) = choice(line.text) else {
                return unrecognized(
                    panel, on: screen,
                    "Heeler answers only Oh My Pi's single-select questions. Answer this one in the terminal.")
            }
            options.append(
                DialogOption(
                    ordinal: options.count + 1, number: nil, label: label,
                    role: label == otherLabel ? .otherText : .answer, isFocused: isFocused))
        }
        guard isGuarded || footer.contains("select"), options.contains(where: { $0.role == .answer }) else {
            return unrecognized(panel, on: screen, layout)
        }
        let focused = options.filter(\.isFocused)
        var subject = DialogSubject()
        subject.question = question
        subject.questionHeaders = headers
        return .dialog(
            BlockedDialog(
                kind: .ompQuestion, title: question, sourceSuffix: nil, positionLabel: nil, body: [question],
                progress: activeTab, options: options, rows: panel.rows,
                fingerprint: DialogFingerprint(
                    program: .omp, kind: .ompQuestion, title: question, sourceSuffix: nil, body: [question],
                    progress: activeTab, options: options),
                focus: DialogFocusState(
                    focusedOrdinal: focused.count == 1 ? focused.first?.ordinal : nil, composerDraftGuard: isGuarded),
                subject: subject))
    }

    /// `Review answers`: `1. fruit: apple` per question, then `Submit`.
    private static func review(_ panel: OMPPanel, headers: [String], isGuarded: Bool) -> DialogParseResult? {
        var answers: [DialogSubject.ReviewAnswer] = []
        var body: [String] = []
        var submit: DialogOption?
        for line in panel.sections[1] {
            guard submit == nil else { return nil }
            if let (label, isFocused) = pointed(line.text), label == submitTab {
                submit = DialogOption(ordinal: 1, number: nil, label: label, role: .submit, isFocused: isFocused)
            } else if line.text.range(of: #"^\d+\. "#, options: .regularExpression) != nil,
                let colon = line.text.range(of: ": ")
            {
                let name = line.text[..<colon.lowerBound].drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                answers.append(
                    DialogSubject.ReviewAnswer(
                        question: name, answer: String(line.text[colon.upperBound...])))
                body.append(line.text)
            } else {
                return nil
            }
        }
        guard let submit, !answers.isEmpty, answers.count == headers.count else { return nil }
        var subject = DialogSubject()
        subject.questionHeaders = headers
        subject.reviewAnswers = answers
        return .dialog(
            BlockedDialog(
                kind: .ompQuestionReview, title: reviewTitle, sourceSuffix: nil, positionLabel: nil, body: body,
                progress: reviewTitle, options: [submit], rows: panel.rows,
                fingerprint: DialogFingerprint(
                    program: .omp, kind: .ompQuestionReview, title: reviewTitle, sourceSuffix: nil, body: body,
                    progress: reviewTitle, options: [submit]),
                focus: DialogFocusState(
                    focusedOrdinal: submit.isFocused ? submit.ordinal : nil, composerDraftGuard: isGuarded),
                subject: subject))
    }

    /// `<pointer> <radio> label`, or the radio alone off focus.
    private static func choice(_ text: String) -> (label: String, isFocused: Bool)? {
        guard let (rest, isFocused) = pointed(text), rest.first == radio else { return nil }
        let label = rest.dropFirst()
        guard let space = label.first, ScreenRow.isBlank(space) else { return nil }
        var trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(recommendedSuffix) { trimmed = String(trimmed.dropLast(recommendedSuffix.count)) }
        return trimmed.isEmpty ? nil : (trimmed, isFocused)
    }

    /// The row without its focus pointer, and whether it had one.
    private static func pointed(_ text: String) -> (rest: String, isFocused: Bool)? {
        guard let first = text.first else { return nil }
        guard pointers.contains(first) else { return (text, false) }
        let rest = text.dropFirst()
        guard let space = rest.first, ScreenRow.isBlank(space) else { return nil }
        return (rest.trimmingCharacters(in: .whitespaces), true)
    }

    private static let pointers: Set<Character> = ["\u{F054}", "❯", ">"]
    /// The unchecked radio of OMP's nerd-font symbols.
    private static let radio: Character = "\u{F10C}"
    private static let otherLabel = "Other (type your own)"
    private static let recommendedSuffix = " (Recommended)"
    private static let submitTab = "Submit"
    private static let reviewTitle = "Review answers"
    private static let draftGuardFooter = "Finish or clear the current prompt to answer"

    private static func value(of label: String, in body: [String]) -> String? {
        body.first { $0.hasPrefix(label) }.map {
            String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The panel's rows verbatim. The fingerprint leaves out the key hints,
    /// which change with the prompt's draft, and the focus pointer.
    private static func unrecognized(_ panel: OMPPanel, on screen: ANSIScreen, _ reason: String) -> DialogParseResult {
        let sections = panel.sections.count > 1 ? Array(panel.sections.dropLast()) : panel.sections
        let content = sections.flatMap { $0 }.map(\.text)
        let unpointed = content.map { row in
            String(row.drop { $0 == "\u{F054}" || $0 == "❯" || ScreenRow.isBlank($0) })
        }
        return .unrecognized(
            GenericDialogExcerpt(
                rows: Array(screen.rows[panel.rows]), numbered: [:], reason: reason,
                fingerprint: DialogFingerprint(program: .omp, excerptRows: [panel.title ?? ""] + unpointed),
                displayLines: displayLines(of: panel)))
    }

    /// The panel as the card shows it: the title, then each section's rows
    /// between the side borders, a rule between sections. Rows keep their
    /// indent inside the panel, so options line up under the pointer.
    private static func displayLines(of panel: OMPPanel) -> [String] {
        var lines = panel.title.map { [displayText($0)] } ?? []
        var hasSection = false
        for section in panel.sections where !section.isEmpty {
            if hasSection { lines.append(GenericDialogExcerpt.ruleLine) }
            lines += section.map { String(repeating: " ", count: max(0, $0.indent - 1)) + displayText($0.text) }
            hasSection = true
        }
        return lines
    }

    /// `text` with OMP's nerd-font symbols as the system font draws them:
    /// the pointer, check boxes and radios mapped, any other Private Use
    /// Area glyph, such as a key icon in the hints, dropped with its space.
    private static func displayText(_ text: String) -> String {
        var result = ""
        var skipsBlank = false
        for character in text {
            if skipsBlank, ScreenRow.isBlank(character) {
                skipsBlank = false
                continue
            }
            skipsBlank = false
            if let mapped = displayGlyphs[character] {
                result.append(mapped)
            } else if character.unicodeScalars.contains(where: isPrivateUse) {
                skipsBlank = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// From OMP's nerd-font symbol table, with the Unicode symbols of its
    /// plain table.
    private static let displayGlyphs: [Character: Character] = [
        "\u{F054}": "❯", "\u{F096}": "☐", "\u{F14A}": "☑", radio: "○", "\u{F192}": "◉",
    ]

    /// The Private Use Areas, where nerd fonts put their icons.
    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || scalar.value >= 0xF0000
    }
}

/// An OMP panel as `OMPDialogParser` finds it.
private struct OMPPanel {
    /// The zero-based screen rows from the top border, or the screen's top
    /// when the border is off screen, through the bottom border.
    let rows: Range<Int>
    /// The title from the top border, without a countdown such as `(30s)`;
    /// nil when the top border is off screen.
    let title: String?
    /// The rows between the side borders, blank ones dropped, split at each
    /// `├─…┤` rule.
    let sections: [[Line]]

    struct Line {
        /// The text between the side borders, trimmed.
        let text: String
        /// Blank cells between the left border and the text.
        let indent: Int
        let row: ScreenRow
    }

    /// The lowest panel, when it ends the screen or rests on the status
    /// band. An untitled panel is a tool's rendering, not a dialog.
    static func bottom(of screen: ANSIScreen) -> OMPPanel? {
        let rows = screen.rows
        guard let last = rows.lastIndex(where: { !$0.isBlank }) else { return nil }
        let bottom: Int
        if isBottomBorder(rows[last]) {
            bottom = last
        } else if let prompt = rows.indices.last(where: { PiInputBoxDetector.isOMPPrompt(rows[$0]) }), prompt >= 2,
            PiInputBoxDetector.isOMPStatusBand(rows[prompt - 1]), isBottomBorder(rows[prompt - 2])
        {
            bottom = prompt - 2
        } else {
            return nil
        }
        var sections: [[Line]] = [[]]
        var index = bottom - 1
        while index >= 0 {
            let text = rows[index].trimmedText
            if text.hasPrefix("╭"), text.hasSuffix("╮") { break }
            if text.hasPrefix("├"), text.hasSuffix("┤") {
                sections.insert([], at: 0)
            } else if text.hasPrefix("│"), text.hasSuffix("│"), text.count >= 2 {
                let inner = text.dropFirst().dropLast()
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let indent = inner.prefix { ScreenRow.isBlank($0) }.count
                    sections[0].insert(Line(text: trimmed, indent: indent, row: rows[index]), at: 0)
                }
            } else {
                return nil
            }
            index -= 1
        }
        guard index >= 0 else { return OMPPanel(rows: 0..<(bottom + 1), title: nil, sections: sections) }
        guard let title = title(of: rows[index].trimmedText) else { return nil }
        return OMPPanel(rows: index..<(bottom + 1), title: title, sections: sections)
    }

    private static func isBottomBorder(_ row: ScreenRow) -> Bool {
        let text = row.trimmedText
        return text.hasPrefix("╰") && text.hasSuffix("╯")
    }

    /// `╭─ Title ─…╮`: exactly one rule cell, a space, then the title.
    private static func title(of border: String) -> String? {
        guard border.hasPrefix("╭─ ") else { return nil }
        let rest = border.dropFirst(3)
        guard let first = rest.first, first != "─", !ScreenRow.isBlank(first) else { return nil }
        let end = rest.range(of: " ─")?.lowerBound ?? rest.index(before: rest.endIndex)
        let title = rest[..<end].replacingOccurrences(
            of: #"\s*\(\d+s\)$"#, with: "", options: .regularExpression)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
