import Foundation

/// Reads OpenCode's permission and question prompts from a visible-screen
/// read.
///
/// OpenCode 2.0.32 draws a prompt in place of its input box, at the bottom
/// of the session: a block of rows behind a left bar `┃` on a raised
/// background, with a blank bar row above and below its text. Messages and
/// tool output in the history use the same bar, but the input box ends the
/// screen with its status row, so a bar block is a prompt only when it ends
/// the screen. Its first row names it: `△ Permission required`, `△ Reject
/// permission` (the note a subagent's rejection asks for) or the muted
/// `Questions` of a question form. Any other block, such as the subagent
/// panel, is no prompt.
enum OpenCodeDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        guard let block = OpenCodeBlock.bottom(of: screen), let heading = block.sections.first?.first?.text else {
            return .none
        }
        switch heading {
        case permissionHeading:
            return permission(block, on: screen)
        case "△ Reject permission":
            return unrecognized(
                block, on: screen, "OpenCode asks what to do differently before it rejects. Answer it in the terminal.")
        case "Questions":
            return question(block, on: screen)
        default:
            return .none
        }
    }

    private static let permissionHeading = "△ Permission required"

    // MARK: Permissions

    /// `△ Permission required`, then `<icon> <action> <target>` (`→ Read
    /// .env`; a shell command has no such row), OpenCode's lines about the
    /// request (`Path: .env`, `$ ls -la`), and the options in a row on a
    /// darker band: `Allow once`, `Always allow` when OpenCode can keep a
    /// rule, and `Reject`, the focused one on a fill of its own. The key
    /// hints share the options' row on a wide screen and take a row below
    /// them under 80 columns.
    ///
    /// While `Always allow` has focus, OpenCode swaps the lines about the
    /// request for what the rule would allow, so those lines are notes and
    /// only the action row is the body. The fingerprint still carries the
    /// lines, apart from the body: a shell command's permission has no
    /// action row, and a subagent's names only the agent, so only their
    /// `$ git status` or `◉ <description>` line tells one request from the
    /// next.
    private static func permission(_ block: OpenCodeBlock, on screen: ANSIScreen) -> DialogParseResult {
        let layout = "Heeler doesn't know this permission's layout. Answer it with these keys or in the terminal."
        let sections = block.sections
        guard let optionsIndex = sections.firstIndex(where: { $0.first?.text.hasPrefix(allowOnce) == true }),
            optionsIndex > 0, let optionsLine = sections[optionsIndex].first,
            let labels = permissionOptions(optionsLine)
        else { return unrecognized(block, on: screen, layout) }

        let header = sections[0].dropFirst()
        let action = header.isEmpty ? nil : block.joined(header)
        var target: String?
        if let action {
            // The icon, then the action and its target.
            guard let space = action.firstIndex(of: " "), action.distance(from: action.startIndex, to: space) == 1
            else { return unrecognized(block, on: screen, layout) }
            target = action[action.index(after: space)...].trimmingCharacters(in: .whitespaces)
        }
        var notes = sections[1..<optionsIndex].flatMap { block.paragraphs($0) }
        let showsRule = notes.first?.hasPrefix("This will always allow") == true
        let body = target.map { [$0] } ?? []

        var subject = DialogSubject()
        if let target {
            let words = target.split(separator: " ", maxSplits: 1).map(String.init)
            subject.toolName = words.first
            let operand = words.count > 1 ? words[1] : nil
            switch subject.toolName {
            case "Read", "List", "Edit", "Write", "Patch": subject.filePath = operand
            case "WebFetch": subject.url = operand
            default: break
            }
            // An edit's lines are its diff, which stays in the terminal.
            if subject.toolName == "Edit", !showsRule {
                notes = []
            }
        } else {
            subject.toolName = "Shell"
            subject.command = notes.first { $0.hasPrefix("$ ") }.map { String($0.dropFirst(2)) }
        }
        subject.notes = notes

        let focused = focusedOption(labels.map { $0.background }, panel: optionsLine.background)
        let options = labels.enumerated().map { index, item in
            DialogOption(
                ordinal: index + 1, number: nil, label: item.label, role: permissionRoles[item.label] ?? .decline,
                isFocused: focused == index)
        }
        return .dialog(
            BlockedDialog(
                kind: .openCodePermission, title: permissionTitle, sourceSuffix: nil, positionLabel: nil, body: body,
                progress: nil, options: options, rows: block.rows,
                fingerprint: DialogFingerprint(
                    program: .opencode, kind: .openCodePermission, title: permissionTitle, sourceSuffix: nil,
                    body: body, progress: nil, options: options, requestLines: showsRule ? nil : notes,
                    ruleLines: showsRule ? notes : nil),
                focus: DialogFocusState(focusedOrdinal: focused.map { $0 + 1 }), subject: subject))
    }

    private static let permissionTitle = "Permission required"
    private static let allowOnce = "Allow once"
    private static let alwaysAllow = "Always allow"
    private static let reject = "Reject"
    private static let permissionRoles: [String: DialogOptionRole] = [
        allowOnce: .approve, alwaysAllow: .approvePersistent, reject: .decline,
    ]

    /// The labels at the start of the options row, each with the fill it is
    /// drawn on. Two or more blanks part the options from each other and
    /// from the key hints.
    private static func permissionOptions(_ line: OpenCodeBlock.Line) -> [(label: String, background: ScreenColor?)]? {
        let items = line.text.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let labels = Array(items.prefix { permissionRoles[$0] != nil })
        guard labels == [allowOnce, alwaysAllow, reject] || labels == [allowOnce, reject] else { return nil }
        var result: [(label: String, background: ScreenColor?)] = []
        var searchFrom = line.row.text.startIndex
        for label in labels {
            guard let range = line.row.text.range(of: label, range: searchFrom..<line.row.text.endIndex) else {
                return nil
            }
            let column = TerminalCellWidth.width(of: line.row.text[..<range.lowerBound])
            result.append((label, line.row.run(at: column)?.style.background))
            searchFrom = range.upperBound
        }
        return result
    }

    /// The option drawn on a fill unlike the band's. A theme that fills
    /// every option leaves the focused one as the only fill of its kind.
    private static func focusedOption(_ backgrounds: [ScreenColor?], panel: ScreenColor?) -> Int? {
        let filled = backgrounds.indices.filter { backgrounds[$0] != panel }
        if filled.count == 1 { return filled[0] }
        let lone = backgrounds.indices.filter { index in backgrounds.filter { $0 == backgrounds[index] }.count == 1 }
        return backgrounds.count > 2 && lone.count == 1 ? lone[0] : nil
    }

    // MARK: Questions

    /// `Questions`, the question, then `N. label` per answer, each answer's
    /// description indented under its label, and `N. Type your own answer`
    /// last; the focused answer's number and label share their color. Below,
    /// `↑↓ select  enter submit  esc dismiss`. A digit picks its answer and
    /// submits. Several questions add a tab row and `⇆ tab`, a multi-select
    /// question `enter toggle`, and typing an answer `esc close`; those
    /// stay in the terminal.
    private static func question(_ block: OpenCodeBlock, on screen: ANSIScreen) -> DialogParseResult {
        let layout = "Heeler answers only OpenCode's single questions. Answer this one in the terminal."
        let sections = block.sections
        guard sections.count >= 4, let footer = sections.last, footer.count == 1,
            DialogRowScanner.comparable(footer[0].text) == DialogRowScanner.comparable(singleQuestionFooter),
            let options = answers(sections[sections.count - 2], in: block)
        else { return unrecognized(block, on: screen, layout) }
        let texts = sections[1..<(sections.count - 2)].map { block.joined($0) }
        guard let question = texts.last else { return unrecognized(block, on: screen, layout) }
        var subject = DialogSubject()
        subject.question = question
        let focused = options.filter(\.isFocused)
        return .dialog(
            BlockedDialog(
                kind: .openCodeQuestion, title: question, sourceSuffix: nil, positionLabel: nil, body: texts,
                progress: nil, options: options, rows: block.rows,
                fingerprint: DialogFingerprint(
                    program: .opencode, kind: .openCodeQuestion, title: question, sourceSuffix: nil, body: texts,
                    progress: nil, options: options),
                focus: DialogFocusState(focusedOrdinal: focused.count == 1 ? focused[0].ordinal : nil),
                subject: subject))
    }

    private static let singleQuestionFooter = "↑↓ select  enter submit  esc dismiss"
    private static let ownAnswer = "Type your own answer"

    /// The numbered answers, 1 up, the last one OpenCode's own answer row.
    /// A deeper row continues the answer above: its label when drawn in the
    /// label's color, its description otherwise.
    private static func answers(_ lines: [OpenCodeBlock.Line], in block: OpenCodeBlock) -> [DialogOption]? {
        struct Answer {
            var number: Int
            var labelLines: [OpenCodeBlock.Line]
            var labelColor: ScreenColor?
            var detailLines: [OpenCodeBlock.Line] = []
            var isFocused: Bool
        }
        guard let indent = lines.first?.indent else { return nil }
        var answers: [Answer] = []
        for line in lines {
            if line.indent == indent {
                let digits = line.text.prefix(while: \.isNumber)
                guard let number = Int(digits), number == answers.count + 1,
                    line.text.dropFirst(digits.count).hasPrefix(". ")
                else { return nil }
                let labelColumn = line.column + digits.count + 2
                let labelColor = line.row.run(at: labelColumn)?.style.foreground
                let label = OpenCodeBlock.Line(
                    text: line.row.text(from: labelColumn).trimmingCharacters(in: .whitespaces),
                    indent: line.indent + digits.count + 2, column: labelColumn, background: line.background,
                    row: line.row)
                answers.append(
                    Answer(
                        number: number, labelLines: [label], labelColor: labelColor,
                        isFocused: line.row.run(at: line.column)?.style.foreground == labelColor))
            } else if line.indent > indent, var answer = answers.popLast() {
                if answer.detailLines.isEmpty, line.row.run(at: line.column)?.style.foreground == answer.labelColor {
                    answer.labelLines.append(line)
                } else {
                    answer.detailLines.append(line)
                }
                answers.append(answer)
            } else {
                return nil
            }
        }
        guard answers.count >= 2, block.joined(answers[answers.count - 1].labelLines) == ownAnswer else { return nil }
        // Without any focus shown, every row would read as focused.
        let showsFocus = answers.filter(\.isFocused).count == 1
        return answers.enumerated().map { index, answer in
            var label = block.joined(answer.labelLines)
            // A picked answer ends in a check.
            if label.hasSuffix("✓") { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
            return DialogOption(
                ordinal: index + 1, number: answer.number, label: label,
                detail: answer.detailLines.isEmpty ? nil : block.joined(answer.detailLines),
                role: index == answers.count - 1 ? .otherText : .answer, isFocused: showsFocus && answer.isFocused)
        }
    }

    // MARK: Anything else

    /// The block's rows verbatim, shown without the bar. The fingerprint
    /// covers the text on the block's own background, without what changes
    /// as the user acts: the band below it (options, or a reply field and
    /// its hints), or a form's key hints, its last row.
    private static func unrecognized(
        _ block: OpenCodeBlock, on screen: ANSIScreen, _ reason: String
    ) -> DialogParseResult {
        let panel = block.lines.first?.background
        let content = Array(block.lines.prefix { $0.background == panel })
        var sections = OpenCodeBlock.sections(of: content)
        if content.count == block.lines.count, sections.count > 1 { sections.removeLast() }
        return .unrecognized(
            GenericDialogExcerpt(
                rows: Array(screen.rows[block.rows]), numbered: [:], reason: reason,
                fingerprint: DialogFingerprint(program: .opencode, excerptRows: sections.flatMap { $0 }.map(\.text)),
                displayLines: block.lines.map { line in
                    // The band's hints sit at its right edge on a wide screen.
                    let indent = line.background == panel ? max(0, line.indent - 2) : 0
                    return line.text.isEmpty ? "" : String(repeating: " ", count: indent) + line.text
                }))
    }
}

/// The bar block that ends an OpenCode screen: a prompt, or the subagent
/// panel, in place of the input box.
struct OpenCodeBlock {
    /// The zero-based screen rows from the top padding row through the
    /// bottom one.
    let rows: Range<Int>
    /// Every row inside the bar, top to bottom, blank ones included.
    let lines: [Line]
    /// The column just past the last cell wrapped text may reach: the
    /// block's right edge less OpenCode's three cells of padding.
    let wrapColumn: Int

    struct Line {
        /// The text right of the bar, trimmed.
        let text: String
        /// Blank cells between the bar and the text.
        let indent: Int
        /// The column of the text's first cell.
        let column: Int
        /// The fill just right of the bar.
        let background: ScreenColor?
        let row: ScreenRow
    }

    /// The lines between blank rows, the padding rows dropped.
    var sections: [[Line]] { Self.sections(of: lines) }

    static func sections(of lines: [Line]) -> [[Line]] {
        var sections: [[Line]] = []
        var current: [Line] = []
        for line in lines {
            if line.text.isEmpty {
                if !current.isEmpty { sections.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    /// `section` as the lines OpenCode drew: a row continues the one above
    /// when its first word would not have fit there.
    func paragraphs(_ section: [Line]) -> [String] {
        var paragraphs: [[Line]] = []
        for line in section {
            if let previous = paragraphs.last?.last,
                !DialogRowScanner.wouldFit(firstWordOf: line.text, after: previous.row, columns: wrapColumn)
            {
                paragraphs[paragraphs.count - 1].append(line)
            } else {
                paragraphs.append([line])
            }
        }
        return paragraphs.map { joined($0) }
    }

    /// The rows as one wrapped line. OpenCode breaks at blanks or after a
    /// hyphen, and cuts a word too long for its row at the edge.
    func joined(_ lines: some Collection<Line>) -> String {
        var text = ""
        var previous: Line?
        for line in lines {
            text =
                previous.map {
                    DialogRowScanner.join(
                        text, line.text, wrap: .codex, previousRow: $0.row, columns: wrapColumn,
                        boxColumn: line.column)
                } ?? line.text
            previous = line
        }
        return text
    }

    /// The bar block whose last row is the screen's last non-blank one.
    static func bottom(of screen: ANSIScreen) -> OpenCodeBlock? {
        let rows = screen.rows
        guard let last = rows.lastIndex(where: { !$0.isBlank }), let bar = bar(of: rows[last]) else { return nil }
        var top = last
        while top > 0, let above = Self.bar(of: rows[top - 1]), above == bar {
            top -= 1
        }
        let lines = rows[top...last].map { row in
            let rest = row.text(from: bar.column + 1)
            let indent = TerminalCellWidth.width(of: rest.prefix(while: ScreenRow.isBlank))
            return Line(
                text: ScreenRow.normalizedSpaces(rest).trimmingCharacters(in: .whitespaces), indent: indent,
                column: bar.column + 1 + indent, background: row.run(at: bar.column + 1)?.style.background, row: row)
        }
        let panel = lines.first?.background
        let edge = rows[top].runs.last { $0.style.background == panel }?.endColumn ?? screen.columns
        return OpenCodeBlock(rows: top..<(last + 1), lines: lines, wrapColumn: edge - 3)
    }

    /// The bar a row starts with after blanks: its column and style.
    private static func bar(of row: ScreenRow) -> Bar? {
        guard let column = row.indent, row.text(from: column).first == "┃", let run = row.run(at: column) else {
            return nil
        }
        return Bar(column: column, style: run.style)
    }

    private struct Bar: Equatable {
        let column: Int
        let style: ScreenStyle
    }
}
