import Foundation

/// Amp's local TUI closes its full-width input box with the working directory.
enum AmpInputBox {
    static func read(_ screen: ANSIScreen) -> InputBoxState {
        let rows = screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let unknown = InputBoxState.unknown(String(localized: "Open the ordinary Amp input box in the terminal."))
        guard let bottom = rows.lastIndex(where: { !$0.isEmpty }),
            rows[bottom].hasPrefix("╰─"), rows[bottom].hasSuffix("─╯"),
            rows[bottom].contains("/") || rows[bottom].contains("~"),
            let top = rows[..<bottom].lastIndex(where: { $0.hasPrefix("╭─") && $0.hasSuffix("─╮") }),
            bottom > top + 1
        else { return unknown }
        guard !rows[..<top].contains(where: { $0.hasPrefix("╭─") && $0.hasSuffix("─╮") }),
            !rows[top].dropFirst().dropLast().contains("│") else { return unknown }
        var draft: [String] = []
        for row in rows[(top + 1)..<bottom] {
            guard row.first == "│", row.last == "│", row.count >= 2 else { return unknown }
            let value = row.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { draft.append(value) }
        }
        return draft.isEmpty ? .empty(placeholder: nil) : .text(draft.joined(separator: "\n"))
    }
}
