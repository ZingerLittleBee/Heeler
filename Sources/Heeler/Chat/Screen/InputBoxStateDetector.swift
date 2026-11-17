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
    /// A dialog took the box's place: its title when Chat names it in the
    /// hold.
    case dialog(title: String?)
    /// No input box for this conversation is on screen: a home screen, a
    /// dashboard, a picker or a panel of single-key actions stands in its
    /// place, where a message would start a new conversation, reach another
    /// one, pick an entry, or press keys. The program's reason, shown as the
    /// hold as is.
    case noComposer(String)
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
            // herdr reports Codex idle under its plan selector, so no card
            // names it; the hold does.
            let isPlanPrompt = program == .codex && CodexPlanPrompt.shows(in: screen)
            return .dialog(title: isPlanPrompt ? CodexPlanPrompt.title : nil)
        case .none:
            break
        }
        switch program {
        case .claude: return claude(screen)
        case .codex: return codex(screen)
        case .pi, .omp: return PiInputBoxDetector.detect(screen, program: program)
        case .grok: return GrokInputBoxDetector.detect(screen)
        case .opencode: return OpenCodeScreenReader.read(screen).state
        case .agy: return AgyInputBoxDetector.detect(screen)
        }
    }

    // MARK: Claude

    /// Dim text in Claude's box is a placeholder: a hint
    /// (`CC/chunk-scapxbwa.js` `xde`) or, after a turn, a prompt suggestion
    /// of any text, which typing replaces. While a queued message is
    /// selected for editing, Enter edits it instead of sending, so that hint
    /// counts as an overlay.
    private static let claudeQueueEditHint = "Press Enter to edit the selected message"

    private static func claude(_ screen: ANSIScreen) -> InputBoxState {
        guard let box = ClaudeInputBox.locate(in: screen) else {
            return .unknown(String(localized: "Claude's input box is not on screen."))
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
            if codexShowsConversationOpenElsewhere(in: screen) { return .noComposer(codexConversationOpenElsewhere) }
            return .unknown(String(localized: "Codex's composer is not on screen."))
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
            return .unknown(String(localized: "Codex's composer shows neither text nor its placeholder."))
        }
        if lines.count == 1, !visible.isEmpty, visible.allSatisfy(\.style.isDim) {
            let shown = firstLine.hasSuffix("…") ? String(firstLine.dropLast()) : firstLine
            guard codexPlaceholders.contains(where: { $0.hasPrefix(shown) }) else {
                return .unknown(String(localized: "The composer shows \u{201C}\(firstLine)\u{201D}, which Heeler does not know."))
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
        let hints = ["again to quit", "to edit previous message", "reverse-i-search", "esc close", "Waiting for startup"]
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

    /// Codex's panel in the composer's place when another app holds the
    /// conversation: "This conversation is open in another app", "r to
    /// retry" and "Close it there and press R to continue here.", over key
    /// hints from "r retry f fork" (codex-cli 0.169.0, 2026-11-18). Single
    /// keys act there, so Chat holds, as for any screen without the
    /// composer, with what to do instead.
    ///
    /// Read only where the composer was not found, from the drawn rows
    /// nearest the bottom joined into one text, so neither the width nor
    /// where a row breaks matters, and colors and the panel's emoji count
    /// for nothing. The sentence takes another marker of the panel after
    /// it, so a conversation that quotes the sentence does not read as it.
    private static func codexShowsConversationOpenElsewhere(in screen: ANSIScreen) -> Bool {
        let rows = screen.rows
        guard let last = rows.lastIndex(where: { !$0.isBlank }) else { return false }
        let bottom = rows[...last].suffix(codexPanelRows).map(\.trimmedText).joined(separator: " ")
        let text = bottom.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let sentence = text.range(of: "This conversation is open in another app") else { return false }
        let after = text[sentence.upperBound...]
        return [#"\bClose it there and press R to continue here\b"#, #"\br to retry\b"#, #"\br retry f fork\b"#]
            .contains { after.range(of: $0, options: .regularExpression) != nil }
    }

    /// The rows, up to the last drawn one, that the panel and its hints may
    /// take once a narrow screen wraps them.
    private static let codexPanelRows = 14

    /// What to do about the panel, in `ChatLaunchNotice.stopSharedServer`'s
    /// terms for the shared server, short enough for the Composer's notice.
    private static var codexConversationOpenElsewhere: String {
        String(localized: "Codex reports this conversation open in another app. Close it there, then press R in the terminal. If no other app has it, Codex's shared server may hold it: codex app\u{2011}server daemon stop frees it, ending any other Codex on that server.")
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
