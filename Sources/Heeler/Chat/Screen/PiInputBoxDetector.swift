import Foundation

/// Positively recognizes the stock Pi rule editor above its footer and OMP's
/// box/band composers. Custom extension editors, completion lists, Vim
/// cursors and other OMP composer shapes remain in the terminal rather than
/// guessing Enter's role.
enum PiInputBoxDetector {
    static func detect(_ screen: ANSIScreen, program: ChatProgram) -> InputBoxState {
        if program == .omp, let band = ompBand(screen) { return band }
        let rows = screen.rows
        // Prefer the last editor on screen; rules in a tool's output above
        // it must never be mistaken for the input box.
        for bottom in rows.indices.reversed() {
            let end = rows[bottom].trimmedText
            let isRule = rule(end)
            let isBox = program == .omp && end.hasPrefix("╰") && end.hasSuffix("╯")
            guard isRule || isBox else { continue }
            var top = bottom - 1
            while top >= 0, bottom - top <= 12 {
                let start = rows[top].trimmedText
                if (isRule && (rule(start) || (program == .pi && piWorkingRule(start))))
                    || (isBox && start.hasPrefix("╭") && start.hasSuffix("╮"))
                {
                    break
                }
                top -= 1
            }
            guard top >= 0, bottom - top <= 12 else { continue }
            let input = isBox ? Array(rows[(top + 1)...bottom]) : Array(rows[(top + 1)..<bottom])
            guard !input.isEmpty else { continue }
            let hasCursor = input.contains { row in
                row.runs.contains { $0.style.isReverse }
                    || (program == .omp && row.text.contains("▏"))
            }
            guard hasCursor else { continue }
            if program == .pi {
                // Stock Pi's footer is a pwd row then a stats row, right
                // under the editor; extension statuses may follow. A
                // completion list draws between the editor and the footer.
                guard let stats = rows.indices.dropFirst(bottom + 2).first(where: { piStats(rows[$0].trimmedText) })
                else {
                    return .unknown("Pi's footer is not recognized. Continue in the Agent terminal.")
                }
                if stats != bottom + 2 { return .overlay(rows[bottom + 1].trimmedText) }
            } else {
                // Every nonblank row below OMP's editors is footer chrome.
                // Suggestions or an extension popup suspend sending.
                for row in rows.dropFirst(bottom + 1) where !row.isBlank {
                    let text = row.trimmedText
                    if text.hasPrefix("❯") || text.hasPrefix(">") || text.hasPrefix("/")
                        || text.lowercased().contains("esc to") || text.lowercased().contains("escape to")
                    {
                        return .overlay(text)
                    }
                }
            }
            var text: [String] = []
            for row in input {
                var value = row.text
                if isBox {
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("│") || trimmed.hasPrefix("╰") else {
                        return .unknown("The OMP editor is not recognized.")
                    }
                    value = String(trimmed.dropFirst())
                    if value.last == "│" || value.last == "╯" { value.removeLast() }
                    if value.hasPrefix("─") { value.removeFirst() }
                    if value.hasSuffix("─") { value.removeLast() }
                }
                // OMP's software insertion caret is chrome, not input.
                if program == .omp, value.trimmingCharacters(in: .whitespaces) == "▏" { value = "" }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { text.append(trimmed) }
            }
            let draft = text.joined(separator: "\n")
            if draft.hasPrefix("!") { return .shellMode(draft) }
            // Pi's empty editor is exactly one row; extra blank rows are
            // newlines the user typed.
            if draft.isEmpty, program == .pi, input.count != 1 { return .text(draft) }
            return draft.isEmpty ? .empty(placeholder: nil) : .text(draft)
        }
        return .unknown(
            "The \(program == .pi ? "Pi" : "Oh My Pi") input box is not recognized. Continue in the Agent terminal.")
    }

    /// OMP draws its default composer as a filled status band followed by
    /// an unboxed `╰─ ` prompt; agent.read omits the hardware cursor. The
    /// band's leading segment says whether OMP takes a message: idle shows
    /// `π > ` (18.10.4 unicode preset) or U+E0B6 then U+F0D57 (18.11.1
    /// nerd preset, plan mode included); a running turn swaps that glyph
    /// for a braille spinner and elapsed time. Any other band, such as the
    /// ASCII preset or a focused subagent, stays unrecognized. Approval
    /// and ask panels sit directly on the band without replacing the
    /// prompt. Every row after the prompt is consumed so a multiline draft
    /// cannot look empty.
    private static func ompBand(_ screen: ANSIScreen) -> InputBoxState? {
        let rows = screen.rows
        guard let prompt = rows.indices.last(where: { isOMPPrompt(rows[$0]) }), prompt > 0 else { return nil }
        let band = rows[prompt - 1]
        guard isOMPStatusBand(band) else { return nil }
        let header = band.trimmedText
        let isWorking: Bool
        if ompIdleBands.contains(where: { header.hasPrefix($0) }) {
            isWorking = false
        } else if ompSpinnerBand(header) {
            isWorking = true
        } else {
            return nil
        }
        if prompt > 1, rows[prompt - 2].trimmedText.hasSuffix("╯") {
            return .overlay(rows[prompt - 2].trimmedText)
        }
        var lines: [String] = []
        for index in prompt..<rows.count {
            let row = rows[index]
            let value = index == prompt ? String(ompPromptText(row).dropFirst(3)) : row.text
            let text = value.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // Suggestions/hints are not editor continuation rows. Unknown
            // chrome, such as the shell after OMP exits, also stays
            // non-sendable rather than being discarded.
            if index > prompt, !row.text.hasPrefix("   ") { return .overlay(text) }
            if text == "▏" { continue }
            lines.append(text)
        }
        let draft = lines.joined(separator: "\n")
        if draft.hasPrefix("!") { return .shellMode(draft) }
        if !draft.isEmpty { return .text(draft) }
        // Enter while a turn runs steers it, and OMP backgrounds a running
        // bash command to take the message.
        return isWorking
            ? .disabled("Oh My Pi is working. Send once it's idle, or steer from the terminal.")
            : .empty(placeholder: nil)
    }

    /// OMP's unboxed `╰─` prompt row under the status band.
    static func isOMPPrompt(_ row: ScreenRow) -> Bool {
        // herdr pads ANSI rows to the pane width; a trimmed read ends at `╰─`.
        row.text.hasPrefix("╰─ ") || row.text == "╰─"
    }

    /// OMP's status band: a filled row with rules and a context gauge.
    static func isOMPStatusBand(_ row: ScreenRow) -> Bool {
        row.text.contains("─") && row.text.range(of: #"\d{1,3}%"#, options: .regularExpression) != nil
            && row.runs.contains { $0.style.background != nil }
    }

    private static let ompIdleBands = ["π > ", "\u{E0B6} \u{F0D57} "]

    private static func ompSpinnerBand(_ header: String) -> Bool {
        let scalars = Array(header.unicodeScalars.prefix(3))
        return scalars.count == 3 && scalars[0] == "\u{E0B6}" && scalars[1] == " "
            && (0x2800...0x28FF).contains(scalars[2].value)
    }

    /// The prompt row without OMP's right-aligned italic hint: before the
    /// first message, U+F0636 U+F0312 `to change thinking effort`. Only a
    /// known hint set apart by at least two blanks is dropped; anything
    /// else stays part of the draft.
    private static func ompPromptText(_ row: ScreenRow) -> String {
        var runs = row.runs
        while let last = runs.last, last.text.allSatisfy(ScreenRow.isBlank) { runs.removeLast() }
        guard let hint = runs.last, hint.style.isItalic,
            hint.text.range(of: #"(?:to change thinking effort|to see \d+ running agents?)\s*$"#,
                options: .regularExpression) != nil
        else { return row.text }
        var body = runs.dropLast().map(\.text).joined()
        var gap = 0
        while let last = body.last, ScreenRow.isBlank(last) || ompHintIcons.contains(last) {
            gap = ScreenRow.isBlank(last) ? gap + 1 : 0
            body.removeLast()
        }
        return gap >= 2 ? body : row.text
    }

    private static let ompHintIcons: Set<Character> = ["\u{F0636}", "\u{F0312}"]

    /// Pi's footer stats: context use such as `0.0%/500k` or `?/200k`.
    /// Narrow panes cut the row with `...`, possibly before the gauge, so
    /// a cut row starting like the token, cost or gauge fields also counts.
    private static func piStats(_ text: String) -> Bool {
        if text.range(of: #"(?:\d+\.\d%|\?)/\d+(?:\.\d+)?[kM]?"#, options: .regularExpression) != nil { return true }
        guard text.hasSuffix("..."), let first = text.first else { return false }
        return first.isNumber || "↑↓RWC$?".contains(first)
    }

    private static func rule(_ text: String) -> Bool {
        text.count >= 10 && text.allSatisfy { $0 == "─" }
    }

    /// Pi's top rule while a turn runs, `── ⠸ Working ───`: a braille
    /// spinner and a label set into it, which extensions may reword. Enter
    /// then steers the turn. A scrolled editor's `↑ N more` rule is not
    /// one, so a draft too long to show never reads as empty.
    private static func piWorkingRule(_ text: String) -> Bool {
        text.range(of: "^──+ [\u{2800}-\u{28FF}] .+ ─+$", options: .regularExpression) != nil
    }
}
