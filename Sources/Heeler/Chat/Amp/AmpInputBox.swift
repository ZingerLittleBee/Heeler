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
        guard !hasOverlay(in: rows[..<top]), !rows[top].contains("│") else { return unknown }
        var draft: [String] = []
        for row in rows[(top + 1)..<bottom] {
            guard row.first == "│", row.last == "│", row.count >= 2 else { return unknown }
            let value = row.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { draft.append(value) }
        }
        return draft.isEmpty ? .empty(placeholder: nil) : .text(draft.joined(separator: "\n"))
    }

    /// A floating dialog can leave transcript text visible on both sides
    /// of its title. Amp draws Markdown tables with the same rounded corners.
    private static func hasOverlay(in history: ArraySlice<String>) -> Bool {
        for index in history.indices {
            let line = history[index]
            var remainder = line[...]
            while let start = remainder.range(of: "╭─") {
                let inside = line.index(after: start.lowerBound)
                guard let edge = line[inside...].range(of: "─╮") else { break }
                let prefix = line[..<start.lowerBound]
                let border = line[inside..<line.index(before: edge.upperBound)]
                guard isTable(border: border, prefix: prefix, rows: history[(index + 1)...]) else { return true }
                remainder = line[edge.upperBound...]
            }
        }
        return false
    }

    /// Match the divider and bottom at the same inset and column junctions,
    /// including a one-column table. The transcript scrollbar may follow them.
    private static func isTable(border: Substring, prefix: Substring, rows: ArraySlice<String>) -> Bool {
        guard border.allSatisfy({ $0 == "─" || $0 == "┬" }) else { return false }
        let divider = prefix + "├" + border.replacingOccurrences(of: "┬", with: "┼") + "┤"
        let bottom = prefix + "╰" + border.replacingOccurrences(of: "┬", with: "┴") + "╯"
        let cell = prefix + "│"
        var sawDivider = false
        for row in rows {
            if row.hasPrefix(bottom) { return sawDivider }
            if row.hasPrefix(divider) { sawDivider = true }
            else if !row.hasPrefix(cell) { return false }
        }
        // The viewport can cut off the lower rows of a tall table.
        return sawDivider
    }
}
