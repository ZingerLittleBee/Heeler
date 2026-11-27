import Foundation

enum DevinInputBox {
    static let working = String(localized: "Wait for Devin to finish this turn, or steer it from the terminal.")
    private static let placeholder = "Ask Devin to build features, fix bugs, or work on your code"
    private static let unavailable = String(localized: "Open Devin’s message field in this terminal to send.")

    private static func field(_ screen: ANSIScreen) -> (rows: [String], width: Int, hint: Bool)? {
        let lines = screen.rows
        guard let footer = lines.lastIndex(where: { !$0.isBlank }), footer >= 3 else { return nil }
        let status = lines[footer].trimmedText
        guard !status.isEmpty, !status.contains("↑↓"), !status.contains("↵"), !status.hasPrefix("❭"),
              let lower = lines[..<footer].lastIndex(where: { !$0.isBlank }),
              lines[lower].trimmedText.count >= 12, lines[lower].trimmedText.allSatisfy({ $0 == "─" }),
              let upper = lines[..<lower].lastIndex(where: { $0.trimmedText.hasPrefix("─") && $0.trimmedText.hasSuffix("─") }),
              upper + 1 < lower, lines[upper + 1].text.hasPrefix("❭ ") else { return nil }
        var rows = [String(lines[upper + 1].text.dropFirst(2))]
        for line in lines[(upper + 2)..<lower] {
            guard line.isBlank || line.text.hasPrefix("  ") else { return nil }
            rows.append(line.isBlank ? "" : String(line.text.dropFirst(2)))
        }
        // Devin draws its placeholder in its theme's grey, rgb(124,124,124)
        // dark and rgb(107,107,107) light (3000.15.14), and a draft in the
        // terminal's default color, so any color or dim marks the hint.
        let ink = lines[upper + 1].runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.endColumn > 2 }
        let hint = !ink.isEmpty && ink.allSatisfy { $0.style.isDim || $0.style.foreground != nil }
        return (rows, lines[lower].trimmedText.count - 2, hint)
    }

    static func read(_ screen: ANSIScreen) -> InputBoxState {
        guard let field = field(screen) else { return .noComposer(unavailable) }
        let text = field.rows.map { row in
            row.lastIndex(where: { $0 != " " }).map { String(row[...$0]) } ?? ""
        }.joined(separator: "\n")
        if text == placeholder || (field.rows.count == 1 && text.hasSuffix("…") && text.count >= 12 && placeholder.hasPrefix(String(text.dropLast()))) {
            guard field.hint else {
                return .disabled(String(localized: "Devin’s message field could contain a draft. Enable terminal colors or send from this terminal."))
            }
            return .empty(placeholder: placeholder)
        }
        if text == "Guide Devin while it works" { return .disabled(working) }
        if text.hasPrefix("!") { return .shellMode(text) }
        return .text(text)
    }

    static func showsPaste(_ text: String, on screen: ANSIScreen) -> Bool {
        guard !text.isEmpty, let field = field(screen), field.width > 0 else { return false }
        // The viewport drops line-end blanks. At a soft wrap only a word or a
        // cell that would overflow could have moved onto the following row.
        var rest = text[...]
        for (i, row) in field.rows.enumerated() {
            let visible = row.lastIndex(where: { $0 != " " }).map { String(row[...$0]) } ?? ""
            guard rest.hasPrefix(visible) else { return false }
            rest = rest.dropFirst(visible.count)
            let spaces = rest.prefix(while: { $0 == " " })
            let next = rest.dropFirst(spaces.count)
            if i == field.rows.count - 1 { return next.isEmpty }
            if next.first == "\n" { rest = next.dropFirst(); continue }
            guard !visible.isEmpty, let nextChar = next.first else { return false }
            let word = next.prefix { $0 != " " && $0 != "\n" }
            let used = TerminalCellWidth.width(of: visible) + spaces.count
            let width = TerminalCellWidth.width(of: word)
            guard used + min(width, field.width) > field.width ||
                    used + TerminalCellWidth.width(of: nextChar) > field.width else { return false }
            rest = next
        }
        return false
    }

    static func isPlan(_ screen: ANSIScreen) -> Bool {
        field(screen) != nil && screen.rows.last(where: { !$0.isBlank })?.trimmedText.hasPrefix("Plan · ") == true
    }

    static func guidance(_ screen: ANSIScreen) -> String? {
        let rows = screen.rows.suffix(20).map(\.trimmedText)
        if rows.contains(where: { $0.contains("trust the authors of this directory?") }) {
            return String(localized: "Open this Devin terminal to confirm the directory shown on its trust prompt.")
        }
        if rows.contains(where: { $0.contains("devin auth login") || $0.hasPrefix("Sign in to Devin") }) {
            return String(localized: "Sign in to Devin in this terminal, then return to Chat.")
        }
        if rows.contains(where: { $0.contains("switch question") || $0.contains("esc close") }) {
            return String(localized: "Finish the active question or menu in this Devin terminal.")
        }
        return nil
    }

    static func stop(_ context: ChatStopContext) -> ChatStopVerdict {
        guard context.activity != .blocked, context.activity == .working || context.hasVerifiedTurn,
              read(context.screen) == .disabled(working),
              context.screen.rows.suffix(12).map(\.trimmedText).joined(separator: " ").contains("(esc twice to interrupt)")
        else { return .refuse(String(localized: "Open the Devin terminal to check the current turn before interrupting it.")) }
        return .press
    }
}
