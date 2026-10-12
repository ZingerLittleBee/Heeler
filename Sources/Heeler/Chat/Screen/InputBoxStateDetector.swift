import Foundation

/// What the Agent's input box shows in a visible-screen read.
///
/// Chat delivers a message by having herdr type it and press Enter, so the
/// box must be empty first: text already in it would be sent along, and a
/// popup or picker would take the keys. Only `.empty` is sendable, and only
/// after positive identification; every other state carries what the user
/// needs to resolve it in the terminal. Heeler never clears the box.
enum InputBoxState: Equatable, Sendable {
    /// Empty, showing `placeholder` when the program draws one.
    case empty(placeholder: String?)
    /// A draft the user typed in the terminal.
    case text(String)
    /// Shell mode (`!`), with the command typed so far.
    case shellMode(String)
    /// Input is disabled; the program's explanation.
    case disabled(String)
    /// A popup, picker, help view or transient hint over the box: the row
    /// that shows it.
    case overlay(String)
    /// A dialog took the box's place.
    case dialog
    /// The screen does not show a box Heeler recognizes; why.
    case unknown(String)

    var isSendable: Bool {
        if case .empty = self { true } else { false }
    }
}

enum InputBoxStateDetector {
    static func detect(_ screen: ANSIScreen, program: ChatProgram) -> InputBoxState {
        switch BlockedDialogParser.parse(screen, program: program) {
        case .dialog, .unrecognized:
            return .dialog
        case .none:
            break
        }
        switch program {
        case .claude: return claude(screen)
        case .codex: return codex(screen)
        }
    }

    // MARK: Claude

    /// Hints Claude shows in an empty box (`CC/chunk-scapxbwa.js` `xde`).
    /// While a queued message is selected for editing, Enter edits it
    /// instead of sending, so that hint counts as an overlay.
    private static let claudePlaceholders = [
        "Try \"", "Message @", "Press up to edit queued messages", "Press up to select a queued message",
    ]
    private static let claudeQueueEditHint = "Press Enter to edit the selected message"

    private static func claude(_ screen: ANSIScreen) -> InputBoxState {
        guard let box = ClaudeInputBox.locate(in: screen) else {
            return .unknown("Claude's input box is not on screen.")
        }
        let rows = screen.rows
        let field = FieldText.read(DialogRowScanner.runs(of: rows[box.inputRows.lowerBound], from: 2))
        let moreLines = box.inputRows.dropFirst().map { rows[$0].trimmedText }.filter { !$0.isEmpty }

        var firstLine = ""
        var placeholder: String?
        switch field {
        case .typed(let text): firstLine = text
        case .placeholder(let text): placeholder = text.isEmpty ? nil : text
        }
        let lines = (firstLine.isEmpty ? [] : [firstLine]) + moreLines
        if box.glyph == "!" {
            return .shellMode(lines.joined(separator: "\n"))
        }
        if !lines.isEmpty {
            return .text(lines.joined(separator: "\n"))
        }
        if let overlay = claudeOverlay(below: box, in: screen) {
            return .overlay(overlay)
        }
        guard let placeholder else { return .empty(placeholder: nil) }
        if placeholder.hasPrefix(claudeQueueEditHint) {
            return .overlay(placeholder)
        }
        guard claudePlaceholders.contains(where: placeholder.hasPrefix) else {
            return .unknown("The input box shows \u{201C}\(placeholder)\u{201D}, which Heeler does not know.")
        }
        return .empty(placeholder: placeholder)
    }

    /// Suggestions and pickers Claude draws under the box: a pointer row,
    /// a numbered row, or a `/command` with its description.
    private static func claudeOverlay(below box: ClaudeInputBox, in screen: ANSIScreen) -> String? {
        let patterns = [#"^(❯|>)\s+\S"#, #"^\d+\.\s"#, #"^/[\w:-]+\s{2,}\S"#]
        for row in screen.rows[(box.bottomRule + 1)...] where !row.isBlank {
            let text = row.trimmedText
            if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
                return text
            }
        }
        return nil
    }

    // MARK: Codex

    /// The composer's placeholders (`CX/tui/src/chatwidget.rs`). A narrow
    /// screen can cut them short.
    private static let codexPlaceholders = ["Ask Codex to do anything", "Ask a follow-up question"]

    private static func codex(_ screen: ANSIScreen) -> InputBoxState {
        guard let composer = CodexComposer.locate(in: screen) else {
            if let reason = codexDisabledReason(in: screen) { return .disabled(reason) }
            return .unknown("Codex's composer is not on screen.")
        }
        let rows = screen.rows
        let runs = DialogRowScanner.runs(of: rows[composer.row], from: 2)
        let firstLine = ScreenRow.normalizedSpaces(runs.map(\.text).joined()).trimmingCharacters(in: .whitespaces)
        var lines = firstLine.isEmpty ? [] : [firstLine]
        // A draft continues at column 2 until a blank row.
        var next = composer.row + 1
        while next < rows.count, !rows[next].isBlank, (rows[next].indent ?? 0) >= 2 {
            lines.append(rows[next].trimmedText)
            next += 1
        }
        let visible = runs.filter { !DialogRowScanner.isBlank($0) }
        if composer.glyph == "!" {
            return .shellMode(lines.joined(separator: "\n"))
        }
        if lines.isEmpty {
            return .unknown("Codex's composer shows neither text nor its placeholder.")
        }
        if lines.count == 1, !visible.isEmpty, visible.allSatisfy(\.style.isDim) {
            let shown = firstLine.hasSuffix("…") ? String(firstLine.dropLast()) : firstLine
            guard codexPlaceholders.contains(where: { $0.hasPrefix(shown) }) else {
                return .unknown("The composer shows \u{201C}\(firstLine)\u{201D}, which Heeler does not know.")
            }
            if let overlay = codexOverlay(around: composer, in: screen) {
                return .overlay(overlay)
            }
            return .empty(placeholder: firstLine)
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// Transient hints under the composer and popups drawn above it
    /// (`CX/tui/src/bottom_pane/footer.rs` and the composer snapshots).
    private static func codexOverlay(around composer: CodexComposer, in screen: ANSIScreen) -> String? {
        let rows = screen.rows
        let hints = ["again to quit", "to edit previous message", "reverse-i-search", "esc close"]
        for row in rows[(composer.row + 1)...] where !row.isBlank {
            let text = row.trimmedText
            if hints.contains(where: text.contains) { return text }
        }
        var index = composer.row - 1
        if index >= 0, rows[index].isBlank { index -= 1 }
        while index >= 0, !rows[index].isBlank {
            let text = rows[index].trimmedText
            if text == "Keyboard shortcuts" || text.contains("esc close")
                || text.range(of: #"^(›\s+)?/[\w:-]+\s{2,}\S"#, options: .regularExpression) != nil
            {
                return text
            }
            index -= 1
        }
        return nil
    }

    /// A dim `›` with Codex's disabled-input text in place of the
    /// placeholder.
    private static func codexDisabledReason(in screen: ANSIScreen) -> String? {
        for row in screen.rows.reversed() {
            guard row.text.first == "›", let run = row.runs.first, run.style.isDim, !run.style.isBold else { continue }
            let text = String(row.trimmedText.dropFirst()).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Input disabled") || text.contains("direct input is disabled") {
                return text
            }
        }
        return nil
    }
}
