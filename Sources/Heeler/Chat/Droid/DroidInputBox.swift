import Foundation

enum DroidInputBox {
    static let working = String(localized: "Wait for Droid to finish this turn before sending another message.")
    private static let openComposer = String(localized: "Open Droid's message box in the terminal to send a message.")

    private enum Reading {
        case held(InputBoxState)
        case composer(rows: [String], columns: Int, cursor: (row: Int, column: Int)?)
    }

    static func read(_ screen: ANSIScreen) -> InputBoxState {
        switch inspect(screen) {
        case .held(let state): return state
        case .composer(let rows, _, let cursor):
            let text = rows.joined(separator: "\n")
            if !text.isEmpty { return .text(text) }
            if let cursor, cursor.column > 0 { return .text(String(repeating: " ", count: cursor.column)) }
            return .empty(placeholder: nil)
        }
    }

    private static func inspect(_ screen: ANSIScreen) -> Reading {
        let rows = screen.rows.map(\.trimmedText)
        if let reason = terminalGuidance(rows) { return .held(.noComposer(reason)) }
        guard let bottom = rows.lastIndex(where: { border($0, left: "╰", right: "╯") }),
              let top = rows[..<bottom].lastIndex(where: {
                  border($0.replacingOccurrences(of: "╭── Spec ", with: "╭───────"), left: "╭", right: "╮")
              }),
              bottom > top + 1, rows[top].count == rows[bottom].count
        else { return .held(.noComposer(openComposer)) }

        var draft: [String] = []
        var cursor: (row: Int, column: Int)?
        for index in (top + 1)..<bottom {
            let source = screen.rows[index]
            let row = source.text.trimmingCharacters(in: .whitespaces)
            let prefix = index == top + 1 ? "│ > " : "│   "
            guard row.hasPrefix(prefix), row.hasSuffix("│") else { return .held(.noComposer(openComposer)) }
            if let caret = source.runs.first(where: { $0.style.isReverse }) {
                cursor = (draft.count, caret.column - (source.indent ?? 0) - prefix.count)
            }
            draft.append(withoutFramePadding(row.dropFirst(prefix.count).dropLast()))
        }
        // Menus can leave the input frame on screen and replace the status footer.
        let footer = rows[(bottom + 1)...].filter { !$0.isEmpty }
        guard let status = footer.last,
              footer.count == 1 || (footer.count == 2 && footer[0].wholeMatch(of: /\(\d+\) processes? running \(press ↓ to view\)/) != nil),
              (status.contains("MCP ") && (status.contains("| IDE ") || status.hasSuffix("| TMUX ⧉") || status.hasSuffix("| GHOSTTY ᗣ")))
                || ["? for help TMUX ⧉", "? for help GHOSTTY ᗣ", "? for help IDE ◌"]
                    .contains(status.replacing(#/^\[⏱ [0-9hms ]+\] /#, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")) else {
            return .held(.noComposer(openComposer))
        }
        // The steering hint and the stop instruction appear together during a turn.
        if draft.first?.hasPrefix("Enter to steer") == true,
           rows[max(0, top - 6)..<top].contains(where: { $0.hasSuffix("(Press ESC to stop)") }) {
            return .held(.disabled(working))
        }
        // Droid 1.21.1 wraps ten cells inside the frame width, at every pane size.
        return .composer(rows: draft, columns: rows[top].count - 10, cursor: cursor)
    }

    private static func withoutFramePadding(_ row: Substring) -> String {
        guard let last = row.lastIndex(where: { $0 != " " }) else { return "" }
        return String(row[...last])
    }

    /// Identify only the active page. Old tool output can mention any menu.
    static func terminalGuidance(_ rows: [String]) -> String? {
        let visible = rows.filter { !$0.isEmpty }
        guard let footer = visible.last else { return nil }
        let hint = footer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if visible.suffix(5).contains("Please login with your Factory account to continue.") {
            return String(localized: "Sign in to Factory in this terminal. Chat will check for the session after sign-in.")
        }
        if hint == "Enter to confirm · Esc to exit" {
            return String(localized: "Review the full folder path and choose whether to trust it in this Droid terminal.")
        }
        if hint == "Type search ↑↓ focus list Enter select Tab switch Esc cancel" {
            return String(localized: "Finish choosing the model in the Droid terminal.")
        }
        if hint == "↑↓ navigate Space toggle Enter details Tab switch tabs Esc close" {
            return String(localized: "Close the skills picker in the Droid terminal to return to Chat.")
        }
        if hint == "↑↓ navigate Enter select Ctrl+R rename Esc cancel" {
            return String(localized: "Open Mission Control in the Droid terminal to view or manage missions.")
        }
        if hint == "Enter send ⇧Enter newline", visible.suffix(8).contains(where: { $0.hasPrefix("── Side chat") }) {
            return String(localized: "Continue the side chat in the Droid terminal. Its messages stay separate from the main session.")
        }
        if let bottom = visible.lastIndex(where: { border($0, left: "╰", right: "╯") }), bottom > 1 {
            if visible[bottom - 1].hasPrefix("│ !") || visible[bottom - 1].hasPrefix("│  !") {
                return String(localized: "Exit Bash mode in the Droid terminal to send a Chat message.")
            }
            if visible[bottom - 1].hasPrefix("│ > /"), visible.dropFirst(bottom + 1).contains(where: { $0.hasPrefix("/") }) {
                return String(localized: "Finish choosing a slash command in the Droid terminal.")
            }
        }
        return nil
    }

    static func isEmptySpec(_ screen: ANSIScreen) -> Bool {
        guard case .empty = read(screen) else { return false }
        return isSpec(screen)
    }

    static func isSpec(_ screen: ANSIScreen) -> Bool {
        screen.rows.last(where: { $0.trimmedText.hasPrefix("╭") })?.trimmedText.hasPrefix("╭── Spec ") == true
    }

    static func showsPaste(_ text: String, on screen: ANSIScreen) -> Bool {
        guard !text.isEmpty, case .composer(let visible, let columns, let cursor) = inspect(screen), columns > 0 else { return false }
        let expected = wrappedRows(text, columns: columns)
        guard expected.map({ withoutFramePadding($0[...]) }) == visible else { return false }
        // Captures that retain Droid's reverse-video caret distinguish trailing input spaces from frame padding.
        guard let cursor, let last = expected.last else { return true }
        return cursor.row == expected.count - 1 && cursor.column == TerminalCellWidth.width(of: last)
    }

    private static func wrappedRows(_ text: String, columns: Int) -> [String] {
        var rows: [String] = []
        var row = ""
        var used = 0
        func finishRow() {
            rows.append(row)
            row = ""
            used = 0
        }
        func append(_ character: Character) {
            let width = TerminalCellWidth.width(of: character)
            if used + width > columns { finishRow() }
            row.append(character)
            used += width
        }

        // Droid expands each pasted tab to four spaces, keeps explicit blank lines,
        // wraps whole words and splits a word wider than the field at cell boundaries.
        for line in text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n") {
            for (index, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { append(" ") }
                let width = TerminalCellWidth.width(of: word)
                if width <= columns, used + width > columns { finishRow() }
                for character in word { append(character) }
            }
            finishRow()
        }
        return rows
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

/// Frozen before preflight. Every write must still belong to this instance,
/// foreground process and Factory conversation, even after a writer waited.
struct DroidSendVerification: Sendable {
    let target: DroidDialogTarget
    let readTarget: @Sendable () async throws -> DroidDialogTarget?
    let readScreen: @MainActor @Sendable () async throws -> ANSIScreen
    let requiresSpec: Bool
    var program: ChatProgram = .droid

    @MainActor func refusal(staged text: String? = nil) async -> ComposerRefusal? {
        let held = program == .devin ? String(localized: "Check this Devin session and its message field before sending.") : String(localized: "Check this Droid session and its message box before sending.")
        let afterPaste = program == .devin
            ? String(localized: "Devin’s session or input changed. Check the terminal before sending again.")
            : String(localized: "The Droid session or its input changed. Check the text in the terminal before sending again.")
        guard !Task.isCancelled, (try? await readTarget()) == target,
              let screen = try? await readScreen(), !Task.isCancelled, !requiresSpec || (program == .devin ? DevinInputBox.isPlan(screen) : DroidInputBox.isSpec(screen))
        else { return text == nil ? .inputNotReady(held) : .notSubmitted(afterPaste) }
        if let text {
            let matches = program == .devin ? DevinInputBox.showsPaste(text, on: screen) : DroidInputBox.showsPaste(text, on: screen)
            return matches ? nil : .notSubmitted(afterPaste)
        }
        let box = program == .devin ? DevinInputBox.read(screen) : DroidInputBox.read(screen)
        if case .empty = box { return nil }
        return .inputNotReady(box.holdReason(for: program))
    }
}
