import Foundation

/// Reads Claude Code's permission, plan, question and folder-trust dialogs
/// from a visible-screen read.
///
/// Claude draws a dialog in place of its input box: a rule, a bold title,
/// the request, numbered options and a footer of key hints. Colors carry
/// the roles that matter: option numbers, descriptions and hints in an
/// inactive color, the pointer and focused label in an accent color. Both
/// are taken from the screen rather than assumed, since themes change them.
/// Anything that does not fit a known dialog comes back as an excerpt for
/// the generic card, never as a guess.
enum ClaudeDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        if ClaudeInputBox.locate(in: screen) != nil { return .none }
        if let trust = ClaudeTrustDialogReader.read(screen) { return trust }
        guard let block = ClaudeOptionBlock(screen: screen) else {
            return ClaudeLooseDialogReader.read(screen)
        }
        return ClaudeDialogReader(screen: screen, block: block).read()
    }
}

/// Claude's prompt: one or more input rows between two full-width rules,
/// the first starting with `❯` (or `!` in shell mode) and a blank at column
/// 0, on no background. Past prompts in the history carry a background.
struct ClaudeInputBox: Sendable, Hashable {
    let topRule: Int
    let inputRows: Range<Int>
    let bottomRule: Int
    let glyph: Character

    static func locate(in screen: ANSIScreen) -> ClaudeInputBox? {
        let rows = screen.rows
        let minimumWidth = max(8, screen.columns - 4)
        for bottom in rows.indices.reversed() where isBoxRule(rows[bottom], minimumWidth: minimumWidth) {
            var row = bottom - 1
            while row > 0, bottom - row <= 30 {
                if isBoxRule(rows[row], minimumWidth: minimumWidth) { break }
                if let glyph = promptGlyph(rows[row]), isBoxRule(rows[row - 1], minimumWidth: minimumWidth) {
                    return ClaudeInputBox(topRule: row - 1, inputRows: row..<bottom, bottomRule: bottom, glyph: glyph)
                }
                row -= 1
            }
        }
        return nil
    }

    /// A full-width `─` rule from column 0. The top rule may carry the
    /// session's name (`──── create-and-verify-probe-file ─`).
    static func isBoxRule(_ row: ScreenRow, minimumWidth: Int) -> Bool {
        guard row.indent == 0, row.contentWidth >= minimumWidth else { return false }
        let text = row.trimmedText
        guard text.hasPrefix("─"), text.hasSuffix("─") else { return false }
        let label = text.drop { $0 == "─" }.reversed().drop { $0 == "─" }
        return label.isEmpty || (label.first == " " && label.last == " ")
    }

    private static func promptGlyph(_ row: ScreenRow) -> Character? {
        let characters = Array(row.text.prefix(2))
        guard characters.count == 2, characters[0] == "❯" || characters[0] == "!",
            ScreenRow.isBlank(characters[1]), row.runs.first?.style.background == nil,
            DialogRowScanner.numberedOption(in: row, pointer: "❯") == nil
        else { return nil }
        return characters[0]
    }
}

/// The numbered options nearest the bottom of the screen: rows 1…N whose
/// numbers share one color, with no blank row between them. Numbers in a
/// plan or a reply carry no color, so they never join the block.
private struct ClaudeOptionBlock {
    let rows: [NumberedOptionRow]
    /// The color of option numbers, descriptions and hints.
    let inactive: ScreenColor
    /// The color of the pointer and the focused label.
    let accent: ScreenColor?

    init?(screen: ANSIScreen) {
        let numbered = screen.rows.compactMap { DialogRowScanner.numberedOption(in: $0, pointer: "❯") }
            .filter { $0.numberStyle.foreground != nil }
        guard let last = numbered.last, let color = last.numberStyle.foreground else { return nil }
        var block = [last]
        for candidate in numbered.dropLast().reversed() {
            guard let first = block.first, first.number > 1, candidate.number == first.number - 1,
                candidate.numberStyle.foreground == color,
                !screen.rows[(candidate.rowIndex + 1)..<first.rowIndex].contains(where: \.isBlank)
            else { break }
            block.insert(candidate, at: 0)
        }
        rows = block
        inactive = color
        accent = block.lazy.compactMap { option -> ScreenColor? in
            guard let column = option.pointerColumn else { return nil }
            return screen.rows[option.rowIndex].run(at: column)?.style.foreground
        }.first
    }
}

/// What a row's runs say once split into the parts an option row has.
private struct OptionRowReading {
    var label = ""
    /// The label is drawn in the inactive color: an empty text field's
    /// placeholder.
    var labelIsInactive = false
    var detail: String?
    /// A text field with the cursor in it.
    var field: FieldText?
    /// `No` in `No, and tell Claude…`: the row Tab turned into a note field.
    var feedbackLabel: String?
    var droppedResidue = false
    /// The label ended in ` ✔`: the answer chosen earlier.
    var isMarkedChosen = false
}

/// The content of a text field as drawn.
enum FieldText: Sendable, Hashable {
    case placeholder(String)
    case typed(String)

    var inputRowState: InputRowState {
        switch self {
        case .placeholder(let text): .placeholder(text)
        case .typed(let text): .text(text)
        }
    }

    /// Reads a field whose runs include the reverse-video cursor cell. An
    /// empty field shows its placeholder as the cursor cell followed by dim
    /// text (`{rev}T{dim}ype something.`); typed text sits around the
    /// cursor, which follows it as a blank cell when it is at the end.
    static func read(_ runs: [ScreenRun]) -> FieldText {
        guard let cursor = runs.firstIndex(where: \.style.isReverse) else {
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let visible = runs.filter { !DialogRowScanner.isBlank($0) }
            if !visible.isEmpty, visible.allSatisfy(\.style.isDim) { return .placeholder(text) }
            return .typed(text)
        }
        let before = runs[..<cursor].map(\.text).joined()
        let after = runs[(cursor + 1)...]
        let afterVisible = after.filter { !DialogRowScanner.isBlank($0) }
        let cursorText = runs[cursor].text
        if before.trimmingCharacters(in: .whitespaces).isEmpty {
            if afterVisible.isEmpty, cursorText.allSatisfy(ScreenRow.isBlank) { return .placeholder("") }
            if !afterVisible.isEmpty, afterVisible.allSatisfy(\.style.isDim) {
                let text = cursorText + after.map(\.text).joined()
                return .placeholder(ScreenRow.normalizedSpaces(text).trimmingCharacters(in: .whitespaces))
            }
        }
        let text = before + cursorText + after.map(\.text).joined()
        return .typed(ScreenRow.normalizedSpaces(text).trimmingCharacters(in: .whitespaces))
    }
}

/// An option while its rows are being read.
private struct OptionDraft {
    var number: Int?
    var rowIndex: Int
    var labelColumn: Int
    var isFocused: Bool
    var isChecked: Bool?
    var label: String
    var labelIsInactive: Bool
    var detail: String?
    var field: FieldText?
    var isFeedback = false
    var droppedResidue = false
    var isButton = false
    var isChat = false
    /// The last row that added to the label or field, for join decisions.
    var lastRow: ScreenRow
    /// A row the reader could not place, such as label text after an
    /// inline description.
    var hasStrayRow = false
}

/// The footer's key hints, `<key> to <action>` joined with ` · `.
private struct ClaudeFooter {
    let rows: [ScreenRow]
    let hints: [(key: String, action: String)]
    /// Parts that are not hints, such as the plan file's path.
    let extras: [String]

    init(rows: [ScreenRow]) {
        self.rows = rows
        let text = rows.map(\.trimmedText).joined(separator: " ")
        var hints: [(key: String, action: String)] = []
        var extras: [String] = []
        for part in text.components(separatedBy: " · ") {
            let part = part.trimmingCharacters(in: .whitespaces)
            if let range = part.range(of: " to ") {
                hints.append((String(part[..<range.lowerBound]), String(part[range.upperBound...])))
            } else if !part.isEmpty {
                extras.append(part)
            }
        }
        self.hints = hints
        self.extras = extras
    }

    /// A hint that binds an action the planner relies on to a key other
    /// than Claude's default: the user remapped it, so the planned keys
    /// would not do what the card says.
    var rebinding: String? {
        for hint in hints {
            let key = hint.key.lowercased()
            let rebound =
                switch hint.action.lowercased() {
                case "cancel": key != "esc"
                case "amend": key != "tab"
                case "select", "confirm": key != "enter"
                case "navigate": !(key.contains("↑") || key.contains("arrow"))
                default: false
                }
            if rebound { return "\(hint.key) to \(hint.action)" }
        }
        return nil
    }
}

/// The tab bar over a question (`←  ☐ Colors  ☐ Size  ✔ Submit  →`) or the
/// header chip over a single one (` ☐ 选择`).
private struct QuestionTabs {
    /// Question headers in order, without the Submit tab.
    var headers: [String] = []
    /// The highlighted tab's label.
    var active: String?

    init?(row: ScreenRow) {
        let glyphs: Set<Character> = ["☐", "☒", "✔"]
        guard row.text.contains(where: glyphs.contains) else { return nil }
        var tabs: [(label: String, glyph: Character, isActive: Bool)] = []
        for run in row.runs {
            let highlighted = run.style.background != nil || run.style.isReverse
            for character in run.text {
                if glyphs.contains(character) {
                    tabs.append(("", character, highlighted))
                } else if character == "←" || character == "→" {
                    continue
                } else if let last = tabs.indices.last {
                    tabs[last].label.append(character)
                    if highlighted, !ScreenRow.isBlank(character) { tabs[last].isActive = true }
                }
            }
        }
        let cleaned = tabs.map { (label: $0.label.trimmingCharacters(in: .whitespaces), glyph: $0.glyph, isActive: $0.isActive) }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.label.isEmpty }) else { return nil }
        headers = cleaned.filter { !($0.glyph == "✔" && $0.label == "Submit") }.map(\.label)
        active = cleaned.first(where: \.isActive)?.label ?? (cleaned.count == 1 ? cleaned.first?.label : nil)
    }
}

private struct ClaudeDialogReader {
    let screen: ANSIScreen
    let block: ClaudeOptionBlock

    private var rows: [ScreenRow] { screen.rows }
    private var columns: Int { screen.columns }
    private var fullWidth: Int { max(8, columns - 4) }

    /// Dialogs whose title Heeler knows, keyed by the bold title.
    private static let permissionTitles: [String: BlockedDialogKind] = [
        "Bash command": .claudeBash, "Edit file": .claudeFileEdit, "Create file": .claudeFileCreate,
        "Fetch": .claudeFetch,
    ]
    private static let planQuestionPrefix = "Claude has written up a plan"
    private static let reviewTitle = "Review your answers"

    func read() -> DialogParseResult {
        guard let firstOption = block.rows.first else { return .none }
        let firstRow = firstOption.rowIndex
        guard firstOption.number == 1 else {
            return unrecognized(from: nil, "The options do not start at 1, so the list may be scrolled.")
        }
        guard let top = topRule(above: firstRow) else {
            return unrecognized(from: nil, "The top of the dialog is off screen.")
        }
        guard let headerRow = (top + 1..<firstRow).first(where: { !rows[$0].isBlank }) else {
            return unrecognized(from: top, "The dialog has no title.")
        }
        let header = rows[headerRow]
        if let tabs = QuestionTabs(row: header) {
            return readQuestion(top: top, tabsRow: headerRow, tabs: tabs, firstOption: firstRow)
        }
        if header.trimmedText.hasPrefix(Self.planQuestionPrefix) {
            return readPlan(lowerRule: top, questionRow: headerRow, firstOption: firstRow)
        }
        let title = Self.title(of: header)
        guard let kind = Self.permissionTitles[title.text] else {
            return unrecognized(from: top, "Heeler does not know the dialog \u{201C}\(title.text)\u{201D}.")
        }
        return readPermission(
            kind: kind, top: top, titleRow: headerRow, title: title, firstOption: firstRow)
    }

    // MARK: Kinds

    private func readPermission(
        kind: BlockedDialogKind, top: Int, titleRow: Int, title: (text: String, suffix: String?, position: String?),
        firstOption: Int
    ) -> DialogParseResult {
        guard let scan = scanOptions(from: firstOption, isQuestionPage: false) else {
            return unrecognized(from: top, "The rows after the options are not a footer.")
        }
        if let problem = scan.problem { return unrecognized(from: top, problem, scan: scan) }
        var options: [DialogOption] = []
        for (index, draft) in scan.drafts.enumerated() {
            let (label, shortcut) = DialogRowScanner.splitShortcut(draft.label)
            guard !draft.labelIsInactive, let role = DialogRowScanner.permissionRole(for: label, shortcut: shortcut)
            else {
                return unrecognized(
                    from: top, "Option \(draft.number ?? index + 1) reads \u{201C}\(label)\u{201D}, which is not a label Heeler knows.",
                    scan: scan)
            }
            if draft.field != nil, !draft.isFeedback {
                return unrecognized(from: top, "Option \(index + 1) is a text field Heeler does not expect here.", scan: scan)
            }
            options.append(
                DialogOption(
                    ordinal: index + 1, number: draft.number, label: label, detail: draft.detail, shortcut: shortcut,
                    role: role, isFocused: draft.isFocused, input: draft.field?.inputRowState))
        }
        guard options.contains(where: { $0.role == .decline }), options.contains(where: { $0.role != .decline })
        else { return unrecognized(from: top, "The dialog lacks a Yes or a No option.", scan: scan) }

        let sections = bodySections(from: titleRow + 1, to: firstOption)
        var subject = DialogSubject()
        var body: [String] = []
        let description = sections.before.joined(separator: " ")
        if !description.isEmpty { body.append(description) }
        switch kind {
        case .claudeBash:
            let command = joinRows(sections.content)
            subject.command = command.isEmpty ? nil : command
            subject.commandDescription = description.isEmpty ? nil : description
            if !command.isEmpty { body.append(command) }
        case .claudeFetch:
            subject.host = description.components(separatedBy: " from ").last.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for entry in labeledEntries(sections.content, labels: ["url:", "prompt:"]) {
                body.append(entry)
                if entry.hasPrefix("url:") {
                    subject.url = entry.dropFirst(4).trimmingCharacters(in: .whitespaces)
                } else if entry.hasPrefix("prompt:") {
                    subject.prompt = entry.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
            }
        default:
            subject.filePath = description.isEmpty ? nil : description
            body.append(contentsOf: sections.content.map(\.trimmedText).filter { !$0.isEmpty })
        }
        body.append(contentsOf: sections.after)
        return dialog(
            kind: kind, title: title.text, sourceSuffix: title.suffix, positionLabel: title.position, body: body,
            progress: nil, options: options, top: top, scan: scan, subject: subject)
    }

    private func readPlan(lowerRule: Int, questionRow: Int, firstOption: Int) -> DialogParseResult {
        guard let scan = scanOptions(from: firstOption, isQuestionPage: false) else {
            return unrecognized(from: lowerRule, "The rows after the options are not a footer.")
        }
        if let problem = scan.problem { return unrecognized(from: lowerRule, problem, scan: scan) }
        var options: [DialogOption] = []
        for (index, draft) in scan.drafts.enumerated() {
            let isLast = index == scan.drafts.count - 1
            if isLast {
                // The last row is the "keep planning" field: its placeholder
                // until the user types into it.
                let field = draft.field ?? (draft.labelIsInactive ? .placeholder(draft.label) : .typed(draft.label))
                let label =
                    if case .placeholder(let text) = field, !text.isEmpty { text } else { "Tell Claude what to change" }
                options.append(
                    DialogOption(
                        ordinal: index + 1, number: draft.number, label: label, detail: draft.detail, role: .otherText,
                        isFocused: draft.isFocused, input: field.inputRowState))
                continue
            }
            let (label, shortcut) = DialogRowScanner.splitShortcut(draft.label)
            guard draft.field == nil, !draft.labelIsInactive,
                let role = DialogRowScanner.permissionRole(for: label, shortcut: shortcut)
            else {
                return unrecognized(
                    from: lowerRule,
                    "Option \(draft.number ?? index + 1) reads \u{201C}\(label)\u{201D}, which is not a label Heeler knows.",
                    scan: scan)
            }
            options.append(
                DialogOption(
                    ordinal: index + 1, number: draft.number, label: label, detail: draft.detail, shortcut: shortcut,
                    role: role, isFocused: draft.isFocused))
        }
        guard options.count >= 2 else { return unrecognized(from: lowerRule, "The plan dialog has too few options.", scan: scan) }

        let question = paragraphs(in: questionRow..<firstOption).joined(separator: " ")
        let upper = planUpperBox(above: lowerRule)
        var subject = DialogSubject()
        subject.planFilePath = scan.footer?.extras.last { $0.contains("/") }
        let body = upper.planRows + (question.isEmpty ? [] : [question])
        return dialog(
            kind: .claudePlan, title: upper.title ?? question, sourceSuffix: nil, positionLabel: nil, body: body,
            progress: nil, options: options, top: upper.top ?? lowerRule, scan: scan, subject: subject)
    }

    private func readQuestion(top: Int, tabsRow: Int, tabs: QuestionTabs, firstOption: Int) -> DialogParseResult {
        let titleRows = (tabsRow + 1..<firstOption).drop { rows[$0].isBlank }.prefix { !rows[$0].isBlank }
        let title = joinRows(titleRows.map { rows[$0] })
        let isReview = title == Self.reviewTitle || tabs.active == "Submit"
        guard let scan = scanOptions(from: firstOption, isQuestionPage: !isReview) else {
            return unrecognized(from: top, "The rows after the options are not a footer.")
        }
        if let problem = scan.problem { return unrecognized(from: top, problem, scan: scan) }
        if let footer = scan.footer, footer.hints.contains(where: { $0.key == "n" && $0.action.hasPrefix("add notes") }) {
            // The preview layout: digits only move focus there.
            return unrecognized(from: top, "Heeler does not handle questions with previews yet.", scan: scan)
        }
        var subject = DialogSubject()
        subject.questionHeaders = tabs.headers

        if isReview {
            var options: [DialogOption] = []
            for (index, draft) in scan.drafts.enumerated() {
                let role: DialogOptionRole? =
                    switch draft.label {
                    case "Submit answers": .submit
                    case "Cancel": .cancel
                    default: nil
                    }
                guard let role, draft.field == nil else {
                    return unrecognized(
                        from: top, "The review page offers \u{201C}\(draft.label)\u{201D}, which Heeler does not know.",
                        scan: scan)
                }
                options.append(
                    DialogOption(
                        ordinal: index + 1, number: draft.number, label: draft.label, role: role,
                        isFocused: draft.isFocused))
            }
            let bodyRows = (titleRows.last.map { $0 + 1 } ?? tabsRow + 1)..<firstOption
            let body = bodyRows.map { rows[$0].trimmedText }.filter { !$0.isEmpty }
            subject.reviewAnswers = reviewAnswers(in: bodyRows)
            return dialog(
                kind: .claudeQuestionReview, title: Self.reviewTitle, sourceSuffix: nil, positionLabel: nil, body: body,
                progress: Self.reviewTitle, options: options, top: top, scan: scan, subject: subject)
        }

        guard !title.isEmpty else { return unrecognized(from: top, "The question's text is not on screen.", scan: scan) }
        // The last numbered option before the rule is "Type something":
        // its placeholder until the user types into it.
        let numberedBeforeRule = scan.drafts.filter { $0.number != nil && !$0.isChat }
        let otherIndex = scan.drafts.lastIndex { $0.number != nil && !$0.isChat }
        let isMultiSelect = numberedBeforeRule.contains { $0.isChecked != nil } && scan.drafts.contains(where: \.isButton)
        var options: [DialogOption] = []
        for (index, draft) in scan.drafts.enumerated() {
            let ordinal = index + 1
            if index == otherIndex {
                let field = draft.field ?? (draft.labelIsInactive ? .placeholder(draft.label) : .typed(draft.label))
                let label =
                    if case .placeholder(let text) = field, !text.isEmpty {
                        text
                    } else {
                        isMultiSelect ? "Type something" : "Type something."
                    }
                options.append(
                    DialogOption(
                        ordinal: ordinal, number: draft.number, label: label, detail: draft.detail, role: .otherText,
                        isFocused: draft.isFocused, isChecked: isMultiSelect ? (draft.isChecked ?? false) : draft.isChecked,
                        input: field.inputRowState))
                continue
            }
            if draft.field != nil || draft.droppedResidue && draft.label.isEmpty {
                return unrecognized(from: top, "Option \(ordinal) could not be read.", scan: scan)
            }
            let role: DialogOptionRole = draft.isButton ? .next : draft.isChat ? .chat : .answer
            options.append(
                DialogOption(
                    ordinal: ordinal, number: draft.number, label: draft.label, detail: draft.detail, role: role,
                    isFocused: draft.isFocused,
                    isChecked: role == .answer ? (isMultiSelect ? (draft.isChecked ?? false) : draft.isChecked) : nil))
        }
        guard options.contains(where: { $0.role == .answer }) else {
            return unrecognized(from: top, "The question has no answers Heeler can read.", scan: scan)
        }
        subject.question = title
        return dialog(
            kind: .claudeQuestion, title: title, sourceSuffix: nil, positionLabel: nil, body: [],
            progress: tabs.active, options: options, top: top, scan: scan, subject: subject)
    }

    // MARK: Options

    private struct OptionScan {
        var drafts: [OptionDraft]
        /// The first row after the options.
        var end: Int
        var footer: ClaudeFooter?
        var problem: String?

        /// The last row the dialog covers.
        var lastRow: Int { footer?.rows.last?.index ?? end - 1 }
    }

    /// Reads the options from the first numbered row down, then the footer.
    /// Nil when rows after the options do not look like a footer, which
    /// means the block is not a live dialog.
    private func scanOptions(from first: Int, isQuestionPage: Bool) -> OptionScan? {
        var drafts: [OptionDraft] = []
        var numbered = block.rows[...]
        var sawInnerRule = false
        var row = first
        while row < rows.count {
            let current = rows[row]
            if let next = numbered.first, next.rowIndex == row {
                drafts.append(readNumbered(next, isQuestionPage: isQuestionPage, isChat: false))
                numbered = numbered.dropFirst()
            } else if current.isBlank {
                break
            } else if isQuestionPage, !sawInnerRule, let button = buttonRow(current) {
                drafts.append(button)
            } else if isQuestionPage, DialogRowScanner.isRule(current, of: "─", minimumWidth: fullWidth) {
                sawInnerRule = true
            } else if isQuestionPage, sawInnerRule,
                let chat = DialogRowScanner.numberedOption(in: current, pointer: "❯"),
                chat.number == (drafts.last { $0.number != nil }?.number ?? 0) + 1
            {
                drafts.append(readNumbered(chat, isQuestionPage: true, isChat: true))
            } else if var last = drafts.popLast(), !last.isButton, let indent = current.indent,
                indent >= last.labelColumn
            {
                continueOption(&last, with: current)
                drafts.append(last)
            } else {
                break
            }
            row += 1
        }
        var scan = OptionScan(drafts: drafts, end: row)
        if !numbered.isEmpty {
            scan.problem = "Option \(numbered.first?.number ?? 0) is not where the list continues."
        }

        var footerRows: [ScreenRow] = []
        var index = row
        while index < rows.count, rows[index].isBlank { index += 1 }
        while index < rows.count, !rows[index].isBlank {
            guard isInactiveRow(rows[index]) else { return nil }
            footerRows.append(rows[index])
            index += 1
        }
        guard rows[index...].allSatisfy(\.isBlank) else { return nil }
        if !footerRows.isEmpty {
            let footer = ClaudeFooter(rows: footerRows)
            scan.footer = footer
            if scan.problem == nil, let rebinding = footer.rebinding {
                scan.problem = "The footer shows \u{201C}\(rebinding)\u{201D}; Heeler only sends Claude's default keys."
            }
        }
        if scan.problem == nil, let stray = drafts.firstIndex(where: \.hasStrayRow) {
            scan.problem = "Option \(stray + 1) has a row Heeler could not place."
        }
        return scan
    }

    private func readNumbered(_ numbered: NumberedOptionRow, isQuestionPage: Bool, isChat: Bool) -> OptionDraft {
        let row = rows[numbered.rowIndex]
        var runs = DialogRowScanner.runs(of: row, from: numbered.labelColumn)
        var isChecked: Bool?
        if isQuestionPage, let box = Self.checkbox(in: runs.map(\.text).joined()) {
            isChecked = box.isChecked
            runs = DialogRowScanner.runs(of: row, from: numbered.labelColumn + box.width)
        }
        let reading = readRuns(runs)
        var draft = OptionDraft(
            number: numbered.number, rowIndex: numbered.rowIndex, labelColumn: numbered.labelColumn,
            isFocused: numbered.isPointed, isChecked: isChecked, label: reading.label,
            labelIsInactive: reading.labelIsInactive, detail: reading.detail, field: reading.field,
            isFeedback: reading.feedbackLabel != nil, droppedResidue: reading.droppedResidue, isChat: isChat,
            lastRow: row)
        if let feedbackLabel = reading.feedbackLabel { draft.label = feedbackLabel }
        if reading.isMarkedChosen { draft.isChecked = true }
        return draft
    }

    /// An unnumbered button under a multi-select question (`Next`,
    /// `Submit`): bold text, with the pointer at column 0 when focused.
    private func buttonRow(_ row: ScreenRow) -> OptionDraft? {
        guard DialogRowScanner.numberedOption(in: row, pointer: "❯") == nil else { return nil }
        let pointed = row.text.first == "❯"
        let runs = row.runs.filter { !DialogRowScanner.isBlank($0) && !(pointed && $0.column == 0) }
        let label = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !runs.isEmpty, runs.allSatisfy(\.style.isBold), !label.isEmpty, !label.contains(" ") else { return nil }
        return OptionDraft(
            number: nil, rowIndex: row.index, labelColumn: runs.first?.column ?? 0, isFocused: pointed,
            label: label, labelIsInactive: false, isButton: true, lastRow: row)
    }

    /// Adds a row below an option's first row: a wrapped label or field, an
    /// inline description's continuation, or a description on its own row.
    private func continueOption(_ draft: inout OptionDraft, with row: ScreenRow) {
        let runs = DialogRowScanner.runs(of: row, from: draft.labelColumn)
        let text = runs.map(\.text).joined()
        let visible = runs.filter { !DialogRowScanner.isBlank($0) }
        let allInactive = !visible.isEmpty && visible.allSatisfy { $0.style.foreground == block.inactive }
        if allInactive {
            let wrapsPlaceholder =
                draft.field == nil && draft.detail == nil && draft.labelIsInactive
                && !DialogRowScanner.wouldFit(firstWordOf: text, after: draft.lastRow, columns: columns)
            if wrapsPlaceholder {
                draft.label = join(draft.label, text, after: draft.lastRow, boxColumn: draft.labelColumn)
                draft.lastRow = row
            } else {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                draft.detail = draft.detail.map { $0.isEmpty ? trimmed : $0 + " " + trimmed } ?? trimmed
            }
            return
        }
        if draft.detail != nil {
            draft.hasStrayRow = true
            return
        }
        if let field = draft.field {
            switch field {
            case .typed(let typed):
                let more = FieldText.read(runs)
                let addition =
                    switch more {
                    case .typed(let text), .placeholder(let text): text
                    }
                draft.field = .typed(join(typed, addition, after: draft.lastRow, boxColumn: draft.labelColumn))
            case .placeholder(let placeholder):
                draft.field = .placeholder(join(placeholder, text, after: draft.lastRow, boxColumn: draft.labelColumn))
            }
            draft.lastRow = row
            return
        }
        let reading = readRuns(runs)
        draft.label = join(draft.label, reading.label, after: draft.lastRow, boxColumn: draft.labelColumn)
        draft.lastRow = row
        if reading.droppedResidue { draft.droppedResidue = true }
        if let detail = reading.detail { draft.detail = detail.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits an option row's runs into label, inline description and
    /// field. The label is the default- or accent-colored text after the
    /// number; an inactive run is a description only after ` · `. Any other
    /// inactive run after the label is residue a narrow redraw left behind
    /// (`No` followed by a stale `r you`) and is dropped with the rest of
    /// the row.
    private func readRuns(_ runs: [ScreenRun]) -> OptionRowReading {
        var reading = OptionRowReading()
        if runs.contains(where: \.style.isReverse) {
            return readField(runs)
        }
        var detail: String?
        for run in runs {
            if detail != nil {
                detail?.append(run.text)
                continue
            }
            if DialogRowScanner.isBlank(run) {
                reading.label += run.text
                continue
            }
            if run.style.foreground == block.inactive {
                let text = run.text.drop(while: ScreenRow.isBlank)
                if text.hasPrefix("·") {
                    detail = String(text.dropFirst())
                    continue
                }
                if reading.labelIsInactive || reading.label.allSatisfy(ScreenRow.isBlank) {
                    reading.labelIsInactive = true
                    reading.label += run.text
                    continue
                }
                reading.droppedResidue = true
                break
            }
            if reading.labelIsInactive {
                reading.droppedResidue = true
                break
            }
            reading.label += run.text
        }
        var label = ScreenRow.normalizedSpaces(reading.label).trimmingCharacters(in: .whitespaces)
        if label.hasSuffix(" ✔") {
            label = String(label.dropLast(2))
            reading.isMarkedChosen = true
        }
        reading.label = label
        reading.detail = detail.map { ScreenRow.normalizedSpaces($0).trimmingCharacters(in: .whitespaces) }
        return reading
    }

    /// A row with the cursor in it: a text field, or a `Yes`/`No` row Tab
    /// turned into a note field (`No, ` in the accent color, then the
    /// field).
    private func readField(_ runs: [ScreenRun]) -> OptionRowReading {
        var reading = OptionRowReading()
        let visible = runs.enumerated().filter { !DialogRowScanner.isBlank($0.element) && !$0.element.style.isReverse }
        if let accent = block.accent, let first = visible.first, first.element.style.foreground == accent,
            first.offset < (runs.firstIndex(where: \.style.isReverse) ?? 0)
        {
            let label = first.element.text.trimmingCharacters(in: .whitespaces)
            if label.hasSuffix(",") {
                reading.feedbackLabel = String(label.dropLast())
                reading.label = String(label.dropLast())
                reading.field = FieldText.read(Array(runs[(first.offset + 1)...]))
                return reading
            }
        }
        let field = FieldText.read(runs)
        reading.field = field
        if case .placeholder(let text) = field { reading.label = text }
        return reading
    }

    /// `[ ] `, `[✔] ` and the like at the start of a multi-select option.
    private static func checkbox(in text: String) -> (isChecked: Bool, width: Int)? {
        let characters = Array(text.prefix(4))
        guard characters.count == 4, characters[0] == "[", characters[2] == "]", ScreenRow.isBlank(characters[3])
        else { return nil }
        switch characters[1] {
        case " ": return (false, 4)
        case "✔", "✓", "x", "X", "×": return (true, 4)
        default: return nil
        }
    }

    // MARK: Regions

    /// The nearest full-width `─` rule above `row`: the dialog's top, or
    /// the plan's lower box.
    private func topRule(above row: Int) -> Int? {
        (0..<row).reversed().first { index in
            DialogRowScanner.isRule(rows[index], of: "─", minimumWidth: fullWidth) && (rows[index].indent ?? 0) <= 2
        }
    }

    /// The rows between a permission dialog's title and its options, split
    /// by the `╌` rules around the command, diff or URL. Tips are dropped.
    private func bodySections(from start: Int, to end: Int) -> (before: [String], content: [ScreenRow], after: [String]) {
        var index = start
        if index < end, isBoldRow(rows[index]), rows[index].trimmedText.hasPrefix("Tip:") {
            index += 1
            while index < end, isBoldRow(rows[index]) { index += 1 }
        }
        let dashed = (index..<end).filter { DialogRowScanner.isRule(rows[$0], of: "╌", minimumWidth: fullWidth) }
        guard let open = dashed.first else {
            return (paragraphs(in: index..<end), [], [])
        }
        let close = dashed.dropFirst().first ?? end
        let content = (open + 1..<close).map { rows[$0] }
        let after = close < end ? paragraphs(in: close + 1..<end) : []
        return (paragraphs(in: index..<open), content, after)
    }

    /// The plan's upper box: its title and plan rows, as far as the screen
    /// shows them. A long plan pushes the title off the top.
    private func planUpperBox(above lowerRule: Int) -> (title: String?, planRows: [String], top: Int?) {
        var index = lowerRule - 1
        while index >= 0, rows[index].isBlank { index -= 1 }
        guard index >= 0, DialogRowScanner.isRule(rows[index], of: "╌", minimumWidth: fullWidth) else {
            return (nil, [], nil)
        }
        let close = index
        index -= 1
        while index >= 0, !DialogRowScanner.isRule(rows[index], of: "╌", minimumWidth: fullWidth) { index -= 1 }
        let planRows = (max(index + 1, 0)..<close).map { rows[$0].trimmedText }.filter { !$0.isEmpty }
        guard index >= 0 else { return (nil, planRows, nil) }
        let titleIndex = (max(0, index - 6)..<index).reversed().first { isBoldRow(rows[$0]) }
        let top = titleIndex.flatMap { title in (max(0, title - 3)..<title).reversed().first { isRuleRow(rows[$0]) } }
        return (titleIndex.map { rows[$0].trimmedText }, planRows, top ?? titleIndex)
    }

    private func reviewAnswers(in range: Range<Int>) -> [DialogSubject.ReviewAnswer] {
        var answers: [DialogSubject.ReviewAnswer] = []
        for index in range {
            let text = rows[index].trimmedText
            if text.hasPrefix("●") {
                answers.append(.init(question: text.dropFirst().trimmingCharacters(in: .whitespaces), answer: ""))
            } else if text.hasPrefix("→"), let last = answers.indices.last {
                answers[last].answer = text.dropFirst().trimmingCharacters(in: .whitespaces)
            }
        }
        return answers
    }

    /// `url:` and `prompt:` entries, wrapped rows joined to their entry.
    private func labeledEntries(_ content: [ScreenRow], labels: [String]) -> [String] {
        var entries: [(text: String, row: ScreenRow)] = []
        for row in content where !row.isBlank {
            let text = row.trimmedText
            if labels.contains(where: text.hasPrefix) || entries.isEmpty {
                entries.append((text, row))
            } else if let last = entries.indices.last {
                entries[last].text = join(entries[last].text, text, after: entries[last].row, boxColumn: row.indent ?? 0)
                entries[last].row = row
            }
        }
        return entries.map(\.text)
    }

    /// Consecutive non-blank rows joined as wrapped text; blank rows and
    /// rules separate paragraphs.
    private func paragraphs(in range: Range<Int>) -> [String] {
        var result: [String] = []
        var current: [ScreenRow] = []
        for index in range {
            let row = rows[index]
            if row.isBlank || isRuleRow(row) {
                if !current.isEmpty { result.append(joinRows(current)) }
                current = []
            } else {
                current.append(row)
            }
        }
        if !current.isEmpty { result.append(joinRows(current)) }
        return result
    }

    private func joinRows(_ group: [ScreenRow]) -> String {
        var text = ""
        var previous: ScreenRow?
        for row in group where !row.isBlank {
            if let previous {
                text = join(text, row.trimmedText, after: previous, boxColumn: row.indent ?? 0)
            } else {
                text = row.trimmedText
            }
            previous = row
        }
        return text
    }

    private func join(_ head: String, _ tail: String, after row: ScreenRow, boxColumn: Int) -> String {
        DialogRowScanner.join(
            ScreenRow.normalizedSpaces(head), ScreenRow.normalizedSpaces(tail), wrap: .claude, previousRow: row,
            columns: columns, boxColumn: boxColumn)
    }

    private func isInactiveRow(_ row: ScreenRow) -> Bool {
        let visible = row.visibleRuns
        return !visible.isEmpty && visible.allSatisfy { $0.style.foreground == block.inactive }
    }

    private func isBoldRow(_ row: ScreenRow) -> Bool {
        let visible = row.visibleRuns
        return !visible.isEmpty && visible.allSatisfy(\.style.isBold)
    }

    private func isRuleRow(_ row: ScreenRow) -> Bool {
        ["─", "╌", "▔"].contains { DialogRowScanner.isRule(row, of: $0, minimumWidth: fullWidth) }
    }

    /// A title row: the bold text at its start, then an optional
    /// ` · from …` source and a right-aligned `1 of N`.
    private static func title(of row: ScreenRow) -> (text: String, suffix: String?, position: String?) {
        var title = ""
        var rest = ""
        var inTitle = true
        for run in row.runs {
            if inTitle, run.style.isBold || DialogRowScanner.isBlank(run) && title.allSatisfy(ScreenRow.isBlank) {
                title += run.text
                continue
            }
            inTitle = false
            rest += run.text
        }
        var remainder = ScreenRow.normalizedSpaces(rest).trimmingCharacters(in: .whitespaces)
        var position: String?
        if let range = remainder.range(of: #"\d+ of \d+$"#, options: .regularExpression) {
            position = String(remainder[range])
            remainder = remainder[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        if remainder.hasPrefix("·") {
            remainder = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return (title.trimmingCharacters(in: .whitespaces), remainder.isEmpty ? nil : remainder, position)
    }

    // MARK: Results

    private func dialog(
        kind: BlockedDialogKind, title: String, sourceSuffix: String?, positionLabel: String?, body: [String],
        progress: String?, options: [DialogOption], top: Int, scan: OptionScan, subject: DialogSubject
    ) -> DialogParseResult {
        let focus = DialogFocusState(
            focusedOrdinal: options.first(where: \.isFocused)?.ordinal,
            checked: Set(options.filter { $0.isChecked == true }.map(\.ordinal)),
            inputText: options.first(where: \.isFocused).flatMap { option in
                if case .text(let text) = option.input { return text }
                return nil
            },
            feedbackOrdinal: zip(options, scan.drafts).first { $0.1.isFeedback }?.0.ordinal)
        let fingerprint = DialogFingerprint(
            program: .claude, kind: kind, title: title, sourceSuffix: sourceSuffix, body: body, progress: progress,
            options: options)
        return .dialog(
            BlockedDialog(
                kind: kind, title: title, sourceSuffix: sourceSuffix, positionLabel: positionLabel, body: body,
                progress: progress, options: options, rows: top..<(scan.lastRow + 1), fingerprint: fingerprint,
                focus: focus, subject: subject))
    }

    private func unrecognized(from top: Int?, _ reason: String, scan: OptionScan? = nil) -> DialogParseResult {
        let firstOption = block.rows.first?.rowIndex ?? 0
        let start = top ?? max(0, firstOption - 12)
        let lastOptionRow = block.rows.last?.rowIndex ?? firstOption
        let end = scan.map { max($0.lastRow, lastOptionRow) } ?? lastFooterRow(after: lastOptionRow)
        var numbered: [Int: String] = [:]
        for index in start...end {
            // Option numbers carry a color; numbers in a plan or command
            // do not.
            guard let option = DialogRowScanner.numberedOption(in: rows[index], pointer: "❯"),
                option.numberStyle.foreground != nil
            else { continue }
            let label = readRuns(DialogRowScanner.runs(of: rows[index], from: option.labelColumn)).label
            numbered[option.number] = label
        }
        let footerRows = Set(scan?.footer?.rows.map(\.index) ?? [])
        return .unrecognized(
            ClaudeExcerpt.make(rows: Array(rows[start...end]), footerRows: footerRows, numbered: numbered, reason: reason))
    }

    /// The last non-blank row of the trailing block after `row`.
    private func lastFooterRow(after row: Int) -> Int {
        var last = row
        for index in (row + 1)..<rows.count where !rows[index].isBlank { last = index }
        return last
    }
}

/// Builds generic-card excerpts for Claude screens.
enum ClaudeExcerpt {
    static func make(rows: [ScreenRow], footerRows: Set<Int>, numbered: [Int: String], reason: String)
        -> GenericDialogExcerpt
    {
        let trimmed = rows.drop(while: \.isBlank).reversed().drop(while: \.isBlank).reversed()
        let fingerprintRows = trimmed.filter { !footerRows.contains($0.index) }.map(\.text)
        return GenericDialogExcerpt(
            rows: Array(trimmed), numbered: numbered, reason: reason,
            fingerprint: DialogFingerprint(program: .claude, excerptRows: fingerprintRows))
    }
}

/// Claude's folder-trust dialog at startup: a warning-colored rule, the
/// bold `Accessing workspace:` title and two unnumbered options. Esc and
/// `No, exit` quit Claude Code.
private enum ClaudeTrustDialogReader {
    static let title = "Accessing workspace:"

    static func read(_ screen: ANSIScreen) -> DialogParseResult? {
        let rows = screen.rows
        let fullWidth = max(8, screen.columns - 4)
        guard
            let titleIndex = rows.lastIndex(where: { row in
                row.trimmedText == title && row.visibleRuns.allSatisfy(\.style.isBold)
            }), titleIndex > 0, DialogRowScanner.isRule(rows[titleIndex - 1], of: "─", minimumWidth: fullWidth),
            let last = rows.lastIndex(where: { !$0.isBlank }), last > titleIndex
        else { return nil }
        let top = titleIndex - 1

        // The footer, then a blank row, then the options above it.
        var footerStart = last
        while footerStart > titleIndex, !rows[footerStart - 1].isBlank { footerStart -= 1 }
        var optionsEnd = footerStart - 1
        while optionsEnd > titleIndex, rows[optionsEnd].isBlank { optionsEnd -= 1 }
        var optionsStart = optionsEnd
        while optionsStart > titleIndex + 1, !rows[optionsStart - 1].isBlank { optionsStart -= 1 }
        let footer = ClaudeFooter(rows: Array(rows[footerStart...last]))
        let optionRows = optionsStart <= optionsEnd ? Array(rows[optionsStart...optionsEnd]) : []

        // The options carry no numbers, so the generic card offers no
        // option buttons, only its key pad.
        func unrecognized(_ reason: String) -> DialogParseResult {
            .unrecognized(
                ClaudeExcerpt.make(
                    rows: Array(rows[top...last]), footerRows: Set(footerStart...last), numbered: [:],
                    reason: reason))
        }

        guard footerStart > optionsEnd + 1, optionRows.count == 2 else {
            return unrecognized("The trust dialog's options are not where Heeler expects them.")
        }
        if let rebinding = footer.rebinding {
            return unrecognized("The footer shows \u{201C}\(rebinding)\u{201D}; Heeler only sends Claude's default keys.")
        }
        var options: [DialogOption] = []
        for (index, row) in optionRows.enumerated() {
            let text = row.trimmedText
            let isFocused = text.hasPrefix("❯")
            let label = isFocused ? text.dropFirst().trimmingCharacters(in: .whitespaces) : text
            let role: DialogOptionRole? =
                if label.hasPrefix("No") {
                    .exitProgram
                } else if label.hasPrefix("Yes") {
                    .trust
                } else {
                    nil
                }
            guard let role else {
                return unrecognized("The trust dialog offers \u{201C}\(label)\u{201D}, which Heeler does not know.")
            }
            options.append(DialogOption(ordinal: index + 1, number: nil, label: label, role: role, isFocused: isFocused))
        }
        guard Set(options.map(\.role)) == [.exitProgram, .trust] else {
            return unrecognized("The trust dialog's options are not a Yes and a No.")
        }

        var body: [String] = []
        var subject = DialogSubject()
        var paragraph: [ScreenRow] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            var text = ""
            var previous: ScreenRow?
            for row in paragraph {
                text =
                    previous.map {
                        DialogRowScanner.join(
                            text, row.trimmedText, wrap: .claude, previousRow: $0, columns: screen.columns,
                            boxColumn: row.indent ?? 0)
                    } ?? row.trimmedText
                previous = row
            }
            body.append(text)
            paragraph = []
        }
        for index in (titleIndex + 1)..<optionsStart {
            let row = rows[index]
            if row.isBlank {
                flush()
                continue
            }
            // Leave out the inactive `Security guide` link.
            guard row.visibleRuns.contains(where: { $0.style.foreground == nil }) else { continue }
            if subject.workspacePath == nil, row.visibleRuns.allSatisfy(\.style.isBold) {
                subject.workspacePath = row.trimmedText
            }
            paragraph.append(row)
        }
        flush()

        let focus = DialogFocusState(focusedOrdinal: options.first(where: \.isFocused)?.ordinal)
        let fingerprint = DialogFingerprint(
            program: .claude, kind: .claudeWorkspaceTrust, title: title, sourceSuffix: nil, body: body, progress: nil,
            options: options)
        return .dialog(
            BlockedDialog(
                kind: .claudeWorkspaceTrust, title: title, sourceSuffix: nil, positionLabel: nil, body: body,
                progress: nil, options: options, rows: top..<(last + 1), fingerprint: fingerprint, focus: focus,
                subject: subject))
    }
}

/// A Claude dialog without numbered options that is not the trust dialog,
/// such as a tool prompt that defaults to No. Heeler cannot name its
/// options, so it goes to the generic card when its footer and a pointer
/// row show it is a live dialog.
private enum ClaudeLooseDialogReader {
    static func read(_ screen: ANSIScreen) -> DialogParseResult {
        let rows = screen.rows
        guard let last = rows.lastIndex(where: { !$0.isBlank }) else { return .none }
        let footer = rows[last]
        let text = footer.trimmedText
        let footerColors = Set(footer.visibleRuns.map(\.style.foreground))
        guard footerColors.count == 1, footerColors.first != nil,
            ["to cancel", "to confirm", "to select"].contains(where: text.contains)
        else { return .none }
        let pointerRow = (max(0, last - 12)..<last).reversed().first { index in
            let row = rows[index]
            guard let indent = row.indent, indent <= 4 else { return false }
            let trimmed = row.trimmedText
            return trimmed.hasPrefix("❯ ") && row.run(at: indent)?.style.background == nil
        }
        guard let pointerRow else { return .none }
        let fullWidth = max(8, screen.columns - 4)
        let top =
            (max(0, pointerRow - 25)..<pointerRow).reversed().first {
                DialogRowScanner.isRule(rows[$0], of: "─", minimumWidth: fullWidth)
            } ?? max(0, pointerRow - 12)
        return .unrecognized(
            ClaudeExcerpt.make(
                rows: Array(rows[top...last]), footerRows: [last], numbered: [:],
                reason: "The dialog's options are not numbered."))
    }
}
