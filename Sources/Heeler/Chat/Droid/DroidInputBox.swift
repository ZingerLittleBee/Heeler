import Foundation

enum DroidInputBox {
    static let working = String(localized: "Wait for Droid to finish this turn before sending another message.")
    private static let openComposer = String(localized: "Open Droid's message box in the terminal to send a message.")

    static func read(_ screen: ANSIScreen) -> InputBoxState {
        let rows = screen.rows.map(\.trimmedText)
        guard let bottom = rows.lastIndex(where: { border($0, left: "╰", right: "╯") }),
              let top = rows[..<bottom].lastIndex(where: { border($0, left: "╭", right: "╮") }),
              bottom > top + 1, rows[top].count == rows[bottom].count
        else { return .noComposer(openComposer) }

        var draft: [String] = []
        for index in (top + 1)..<bottom {
            let row = rows[index]
            let prefix = index == top + 1 ? "│ > " : "│ "
            guard row.hasPrefix(prefix), row.hasSuffix("│") else { return .noComposer(openComposer) }
            let text = row.dropFirst(prefix.count).dropLast().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { draft.append(text) }
        }
        // Menus can leave the input frame on screen and replace the status footer.
        let footer = rows[(bottom + 1)...].filter { !$0.isEmpty }
        guard footer.count == 1, let status = footer.first,
              status.contains("MCP "), status.contains("| IDE ") || status.hasSuffix("| TMUX ⧉") || status.hasSuffix("| GHOSTTY ᗣ") else { return .noComposer(openComposer) }
        // The steering hint and the stop instruction appear together during a turn.
        if draft.first?.hasPrefix("Enter to steer") == true,
           rows[max(0, top - 6)..<top].contains(where: { $0.hasSuffix("(Press ESC to stop)") }) {
            return .disabled(working)
        }
        if !draft.isEmpty { return .text(draft.joined(separator: "\n")) }
        return .empty(placeholder: nil)
    }

    static func stop(_ context: ChatStopContext) -> ChatStopVerdict {
        guard context.activity == .working, read(context.screen) == .disabled(working) else {
            return .refuse(String(localized: "Open the terminal to stop Droid. Its interrupt prompt is not visible."))
        }
        return .press
    }

    private static func border(_ row: String, left: Character, right: Character) -> Bool {
        row.count >= 4 && row.first == left && row.last == right && row.dropFirst().dropLast().allSatisfy { $0 == "─" }
    }
}
