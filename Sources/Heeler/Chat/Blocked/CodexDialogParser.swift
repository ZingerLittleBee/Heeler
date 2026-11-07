import Foundation

/// Reads Codex's approval overlays, question views and folder-trust screen
/// from a visible-screen read.
///
/// Codex styles by attribute (bold, dim, reverse, italic) rather than by
/// color, so the parser keys on attributes and stays theme-proof. Each view
/// is anchored by its footer: `Press enter to confirm or esc to cancel` for
/// approvals, `Question i/n` with `enter to submit …` for questions,
/// `enter submit … skip` for asynchronous questions, and `enter continue`
/// under `Folder access` for the trust screen. A view that does not fit
/// comes back as an excerpt for the generic card.
enum CodexDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        CodexDialogReader(screen: screen).read()
    }
}

/// Codex's composer: a prompt glyph at column 0, bold and neither dim nor
/// reversed. Past prompts in the history are bold and dim; a selected
/// option is reversed.
struct CodexComposer: Sendable, Hashable {
    let row: Int
    /// `›`, `»` at the highest reasoning effort, or `!` in shell mode.
    let glyph: Character

    static let glyphs: Set<Character> = ["›", "»", "!"]

    static func locate(in screen: ANSIScreen) -> CodexComposer? {
        for row in screen.rows.reversed() {
            guard let glyph = row.text.first, glyphs.contains(glyph), let run = row.runs.first,
                run.style.isBold, !run.style.isDim, !run.style.isReverse,
                row.text.dropFirst().first.map(ScreenRow.isBlank) ?? true,
                DialogRowScanner.numberedOption(in: row, pointer: DialogRowScanner.codexPointer) == nil
            else { continue }
            return CodexComposer(row: row.index, glyph: glyph)
        }
        return nil
    }
}

/// Codex's selector after a Plan-mode turn: `Implement this plan?` above
/// `1. Yes, implement this plan`, `2. Yes, clear context and implement` and
/// `3. No, stay in Plan mode`.
enum CodexPlanPrompt {
    static let title = "Implement this plan?"

    /// Whether the title sits directly above a first numbered option.
    static func shows(in screen: ANSIScreen) -> Bool {
        let rows = screen.rows
        guard let titleRow = rows.lastIndex(where: { $0.trimmedText == title }),
            let next = rows[(titleRow + 1)...].first(where: { !$0.isBlank })
        else { return false }
        return DialogRowScanner.numberedOption(in: next, pointer: DialogRowScanner.codexPointer)?.number == 1
    }
}

/// Codex's notice for answers waiting to be sent:
/// `• Messages to be submitted after next tool call …`, then
/// `↳ > <question>` and the answer per queued reply.
enum CodexQueuedNotice {
    static let heading = "Messages to be submitted after next tool call"

    /// Whether the notice lists a reply to the question titled `title`.
    static func shows(answerTo title: String, in screen: ANSIScreen) -> Bool {
        guard let heading = screen.rows.lastIndex(where: { $0.text.contains(heading) }) else { return false }
        let wanted = DialogRowScanner.comparable(title)
        for row in screen.rows[(heading + 1)...] {
            let text = row.trimmedText
            guard text.hasPrefix("↳ >") else { continue }
            let shown = DialogRowScanner.comparable(String(text.dropFirst(3)))
            if shown == wanted { return true }
            // A long title wraps; its first row then runs to the edge.
            if !shown.isEmpty, wanted.hasPrefix(shown), row.contentWidth >= screen.columns - 1 { return true }
        }
        return false
    }
}

private struct CodexDialogReader {
    let screen: ANSIScreen

    private var rows: [ScreenRow] { screen.rows }
    private var columns: Int { screen.columns }

    private static let approvalFooter = "Press enter to confirm or esc to cancel"
    private static let trustTitle = "Folder access"
    private static let headerLabels = [
        "Environment", "Reason", "Description", "Destination", "Permission rule", "Thread", "Input", "Server",
    ]

    func read() -> DialogParseResult {
        guard let last = rows.lastIndex(where: { !$0.isBlank }) else { return .none }
        let footerStart = blockStart(endingAt: last)
        let footerText = rows[footerStart...last].map(\.trimmedText).joined(separator: " ")
        if footerText.contains(Self.approvalFooter) {
            return readApproval(footer: footerStart...last)
        }
        if footerText.contains("enter submit"), footerText.contains("skip") {
            return readAsyncQuestion(footer: footerStart...last)
        }
        if footerText.contains("enter continue"), let trust = readTrust(footer: footerStart...last) {
            return trust
        }
        let composer = CodexComposer.locate(in: screen)
        if composer == nil, let questionRow = questionHeaderRow(before: footerStart),
            ["to submit answer", "to submit all", "clear notes", "esc to interrupt"].contains(where: footerText.contains)
        {
            return readQuestion(headerRow: questionRow, footer: footerStart...last)
        }
        if let collapsed = readCollapsedQuestions() { return collapsed }
        if composer != nil { return .none }
        return readLooseOptions(footer: footerStart...last)
    }

    // MARK: Views

    private func readApproval(footer: ClosedRange<Int>) -> DialogParseResult {
        guard let optionRange = blockAbove(footer.lowerBound) else {
            return unrecognized(top: nil, end: footer.upperBound, footer: footer, String(localized: "The approval's options are not on screen."))
        }
        let drafts = readOptions(in: optionRange, isQuestion: false)
        guard let title = titleAbove(optionRange.lowerBound) else {
            return unrecognized(
                top: nil, end: footer.upperBound, footer: footer, String(localized: "The top of the approval is off screen."))
        }
        let top = title.rows.lowerBound
        func fail(_ reason: String) -> DialogParseResult {
            unrecognized(top: top, end: footer.upperBound, footer: footer, reason)
        }
        guard let drafts else { return fail(String(localized: "The approval's options could not be read.")) }

        let kind: BlockedDialogKind
        var subject = DialogSubject()
        switch title.text {
        case "Would you like to run the following command?":
            kind = .codexExec
        case "Would you like to make the following edits?":
            kind = .codexPatch
        case let text where text.hasPrefix("Do you want to approve network access to"):
            kind = .codexNetwork
            subject.host = text.split(separator: "\"").dropFirst().first.map(String.init)
        default:
            return fail("Heeler does not know the approval \u{201C}\(title.text)\u{201D}.")
        }

        var options: [DialogOption] = []
        for (index, draft) in drafts.enumerated() {
            let (label, shortcut) = DialogRowScanner.splitShortcut(draft.label)
            guard let role = DialogRowScanner.permissionRole(for: label, shortcut: shortcut) else {
                return fail("Option \(draft.number) reads \u{201C}\(label)\u{201D}, which is not a label Heeler knows.")
            }
            options.append(
                DialogOption(
                    ordinal: index + 1, number: draft.number, label: label, shortcut: shortcut, role: role,
                    isFocused: draft.isFocused))
        }
        guard options.contains(where: { $0.role == .decline }), options.contains(where: { $0.role != .decline })
        else { return fail(String(localized: "The approval lacks a Yes or a No option.")) }

        let entries = headerEntries(in: (title.rows.upperBound)..<optionRange.lowerBound)
        for entry in entries {
            if entry.hasPrefix("$ ") {
                subject.command = String(entry.dropFirst(2))
            } else if let value = value(of: "Reason", in: entry) {
                subject.reason = value
            } else if let value = value(of: String(localized: "Environment"), in: entry) {
                subject.environment = value
            } else if let value = value(of: String(localized: "Destination"), in: entry) {
                subject.destinations.append(value)
            }
        }
        subject.filePath = subject.destinations.first
        return dialog(
            kind: kind, title: title.text, positionLabel: nil, body: entries, progress: nil, options: options,
            rows: top..<(footer.upperBound + 1), subject: subject)
    }

    private func readQuestion(headerRow: Int, footer: ClosedRange<Int>) -> DialogParseResult {
        func fail(_ reason: String) -> DialogParseResult {
            unrecognized(top: headerRow, end: footer.upperBound, footer: footer, reason)
        }
        let headerText = rows[headerRow].trimmedText
        let progress = headerText.range(of: #"^Question \d+/\d+"#, options: .regularExpression).map {
            String(headerText[$0])
        }
        let titleEnd = (headerRow + 1..<footer.lowerBound).first { rows[$0].isBlank } ?? footer.lowerBound
        let title = joinRows(Array(rows[(headerRow + 1)..<titleEnd]))
        guard !title.isEmpty, let optionStart = (titleEnd..<footer.lowerBound).first(where: { !rows[$0].isBlank })
        else { return fail(String(localized: "The question's options are not on screen.")) }
        let optionEnd = (optionStart..<footer.lowerBound).first { rows[$0].isBlank } ?? footer.lowerBound
        guard let drafts = readOptions(in: optionStart...(optionEnd - 1), isQuestion: true) else {
            return fail(String(localized: "The question's options could not be read."))
        }

        // A notes field opens between the options and the footer on Tab
        // (Codex 0.160.1 also on a paste): `›` and the text, or a dim `Add
        // notes` while blank. A long note wraps under its first row.
        var notes: String?
        var notesIndent = 0
        var lastNotesRow: ScreenRow?
        for index in optionEnd..<footer.lowerBound where !rows[index].isBlank {
            let row = rows[index]
            let indent = row.indent ?? 0
            if let previous = lastNotesRow {
                guard indent > notesIndent else { return fail(String(localized: "Rows between the options and the footer are unknown.")) }
                notes = DialogRowScanner.join(
                    notes ?? "", row.trimmedText, wrap: .codex, previousRow: previous, columns: columns,
                    boxColumn: indent)
                lastNotesRow = row
                continue
            }
            guard row.trimmedText.hasPrefix("›") else {
                return fail(String(localized: "Rows between the options and the footer are unknown."))
            }
            notesIndent = indent
            lastNotesRow = row
            switch FieldText.read(DialogRowScanner.runs(of: row, from: indent + 1)) {
            case .typed(let typed): notes = typed
            case .placeholder: notes = ""
            }
        }

        let options = drafts.enumerated().map { index, draft in
            DialogOption(
                ordinal: index + 1, number: draft.number, label: draft.label, detail: draft.detail,
                role: draft.label == "None of the above" ? .otherText : .answer, isFocused: draft.isFocused)
        }
        guard options.contains(where: { $0.role == .answer }) else {
            return fail("The question has no answers Heeler can read.")
        }
        var subject = DialogSubject()
        subject.question = title
        return dialog(
            kind: .codexQuestion, title: title, positionLabel: nil, body: [], progress: progress, options: options,
            rows: headerRow..<(footer.upperBound + 1), subject: subject, notes: notes)
    }

    private func readAsyncQuestion(footer: ClosedRange<Int>) -> DialogParseResult {
        guard let optionRange = blockAbove(footer.lowerBound), let titleBlock = blockAbove(optionRange.lowerBound)
        else {
            return unrecognized(top: nil, end: footer.upperBound, footer: footer, String(localized: "The question is not on screen."))
        }
        let top = titleBlock.lowerBound
        func fail(_ reason: String) -> DialogParseResult {
            unrecognized(top: top, end: footer.upperBound, footer: footer, reason)
        }
        var positionLabel: String?
        var titleRows: [ScreenRow] = []
        for index in titleBlock {
            let row = rows[index]
            let text = row.trimmedText
            if titleRows.isEmpty, text.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil {
                positionLabel = text
            } else if row.visibleRuns.allSatisfy(\.style.isBold) {
                titleRows.append(row)
            } else {
                return fail(String(localized: "The question's title could not be read."))
            }
        }
        let title = joinRows(titleRows)
        guard !title.isEmpty, let drafts = readOptions(in: optionRange, isQuestion: false) else {
            return fail(String(localized: "The question's options could not be read."))
        }
        let options = drafts.enumerated().map { index, draft in
            DialogOption(
                ordinal: index + 1, number: draft.number, label: draft.label,
                role: draft.label == "Other" ? .otherText : .answer, isFocused: draft.isFocused)
        }
        var subject = DialogSubject()
        subject.question = title
        return dialog(
            kind: .codexAsyncQuestion, title: title, positionLabel: positionLabel, body: [], progress: title,
            options: options, rows: top..<(footer.upperBound + 1), subject: subject)
    }

    /// Codex 0.165.0's folder-trust screen at startup: the bold `Folder
    /// access` title over the folder in dim rows; for a folder below a Git
    /// repository's root, a note and that root, dim too; the sentence
    /// asking for trust; then `1. Trust and continue` and `2. Quit` above
    /// `enter continue · esc quit`. Started without `--no-daemon`, Codex
    /// offers `Back to Agent Command Center` and `esc back` in place of
    /// quitting. Nil when no such title sits above the options.
    private func readTrust(footer: ClosedRange<Int>) -> DialogParseResult? {
        guard let optionRange = blockAbove(footer.lowerBound),
            let titleRow = (max(0, optionRange.lowerBound - 40)..<optionRange.lowerBound).last(where: { index in
                rows[index].trimmedText == Self.trustTitle && rows[index].visibleRuns.allSatisfy(\.style.isBold)
            })
        else { return nil }
        func fail(_ reason: String) -> DialogParseResult {
            unrecognized(top: titleRow, end: footer.upperBound, footer: footer, reason)
        }
        guard let drafts = readOptions(in: optionRange, isQuestion: false), drafts.count == 2 else {
            return fail(String(localized: "The trust screen's options could not be read."))
        }
        var options: [DialogOption] = []
        for (index, draft) in drafts.enumerated() {
            let role: DialogOptionRole
            switch draft.label {
            case "Trust and continue": role = .trust
            case "Quit": role = .exitProgram
            case "Back to Agent Command Center": role = .decline
            default:
                return fail("The trust screen offers \u{201C}\(draft.label)\u{201D}, which Heeler does not know.")
            }
            options.append(
                DialogOption(
                    ordinal: index + 1, number: draft.number, label: draft.label, role: role,
                    isFocused: draft.isFocused))
        }
        guard options.contains(where: { $0.role == .trust }), options.contains(where: { $0.role != .trust }) else {
            return fail(String(localized: "The trust screen's options are not a Trust and a Quit."))
        }

        // Paragraphs split where their rows turn dim or back: the folder
        // and the repository root are dim, the note and the question plain
        // or colored. Codex cuts a long path anywhere, two columns short
        // of the edge, and pads only its last row, so path rows join
        // without a space.
        var segments: [(text: String, isDim: Bool)] = []
        var paragraph: [ScreenRow] = []
        var paragraphIsDim = false
        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraphIsDim ? paragraph.map(\.trimmedText).joined() : joinRows(paragraph)
            segments.append((text, paragraphIsDim))
            paragraph = []
        }
        for index in (titleRow + 1)..<optionRange.lowerBound {
            let row = rows[index]
            if row.isBlank {
                flush()
                continue
            }
            let isDim = row.visibleRuns.allSatisfy(\.style.isDim)
            if isDim != paragraphIsDim { flush() }
            paragraphIsDim = isDim
            paragraph.append(row)
        }
        flush()

        guard let folder = segments.first, folder.isDim else {
            return fail(String(localized: "The trust screen's folder is not on screen."))
        }
        guard segments.contains(where: { !$0.isDim && $0.text.hasPrefix("Trust this folder?") }) else {
            return fail(String(localized: "The trust screen's question is not on screen."))
        }
        var subject = DialogSubject()
        subject.workspacePath = folder.text
        if let note = segments.firstIndex(where: { !$0.isDim && $0.text.contains("repository root") }),
            segments.indices.contains(note + 1), segments[note + 1].isDim
        {
            subject.workspaceRoot = segments[note + 1].text
        }
        return dialog(
            kind: .codexWorkspaceTrust, title: Self.trustTitle, positionLabel: nil, body: segments.map(\.text),
            progress: nil, options: options, rows: titleRow..<(footer.upperBound + 1), subject: subject)
    }

    /// `? 2 questions` with `shift+← to answer` under Codex's queued inputs:
    /// questions waiting while the turn runs. The composer stays usable to
    /// the eye, but Codex refuses prompts until they are answered. Codex
    /// 0.162.1 adds a countdown (`? 2 questions · 20s`) for a while; the
    /// title leaves it out, so the ticks keep the fingerprint.
    private func readCollapsedQuestions() -> DialogParseResult? {
        let countPattern = #"^\? \d+ questions?(?= · |$)"#
        guard
            let countRow = rows.lastIndex(where: {
                $0.trimmedText.range(of: countPattern, options: .regularExpression) != nil
            }),
            let hintRow = rows[(countRow + 1)...].prefix(2).first(where: { $0.trimmedText.contains("to answer") }),
            let count = rows[countRow].trimmedText.range(of: countPattern, options: .regularExpression)
        else { return nil }
        let title = String(rows[countRow].trimmedText[count].dropFirst(2))
        let top = countRow > 0 && rows[countRow - 1].trimmedText.contains("Queued follow-up inputs") ? countRow - 1 : countRow
        return dialog(
            kind: .codexAsyncCollapsed, title: title, positionLabel: nil, body: [], progress: nil, options: [],
            rows: top..<(hintRow.index + 1), subject: DialogSubject())
    }

    /// Numbered rows with a pointer near the bottom and no composer: some
    /// list view Heeler does not know.
    private func readLooseOptions(footer: ClosedRange<Int>) -> DialogParseResult {
        // A narrow pane wraps the list's question and option details, so
        // the pointed option and the question can sit well above the footer.
        let start = max(0, footer.upperBound - 30)
        let numbered = (start...footer.upperBound).compactMap {
            DialogRowScanner.numberedOption(in: rows[$0], pointer: DialogRowScanner.codexPointer)
        }
        guard let pointed = numbered.last(where: \.isPointed), rows[pointed.rowIndex].runs.contains(where: \.style.isReverse)
        else { return .none }
        let top = (start..<pointed.rowIndex).reversed().first { index in
            rows[index].isBlank && (index == 0 || rows[index - 1].isBlank)
        }.map { $0 + 1 } ?? min(pointed.rowIndex, max(0, footer.upperBound - 16))
        return unrecognized(
            top: top, end: footer.upperBound, footer: footer, String(localized: "Heeler does not know this list."))
    }

    // MARK: Options

    private struct OptionDraft {
        var number: Int
        var labelColumn: Int
        var isFocused: Bool
        var label: String
        var detail: String?
        var lastRow: ScreenRow
        var lastDetailRow: ScreenRow
    }

    /// Reads the numbered options in `range`, wrapped rows joined. Question
    /// rows have a second column: the description, dim beside an unselected
    /// label and plain reverse beside the selected one, whose label is bold
    /// reverse. Nil when the rows do not form options 1…N.
    private func readOptions(in range: ClosedRange<Int>, isQuestion: Bool) -> [OptionDraft]? {
        var drafts: [OptionDraft] = []
        for index in range {
            let row = rows[index]
            if let numbered = DialogRowScanner.numberedOption(in: row, pointer: DialogRowScanner.codexPointer) {
                guard numbered.number == drafts.count + 1 else { return nil }
                let runs = DialogRowScanner.runs(of: row, from: numbered.labelColumn)
                let (label, detail) = isQuestion ? splitColumns(runs, isSelected: numbered.isPointed) : (text(of: runs), nil)
                drafts.append(
                    OptionDraft(
                        number: numbered.number, labelColumn: numbered.labelColumn, isFocused: numbered.isPointed,
                        label: label, detail: detail, lastRow: row, lastDetailRow: row))
            } else if var draft = drafts.popLast(), let indent = row.indent, indent >= draft.labelColumn {
                let runs = DialogRowScanner.runs(of: row, from: draft.labelColumn)
                // A narrow pane wraps either column; a wrapped row keeps the
                // first row's styles, so it splits the same way.
                let (label, detail) =
                    isQuestion ? splitColumns(runs, isSelected: draft.isFocused) : (text(of: runs), nil)
                if let detail {
                    draft.detail = draft.detail.map {
                        DialogRowScanner.join(
                            $0, detail, wrap: .codex, previousRow: draft.lastDetailRow, columns: columns,
                            boxColumn: draft.labelColumn)
                    } ?? detail
                    draft.lastDetailRow = row
                }
                if !label.isEmpty {
                    draft.label = DialogRowScanner.join(
                        draft.label, label, wrap: .codex, previousRow: draft.lastRow, columns: columns,
                        boxColumn: draft.labelColumn)
                    draft.lastRow = row
                }
                drafts.append(draft)
            } else {
                return nil
            }
        }
        return drafts.isEmpty ? nil : drafts
    }

    private func splitColumns(_ runs: [ScreenRun], isSelected: Bool) -> (label: String, detail: String?) {
        var label = ""
        var detail = ""
        var inDetail = false
        for run in runs {
            if !inDetail, !DialogRowScanner.isBlank(run) {
                inDetail = isSelected ? !run.style.isBold : run.style.isDim
            }
            if inDetail { detail += run.text } else { label += run.text }
        }
        let trimmedDetail = ScreenRow.normalizedSpaces(detail).trimmingCharacters(in: .whitespaces)
        return (
            ScreenRow.normalizedSpaces(label).trimmingCharacters(in: .whitespaces),
            trimmedDetail.isEmpty ? nil : trimmedDetail
        )
    }

    // MARK: Regions

    /// The first row of the block of non-blank rows ending at `row`.
    private func blockStart(endingAt row: Int) -> Int {
        var start = row
        while start > 0, !rows[start - 1].isBlank { start -= 1 }
        return start
    }

    /// The block of non-blank rows above `row`, past any blank rows.
    private func blockAbove(_ row: Int) -> ClosedRange<Int>? {
        var end = row - 1
        while end >= 0, rows[end].isBlank { end -= 1 }
        guard end >= 0 else { return nil }
        return blockStart(endingAt: end)...end
    }

    /// The bold title above the header rows of an approval. Header rows sit
    /// at column 2 like the title; reaching a column-0 row first means the
    /// history, so the title is off screen.
    private func titleAbove(_ row: Int) -> (text: String, rows: Range<Int>)? {
        var cursor = row
        while let block = blockAbove(cursor), cursor - block.lowerBound <= 24 {
            let blockRows = block.map { rows[$0] }
            guard blockRows.allSatisfy({ ($0.indent ?? 0) > 0 }) else { return nil }
            if blockRows.allSatisfy({ $0.visibleRuns.allSatisfy(\.style.isBold) }) {
                return (joinRows(blockRows), block.lowerBound..<(block.upperBound + 1))
            }
            cursor = block.lowerBound
        }
        return nil
    }

    /// The `Question i/n` row above the footer.
    private func questionHeaderRow(before footer: Int) -> Int? {
        (max(0, footer - 30)..<footer).reversed().first { index in
            let row = rows[index]
            return row.trimmedText.range(of: #"^Question \d+/\d+"#, options: .regularExpression) != nil
                && row.visibleRuns.first?.style.isDim == true
        }
    }

    /// `Environment: local`, `Reason: …`, `$ touch x1.txt` and the like,
    /// wrapped rows joined to their entry.
    private func headerEntries(in range: Range<Int>) -> [String] {
        var entries: [(text: String, row: ScreenRow)] = []
        for index in range where !rows[index].isBlank {
            let row = rows[index]
            let text = ScreenRow.normalizedSpaces(row.trimmedText)
            let startsEntry =
                text.hasPrefix("$ ") || Self.headerLabels.contains { text.hasPrefix($0 + ":") }
            if startsEntry || entries.isEmpty {
                entries.append((text, row))
            } else if let last = entries.indices.last {
                entries[last].text = DialogRowScanner.join(
                    entries[last].text, text, wrap: .codex, previousRow: entries[last].row, columns: columns,
                    boxColumn: row.indent ?? 0)
                entries[last].row = row
            }
        }
        return entries.map(\.text)
    }

    private func value(of label: String, in entry: String) -> String? {
        guard entry.hasPrefix(label + ":") else { return nil }
        return entry.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
    }

    private func text(of runs: [ScreenRun]) -> String {
        ScreenRow.normalizedSpaces(runs.map(\.text).joined()).trimmingCharacters(in: .whitespaces)
    }

    private func joinRows(_ group: [ScreenRow]) -> String {
        var text = ""
        var previous: ScreenRow?
        for row in group where !row.isBlank {
            if let previous {
                text = DialogRowScanner.join(
                    text, row.trimmedText, wrap: .codex, previousRow: previous, columns: columns,
                    boxColumn: row.indent ?? 0)
            } else {
                text = row.trimmedText
            }
            previous = row
        }
        return text
    }

    // MARK: Results

    private func dialog(
        kind: BlockedDialogKind, title: String, positionLabel: String?, body: [String], progress: String?,
        options: [DialogOption], rows: Range<Int>, subject: DialogSubject, notes: String? = nil
    ) -> DialogParseResult {
        let fingerprint = DialogFingerprint(
            program: .codex, kind: kind, title: title, sourceSuffix: nil, body: body, progress: progress,
            options: options)
        return .dialog(
            BlockedDialog(
                kind: kind, title: title, sourceSuffix: nil, positionLabel: positionLabel, body: body,
                progress: progress, options: options, rows: rows, fingerprint: fingerprint,
                focus: DialogFocusState(focusedOrdinal: options.first(where: \.isFocused)?.ordinal, notesText: notes),
                subject: subject))
    }

    private func unrecognized(top: Int?, end: Int, footer: ClosedRange<Int>, _ reason: String) -> DialogParseResult {
        let start = top ?? max(0, footer.lowerBound - 16)
        let excerptRows = rows[start...end].drop(while: \.isBlank)
        let fingerprintRows = excerptRows.filter { !footer.contains($0.index) }.map(\.text)
        return .unrecognized(
            GenericDialogExcerpt(
                rows: Array(excerptRows), numbered: numberedOptions(near: footer, from: start), reason: reason,
                fingerprint: DialogFingerprint(program: .codex, excerptRows: fingerprintRows)))
    }

    /// The numbered rows of the options block: the last block when the list
    /// has no footer, else the block above the footer. Numbered lines
    /// further up belong to the history or a reply.
    ///
    /// A two-column list such as the MCP tool approval draws a description
    /// beside each label, and a narrow pane wraps both columns, so a label
    /// keeps only its text before the description's gap, joined with the
    /// rows below that start at its own column (`2. Allow for this` +
    /// `session`). Rows that start at the description column add nothing.
    private func numberedOptions(near footer: ClosedRange<Int>, from start: Int) -> [Int: String] {
        for block in [footer, blockAbove(footer.lowerBound)].compactMap({ $0 }) {
            var numbered: [Int: String] = [:]
            var current: NumberedOptionRow?
            for index in block where index >= start {
                if let option = DialogRowScanner.numberedOption(in: rows[index], pointer: DialogRowScanner.codexPointer)
                {
                    numbered[option.number] = labelText(of: DialogRowScanner.runs(of: rows[index], from: option.labelColumn))
                    current = option
                } else if let option = current, rows[index].indent == option.labelColumn {
                    let part = labelText(of: DialogRowScanner.runs(of: rows[index], from: option.labelColumn))
                    guard !part.isEmpty else { continue }
                    let head = numbered[option.number] ?? ""
                    numbered[option.number] = head.isEmpty ? part : head + " " + part
                }
            }
            if !numbered.isEmpty { return numbered }
        }
        return [:]
    }

    /// The row's text before a two-column list's description. Codex puts
    /// the description two blanks past the widest label (more past shorter
    /// ones) and draws it dim, or plain beside the pointed row's bold label,
    /// as `splitColumns` reads a question's. A row drawn otherwise cuts at
    /// its first gap of three or more blanks.
    private func labelText(of runs: [ScreenRun]) -> String {
        let isBoldRow = runs.first { !DialogRowScanner.isBlank($0) }?.style.isBold ?? false
        var label = ""
        for run in runs {
            let isDescription = isBoldRow ? !run.style.isBold : run.style.isDim
            if isDescription, !DialogRowScanner.isBlank(run), !label.isEmpty,
                ScreenRow.normalizedSpaces(label).hasSuffix("  ")
            {
                break
            }
            label += run.text
        }
        let text = ScreenRow.normalizedSpaces(label).trimmingCharacters(in: .whitespaces)
        guard let gap = text.range(of: "   ") else { return text }
        return text[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
    }
}
