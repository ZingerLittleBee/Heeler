import Foundation

enum DroidInputBox {
    static let working = String(localized: "Wait for Droid to finish this turn before sending another message.")
    private static let openComposer = String(localized: "Open Droid's message box in the terminal to send a message.")

    static func read(_ screen: ANSIScreen) -> InputBoxState {
        let rows = screen.rows.map(\.trimmedText)
        if let reason = terminalGuidance(rows) { return .noComposer(reason) }
        guard let bottom = rows.lastIndex(where: { border($0, left: "╰", right: "╯") }),
              let top = rows[..<bottom].lastIndex(where: {
                  border($0.replacingOccurrences(of: "╭── Spec ", with: "╭───────"), left: "╭", right: "╮")
              }),
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
        guard let status = footer.last,
              footer.count == 1 || (footer.count == 2 && footer[0].wholeMatch(of: /\(\d+\) processes? running \(press ↓ to view\)/) != nil),
              (status.contains("MCP ") && (status.contains("| IDE ") || status.hasSuffix("| TMUX ⧉") || status.hasSuffix("| GHOSTTY ᗣ")))
                || ["? for help TMUX ⧉", "? for help GHOSTTY ᗣ", "? for help IDE ◌"]
                    .contains(status.replacing(#/^\[⏱ [0-9hms ]+\] /#, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")) else {
            return .noComposer(openComposer)
        }
        // The steering hint and the stop instruction appear together during a turn.
        if draft.first?.hasPrefix("Enter to steer") == true,
           rows[max(0, top - 6)..<top].contains(where: { $0.hasSuffix("(Press ESC to stop)") }) {
            return .disabled(working)
        }
        if !draft.isEmpty { return .text(draft.joined(separator: "\n")) }
        return .empty(placeholder: nil)
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

    static func showsPaste(_ displayed: String, text: String) -> Bool {
        // ChatSendRules adds one trailing space, indistinguishable from the
        // input frame's own padding. It is never part of the user's draft.
        let payload = text.last == " " ? text.dropLast() : text[...]
        if displayed == payload { return true }
        // The terminal wraps at cell boundaries and pads rows with spaces.
        // Consume each displayed fragment in order, including word wraps.
        var remaining = payload
        for row in displayed.components(separatedBy: "\n") {
            if !remaining.hasPrefix(row), remaining.first == " " || remaining.first == "\n" { remaining.removeFirst() }
            guard !row.isEmpty, remaining.hasPrefix(row) else { return false }
            remaining = remaining.dropFirst(row.count)
        }
        return remaining.isEmpty
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

    @MainActor func refusal(staged text: String? = nil) async -> ComposerRefusal? {
        let held = String(localized: "Check this Droid session and its message box before sending.")
        let afterPaste = String(localized: "The Droid session or its input changed. Check the text in the terminal before sending again.")
        guard !Task.isCancelled, (try? await readTarget()) == target,
              let screen = try? await readScreen(), !Task.isCancelled, !requiresSpec || DroidInputBox.isSpec(screen)
        else { return text == nil ? .inputNotReady(held) : .notSubmitted(afterPaste) }
        let box = DroidInputBox.read(screen)
        if let text {
            if case .text(let visible) = box, DroidInputBox.showsPaste(visible, text: text) { return nil }
            return .notSubmitted(afterPaste)
        }
        if case .empty = box { return nil }
        return .inputNotReady(box.holdReason(for: .droid))
    }
}
