import Foundation

/// Reads Antigravity CLI's dialogs from a visible-screen read (agy 1.5.3).
///
/// A dialog takes the input box's place at the bottom of the screen: a bold
/// yellow title at column 0 (`Command`, `Pending edit`, `Create file`,
/// `Question`, or `Accessing workspace:` for the trust prompt), a full-width
/// grey rule under every title but the trust prompt's, the request, a bold
/// question, the options, and a hint row of keys over the footer. Options
/// are numbered `N. label`, the selected one drawn `> N. label` in blue 12;
/// a label too long for its row continues at column 0. The trust prompt's
/// two options have no numbers. Scrollback above keeps past dialogs only
/// as rows: an answered one becomes a `● Ran …`, `● Edited …` or `?
/// <question>` row, but a declined one keeps its title at column 0, bold
/// blue instead of yellow, over `⎿  User declined the tool call` (56, 69,
/// 83). The frame is the bottom-most bold yellow title with a rule under it
/// above the last hint row, so such a title is never read as a dialog.
///
/// Under `NO_COLOR` agy 1.5.3 draws the same dialogs without colors: the
/// title bold, its rule plain, the selected row's `> ` plain. A declined
/// title and a past prompt's rows are bold too, but no rule follows a
/// declined title (143) and the rule over a past prompt is never the
/// screen's width, so there the frame is the bottom-most bold title with a
/// plain full-width rule under it. Every other row is read by its text, so
/// both palettes read alike.
///
/// Tab on a command's `Yes` or `No` row turns it into a note field, `> `
/// under the row, and its label into `Yes, and tell Antigravity CLI what to
/// do next` or `No, and tell Antigravity CLI what to do differently`; the
/// hint row becomes `enter Submit`. A question's `Write-in...` row, single
/// or multi-select, opens `Your answer:` under the options by its digit or
/// by Enter on the row, with `enter Submit · esc Back`; a multi-select
/// question keeps its boxes drawn above the field. Either
/// field keeps the dialog's fingerprint, so a card's step into it checks
/// against the same dialog. A dialog the parser doesn't know, or one it
/// can't read whole, holds sending as an excerpt without numbers.
enum AgyDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        let agy = AgyScreen(screen)
        guard agy.composer == nil, agy.showsDialog else { return .none }
        let rows = screen.rows
        guard let frame = AgyDialogFrame(rows, columns: screen.columns) else {
            return unrecognized(
                rows, from: nil, String(localized: "Heeler can't find the top of Antigravity CLI's dialog."))
        }
        let parsed: BlockedDialog?
        switch frame.title {
        case "Command": parsed = command(frame, rows)
        case "Pending edit": parsed = fileChange(frame, rows, kind: .agyFileEdit)
        case "Create file": parsed = fileChange(frame, rows, kind: .agyFileCreate)
        case "Question": parsed = question(frame, rows)
        case trustTitle: parsed = trust(frame, rows)
        default: parsed = nil
        }
        if let parsed { return .dialog(parsed) }
        return unrecognized(rows, from: frame.titleRow, unknownReason)
    }

    private static let unknownReason = String(
        localized: "Heeler doesn't know this Antigravity CLI dialog. Answer it with these keys or in the terminal.",
        comment: "On a Blocked card that shows an excerpt of the screen with keys to press")

    static let trustTitle = "Accessing workspace:"

    // MARK: Permissions

    /// `Requesting permission for:`, the command on rows indented three
    /// cells, `Run this command?`, then four options: run once, two rules
    /// for commands that start the same way (one for the conversation, one
    /// saved in settings.json), and `No, cancel`, which declines and ends
    /// the turn.
    private static func command(_ frame: AgyDialogFrame, _ rows: [ScreenRow]) -> BlockedDialog? {
        let content = frame.content
        guard let request = content.firstIndex(where: { rows[$0].trimmedText == "Requesting permission for:" }),
            let question = content.firstIndex(where: { $0 > request && rows[$0].trimmedText == commandQuestion }),
            let sheet = AgyOptionSheet(rows, in: (question + 1)..<frame.hintRow, amendable: true)
        else { return nil }
        let command = rows[(request + 1)..<question].map(\.trimmedText).filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !command.isEmpty, let options = permissionOptions(sheet) else { return nil }
        var subject = DialogSubject()
        // A command too long for its rows ends in `…`.
        subject.isRequestCut = command.hasSuffix("…")
        subject.command =
            subject.isRequestCut ? String(command.dropLast()).trimmingCharacters(in: .whitespaces) : command
        return dialog(
            .agyCommand, title: commandQuestion, body: [command], progress: nil, options: options,
            focus: sheet.focus, frame: frame, subject: subject)
    }

    private static let commandQuestion = "Run this command?"

    /// The file's path, cut at the screen's edge, with agy's `+N -N` count
    /// beside it when it fits; the changed lines, `N  -  old` and `N  +
    /// new` on red and green, padded to the edge, where a long one is cut;
    /// on an edit `shift+tab to auto-approve file edits`, which switches
    /// the mode and is no option; the question; then `Yes` and `No`. A
    /// creation lists the new file's lines as added. In both edits
    /// captured, agy draws the whole target as removed and the whole
    /// replacement as added, numbered from 1: 47 draws `1  -  cherry`, `1
    /// +  cherry`, `2  +  date` for `cherry` becoming `cherry` and `date`,
    /// though `cherry` is the file's line 3.
    private static func fileChange(_ frame: AgyDialogFrame, _ rows: [ScreenRow], kind: BlockedDialogKind)
        -> BlockedDialog?
    {
        let asked = kind == .agyFileEdit ? editQuestion : createQuestion
        let content = frame.content
        guard let pathRow = content.first(where: { !rows[$0].isBlank }),
            let question = content.firstIndex(where: { rows[$0].trimmedText == asked }),
            pathRow < question,
            let sheet = AgyOptionSheet(rows, in: (question + 1)..<frame.hintRow, amendable: false),
            let options = permissionOptions(sheet)
        else { return nil }
        // The path is the bold run, under `NO_COLOR` too; the counts follow
        // in their own colors.
        let bold = rows[pathRow].visibleRuns.filter { $0.style.isBold }
        let path = bold.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let last = bold.last else { return nil }
        let changeRows = rows[(pathRow + 1)..<question].filter {
            !$0.isBlank && !$0.trimmedText.hasPrefix(autoApproveHint)
        }
        let changes = changeRows.map(\.trimmedText)
        var subject = DialogSubject()
        subject.filePath = path
        let pathEnd = last.endColumn - last.text.reversed().prefix(while: ScreenRow.isBlank).count
        subject.isRequestCut = pathEnd >= frame.edge
        subject.cutChanges = Set(changeRows.indices.filter { changeRows[$0].contentWidth >= frame.edge })
        return dialog(
            kind, title: asked, body: [path] + changes, progress: nil, options: options, focus: sheet.focus,
            frame: frame, subject: subject)
    }

    private static let editQuestion = "Accept this file edit?"
    private static let createQuestion = "Allow creation of this file?"
    private static let autoApproveHint = "shift+tab"

    /// A permission's options by their labels; a row agy hasn't been seen
    /// to draw leaves the dialog to the generic card. `No` ends the turn:
    /// agy records `User declined the tool call` and stops.
    private static func permissionOptions(_ sheet: AgyOptionSheet) -> [DialogOption]? {
        var options: [DialogOption] = []
        for row in sheet.rows {
            guard let number = row.number, let role = DialogRowScanner.permissionRole(for: row.label, shortcut: nil)
            else { return nil }
            options.append(
                DialogOption(
                    ordinal: options.count + 1, number: number, label: row.label,
                    detail: role == .decline ? String(localized: "Ends the turn") : nil, role: role,
                    isFocused: row.isFocused))
        }
        let roles = Set(options.map(\.role))
        guard roles.contains(.approve), roles.contains(.decline) else { return nil }
        return options
    }

    // MARK: Questions

    /// `Question N/M: <text>`, then the answers and `Write-in...` last. A
    /// multi-select question marks its answers `[ ]` or `[x]`; an answer
    /// the agent recommends starts `(Recommended) `, which the card shows
    /// as a detail, as the transcript's question does.
    private static func question(_ frame: AgyDialogFrame, _ rows: [ScreenRow]) -> BlockedDialog? {
        let content = frame.content
        guard let head = content.first(where: { !rows[$0].isBlank }),
            let match = rows[head].trimmedText.wholeMatch(of: /Question (\d+)\/(\d+): (.+)/)
        else { return nil }
        var text = String(match.3)
        var index = head + 1
        // A question too long for its row continues until a blank row.
        while index < frame.hintRow, !rows[index].isBlank,
            DialogRowScanner.numberedOption(in: rows[index], pointer: ">") == nil
        {
            text += " " + rows[index].trimmedText
            index += 1
        }
        guard let sheet = AgyOptionSheet(rows, in: index..<frame.hintRow, amendable: false),
            let last = sheet.rows.last, last.label == writeIn
        else { return nil }
        var options: [DialogOption] = []
        for row in sheet.rows {
            guard let number = row.number else { return nil }
            if row.label == writeIn {
                guard row.ordinal == sheet.rows.count else { return nil }
                options.append(
                    DialogOption(
                        ordinal: row.ordinal, number: number, label: writeIn, role: .otherText,
                        isFocused: row.isFocused, input: .placeholder(writeIn)))
                continue
            }
            var label = row.label
            var checked: Bool?
            if let box = label.wholeMatch(of: /\[([ x])\] (.*)/) {
                checked = box.1 == "x"
                label = String(box.2)
            }
            var detail: String?
            if label.hasPrefix(recommended) {
                label = String(label.dropFirst(recommended.count))
                detail = String(
                    localized: "Recommended", comment: "Under the answer the agent recommends on a question card")
            }
            options.append(
                DialogOption(
                    ordinal: row.ordinal, number: number, label: label, detail: detail, role: .answer,
                    isFocused: row.isFocused, isChecked: checked))
        }
        // A question is single-select or multi-select throughout.
        let boxes = options.filter { $0.role == .answer }.map { $0.isChecked != nil }
        guard Set(boxes).count == 1 else { return nil }
        var focus = sheet.focus
        focus.checked = Set(options.filter { $0.isChecked == true }.map(\.ordinal))
        var subject = DialogSubject()
        subject.question = text
        return dialog(
            .agyQuestion, title: text, body: [text], progress: "Question \(match.1)/\(match.2)", options: options,
            focus: focus, frame: frame, subject: subject)
    }

    private static let writeIn = "Write-in..."
    private static let recommended = "(Recommended) "

    // MARK: Trust

    /// At start in a folder agy doesn't trust yet: the folder in bold,
    /// wrapped over as many rows as it takes, the question, agy's note, and
    /// two unnumbered options, `Yes, I trust this folder` and `No, exit`,
    /// the unselected one grey (plain under `NO_COLOR`). Trusting writes the
    /// folder into agy's settings; `No, exit` quits agy.
    private static func trust(_ frame: AgyDialogFrame, _ rows: [ScreenRow]) -> BlockedDialog? {
        let content = Array(frame.content)
        let blocks = content.split { rows[$0].isBlank }.map(Array.init)
        guard blocks.count == 4 else { return nil }
        // A long path wraps wherever the row ends, so its rows join as they are.
        let path = blocks[0].map { rows[$0].trimmedText }.joined()
        let question = blocks[1].map { rows[$0].trimmedText }.joined(separator: " ")
        let note = blocks[2].map { rows[$0].trimmedText }.joined(separator: " ")
        guard question == trustQuestion, !path.isEmpty else { return nil }
        var options: [DialogOption] = []
        for index in blocks[3] {
            let row = rows[index]
            let isFocused = row.text.hasPrefix(">")
            let label =
                isFocused ? String(row.trimmedText.dropFirst()).trimmingCharacters(in: .whitespaces) : row.trimmedText
            let role: DialogOptionRole
            switch label {
            case "Yes, I trust this folder": role = .trust
            case "No, exit": role = .exitProgram
            default: return nil
            }
            options.append(
                DialogOption(ordinal: options.count + 1, number: nil, label: label, role: role, isFocused: isFocused))
        }
        guard Set(options.map(\.role)) == [.trust, .exitProgram],
            options.filter(\.isFocused).count == 1
        else { return nil }
        var subject = DialogSubject()
        subject.workspacePath = path
        let focus = DialogFocusState(focusedOrdinal: options.first(where: \.isFocused)?.ordinal)
        return dialog(
            .agyWorkspaceTrust, title: trustTitle, body: [path, question, note], progress: nil, options: options,
            focus: focus, frame: frame, subject: subject)
    }

    private static let trustQuestion = "Do you trust the contents of this project?"

    // MARK: Building

    private static func dialog(
        _ kind: BlockedDialogKind, title: String, body: [String], progress: String?, options: [DialogOption],
        focus: DialogFocusState, frame: AgyDialogFrame, subject: DialogSubject
    ) -> BlockedDialog {
        BlockedDialog(
            kind: kind, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: progress,
            options: options, rows: frame.titleRow..<(frame.hintRow + 1),
            fingerprint: DialogFingerprint(
                program: .agy, kind: kind, title: title, sourceSuffix: nil, body: body, progress: progress,
                options: options),
            focus: focus, subject: subject)
    }

    /// The dialog's rows from its title, or the screen's last rows when no
    /// title shows, down to the hint row; the excerpt's fingerprint leaves
    /// out the selection marker and the hints, which move as keys go in.
    private static func unrecognized(_ rows: [ScreenRow], from top: Int?, _ reason: String) -> DialogParseResult {
        let visible = rows.indices.filter { !rows[$0].isBlank }
        let hint = visible.last { AgyDialogFrame.isHint(rows[$0]) }
        let end = hint.map { $0 + 1 } ?? rows.count
        let start = top ?? max(0, (visible.suffix(excerptRows).first ?? 0))
        let excerpt = Array(rows[start..<max(start, end)])
        let content = excerpt.filter { !AgyDialogFrame.isHint($0) }.map { row in
            row.text.hasPrefix("> ") ? "  " + row.text.dropFirst(2) : row.text
        }
        return .unrecognized(
            GenericDialogExcerpt(
                rows: excerpt, numbered: [:], reason: reason,
                fingerprint: DialogFingerprint(program: .agy, excerptRows: content)))
    }

    /// How many rows an excerpt without a title keeps.
    private static let excerptRows = 16
}

/// Where an Antigravity CLI dialog lies: its title, and the hint row that
/// ends it over the footer.
private struct AgyDialogFrame {
    let title: String
    let titleRow: Int
    /// The first row of the request, past the rule.
    let contentStart: Int
    let hintRow: Int
    /// The dialog's right edge: where its rule ends, the pane's width. The
    /// trust prompt has no rule, so it takes the widest row.
    let edge: Int

    var content: Range<Int> { contentStart..<hintRow }

    /// The bottom-most title: bold yellow from column 0, with a grey rule
    /// under it unless it is the trust prompt's, or under `NO_COLOR` bold
    /// without color over a plain rule the screen's width. A title the
    /// parser doesn't know still frames the dialog, so its excerpt starts
    /// at the title.
    init?(_ rows: [ScreenRow], columns: Int) {
        guard let hint = rows.indices.last(where: { Self.isHint(rows[$0]) }) else { return nil }
        for index in stride(from: hint - 1, through: 0, by: -1) {
            let row = rows[index]
            guard let palette = Self.titlePalette(row) else { continue }
            let title = row.trimmedText
            if title == AgyDialogParser.trustTitle {
                self.init(
                    title: title, titleRow: index, contentStart: index + 1, hintRow: hint,
                    edge: rows.map(\.contentWidth).max() ?? 0)
                return
            }
            // A past prompt's rule is never the screen's width, so a bold
            // row over it never frames a dialog without colors.
            let ruleWidth = palette == .colored ? 8 : AgyScreen.ruleWidth(columns: columns)
            guard index + 1 < hint, AgyScreen.rulePalette(rows[index + 1], width: ruleWidth) == palette
            else { continue }
            self.init(
                title: title, titleRow: index, contentStart: index + 2, hintRow: hint,
                edge: rows[index + 1].contentWidth)
            return
        }
        return nil
    }

    private init(title: String, titleRow: Int, contentStart: Int, hintRow: Int, edge: Int) {
        self.title = title
        self.titleRow = titleRow
        self.contentStart = contentStart
        self.hintRow = hintRow
        self.edge = edge
    }

    /// A title's palette: a single bold run from column 0, yellow 3 or
    /// without any color.
    private static func titlePalette(_ row: ScreenRow) -> AgyScreen.Palette? {
        guard row.visibleRuns.count == 1, let first = row.visibleRuns.first, first.column == 0, first.style.isBold
        else { return nil }
        if first.style.foreground == .indexed(3) { return .colored }
        if row.indent == 0, first.style == ScreenStyle(isBold: true) { return .colorless }
        return nil
    }

    /// A dialog's hint row: `↑/↓ Navigate · …`, or `enter Submit` while one
    /// of its fields has the keyboard.
    static func isHint(_ row: ScreenRow) -> Bool {
        let text = row.trimmedText
        return text.hasPrefix("↑/↓ Navigate") || text.hasPrefix("enter Submit")
    }
}

/// A dialog's numbered options, wrapped labels joined, and the field Tab or
/// `Write-in...` opens under them.
private struct AgyOptionSheet {
    struct Row {
        let ordinal: Int
        let number: Int?
        let label: String
        let isFocused: Bool
    }

    let rows: [Row]
    let focus: DialogFocusState

    /// - Parameter amendable: A command's rows, which Tab can turn into a
    ///   note field.
    init?(_ screen: [ScreenRow], in range: Range<Int>, amendable: Bool) {
        var rows: [Row] = []
        var labels: [String] = []
        var focused: Int?
        var field: (ordinal: Int, text: [String])?
        var answerField: [String]?
        var index = range.lowerBound
        while index < range.upperBound {
            let row = screen[index]
            if answerField != nil {
                // `Your answer:` is the last block over the hint, so a row
                // under it is typed text, even one that reads `1. mango`.
                if !row.isBlank { answerField?.append(row.trimmedText) }
                index += 1
                continue
            }
            if let option = DialogRowScanner.numberedOption(in: row, pointer: ">") {
                guard option.number == rows.count + 1 else { return nil }
                let isFocused = option.isPointed
                if isFocused {
                    guard focused == nil else { return nil }
                    focused = option.number
                }
                rows.append(Row(ordinal: option.number, number: option.number, label: "", isFocused: isFocused))
                labels.append(row.text(from: option.labelColumn).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }
            let text = row.trimmedText
            if row.isBlank {
                index += 1
                continue
            }
            if amendable, field == nil, !rows.isEmpty, row.indent == 4, text.hasPrefix(">") {
                // The note field under the row Tab turned into one.
                field = (rows.count, [String(text.dropFirst()).trimmingCharacters(in: .whitespaces)])
            } else if text == "Your answer:", !rows.isEmpty {
                answerField = []
            } else if let open = field, open.ordinal == rows.count {
                field?.text.append(text)
            } else if !rows.isEmpty, row.indent == 0, screen[index - 1].isBlank == false {
                // A label too long for its row continues at column 0.
                labels[labels.count - 1] += " " + text
            } else {
                return nil
            }
            index += 1
        }
        guard !rows.isEmpty else { return nil }
        var focus = DialogFocusState(focusedOrdinal: focused)
        if let field {
            guard focused == field.ordinal else { return nil }
            focus.feedbackOrdinal = field.ordinal
            let typed = field.text.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            focus.inputText = typed.isEmpty ? nil : typed
            let label = labels[field.ordinal - 1]
            guard let original = Self.amended[label] else { return nil }
            labels[field.ordinal - 1] = original
        }
        if let answerField, let focused {
            focus.feedbackOrdinal = focused
            let typed = answerField.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            focus.inputText = typed.isEmpty ? nil : typed
        }
        self.rows = zip(rows, labels).map { row, label in
            Row(ordinal: row.ordinal, number: row.number, label: label, isFocused: row.isFocused)
        }
        self.focus = focus
    }

    /// The labels Tab gives a command's rows, by the label each had.
    private static let amended = [
        "Yes, and tell Antigravity CLI what to do next": "Yes, run command",
        "No, and tell Antigravity CLI what to do differently": "No, cancel",
    ]
}
