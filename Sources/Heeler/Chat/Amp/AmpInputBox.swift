import Foundation

/// Amp's local TUI closes its full-width input box with the working directory.
enum AmpInputBox {
    static func read(_ screen: ANSIScreen) -> InputBoxState {
        let rows = screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let openComposer = String(localized: "Open the ordinary Amp input box in the terminal.")
        let unknown = InputBoxState.unknown(openComposer)
        guard let bottom = rows.lastIndex(where: { !$0.isEmpty }),
            let top = rows[..<bottom].lastIndex(where: { $0.hasPrefix("╭─") && $0.hasSuffix("─╮") }),
            bottom > top + 1
        else { return unknown }
        if hasCommandPalette(in: rows[..<top]) || rows[top].contains("│") { return .noComposer(openComposer) }
        let footer = rows[bottom]
        guard footer.hasPrefix("╰"), footer.hasSuffix("─╯") else { return unknown }
        var draft: [String] = []
        for row in rows[(top + 1)..<bottom] {
            guard row.first == "│", row.last == "│", row.count >= 2 else { return unknown }
            let value = row.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { draft.append(value) }
        }
        if !draft.isEmpty { return .text(draft.joined(separator: "\n")) }
        // Amp replaces the start of this border with its streaming status during a turn.
        // A visible draft still holds above, even when the footer cannot confirm an idle box.
        guard footer.hasPrefix("╰─"), footer.contains("/") || footer.contains("~") else { return unknown }
        return .empty(placeholder: nil)
    }

    /// A floating palette can leave transcript text on either side of its frame.
    /// Require its search field as well as its title before holding a send.
    private static func hasCommandPalette(in history: ArraySlice<String>) -> Bool {
        for index in history.indices {
            let line = history[index]
            guard let title = line.range(of: "╭─ Command Palette "),
                line[title.upperBound...].hasPrefix("─"),
                line[title.upperBound...].contains("─╮")
            else { continue }
            if history[(index + 1)...].prefix(3).contains(where: { row in
                guard let field = row.range(of: "│ >") else { return false }
                return row[field.upperBound...].contains("│")
            }) { return true }
        }
        return false
    }
}
