import Foundation
import Testing

@testable import Heeler

@Suite("Input box state detector")
struct InputBoxStateDetectorTests {
    static let claudeEmpty = [
        "claude-01-ready", "claude-15-c9-enterplanmode", "claude-21-c6-after", "claude-23-c7-after-esc",
        "claude-25-c8-after-digit3", "claude-29-c3-after-immediate",
    ]
    static let codexEmpty = ["codex-00-ready", "codex-03-x2-after-esc", "codex-11-x4-after-skip"]
    static let codexPlanPrompt = "codex-19-x3-implement-plan"
    static let dialogScreens = ScreenFixture.all.filter {
        !claudeEmpty.contains($0) && !codexEmpty.contains($0) && $0 != codexPlanPrompt
    }

    private static let cursor = SGR.reverse + " " + SGR.reset

    private func state(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
    }

    @Test("Claude's empty box", arguments: claudeEmpty)
    func claudeEmptyBox(stem: String) throws {
        #expect(try state(stem) == .empty(placeholder: nil))
    }

    @Test("Codex's empty composer", arguments: codexEmpty)
    func codexEmptyComposer(stem: String) throws {
        #expect(try state(stem) == .empty(placeholder: "Ask Codex to do anything"))
    }

    @Test("A dialog in place of the box", arguments: dialogScreens)
    func dialog(stem: String) throws {
        #expect(try state(stem) == .dialog(title: nil))
    }

    @Test("Codex's plan selector is a dialog named by its title")
    func codexPlanPromptIsNamed() throws {
        #expect(try state(Self.codexPlanPrompt) == .dialog(title: "Implement this plan?"))
    }

    @Test("Only an empty box is sendable")
    func sendable() {
        #expect(InputBoxState.empty(placeholder: nil).isSendable)
        #expect(!InputBoxState.text("draft").isSendable)
        #expect(!InputBoxState.dialog(title: nil).isSendable)
        #expect(!InputBoxState.unknown("why").isSendable)
    }

    @Test("Oh My Pi: an approval resting on the band is a dialog, with or without a draft", arguments: [
        "omp-23-approval-a-ctrlq-early", "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc",
    ])
    func ompApprovalWithComposerBelowIsDialog(stem: String) throws {
        #expect(try state(stem) == .dialog(title: nil))
    }

    @Test("Oh My Pi: the plan review is a dialog")
    func ompPlanReviewIsDialog() throws {
        #expect(try state("omp-31-plan-review") == .dialog(title: nil))
    }

    /// Every Grok Build card holds a send as a dialog, the ones Heeler
    /// answers and the ones it leaves to the terminal alike.
    @Test("Grok Build: a card in the composer's place is a dialog", arguments: [
        "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-23-rewind-confirm", "grok-25-fork-question",
    ])
    func grokCardsReadAsDialogs(stem: String) throws {
        #expect(try state(stem) == .dialog(title: nil))
    }

    // MARK: Claude, synthetic until captured

    /// Claude's box between its rules, with the mode line under it.
    private func claude(_ inputRows: [String], below: [String] = []) -> InputBoxState {
        let rows =
            ["⏺ Done.", "", SGR.claudeRule(60)] + inputRows + [SGR.claudeRule(60)] + below
            + ["  " + SGR.claudeInactive + "⏸ manual mode on" + SGR.reset]
        return InputBoxStateDetector.detect(ScreenFixture.synthetic(rows), program: .claude)
    }

    @Test("Claude: typed text, around or before the cursor (synthetic)")
    func claudeText() {
        #expect(claude(["❯\u{00A0}fix the tests" + Self.cursor]) == .text("fix the tests"))
        #expect(claude(["❯\u{00A0}fix " + SGR.reverse + "t" + SGR.reset + "he tests"]) == .text("fix the tests"))
        #expect(claude(["❯\u{00A0}first line", "  second line" + Self.cursor]) == .text("first line\nsecond line"))
    }

    @Test("Claude: a placeholder is empty, except the queued-message edit hint (synthetic)")
    func claudePlaceholder() {
        func hint(_ text: String) -> String {
            "❯\u{00A0}" + SGR.reverse + String(text.prefix(1)) + SGR.reset + SGR.dim + String(text.dropFirst()) + SGR.reset
        }
        #expect(claude([hint("Try \"fix lint errors\"")]) == .empty(placeholder: "Try \"fix lint errors\""))
        #expect(
            claude([hint("Press up to edit queued messages")])
                == .empty(placeholder: "Press up to edit queued messages"))
        // Enter would edit the selected queued message instead of sending.
        #expect(
            claude([hint("Press Enter to edit the selected message")])
                == .overlay("Press Enter to edit the selected message"))
        #expect(claude([hint("Something new")]) == .empty(placeholder: "Something new"))
    }

    /// After a turn Claude may fill the empty box with a prompt suggestion:
    /// any text, dim like a placeholder, which typing replaces. Claude Code
    /// 2.1.311 draws it dim with no color in every theme, with no cursor
    /// cell while the pane is unfocused (live, 2026-10-27).
    @Test("Claude: a prompt suggestion is an empty box (synthetic)")
    func claudePromptSuggestion() {
        let suggestion = "draft the email to the partner team"
        #expect(
            claude(["❯\u{00A0}" + SGR.reset + SGR.dim + suggestion + SGR.reset])
                == .empty(placeholder: suggestion))
        #expect(
            claude(["❯\u{00A0}" + SGR.reverse + "d" + SGR.reset + SGR.dim + suggestion.dropFirst() + SGR.reset])
                == .empty(placeholder: suggestion))
    }

    @Test("Claude: shell mode, empty or with a command (synthetic)")
    func claudeShellMode() {
        #expect(claude(["!\u{00A0}ls -la" + Self.cursor]) == .shellMode("ls -la"))
        #expect(claude(["!\u{00A0}" + Self.cursor]) == .shellMode(""))
    }

    @Test("Claude: suggestions under an empty box (synthetic)")
    func claudeSuggestions() {
        let row = "  /compact     Clear conversation history but keep a summary"
        #expect(claude(["❯\u{00A0}" + Self.cursor], below: [row]) == .overlay(row.trimmingCharacters(in: .whitespaces)))
    }

    @Test("Claude: a past prompt on its background is not the box (synthetic)")
    func claudeHistoryPrompt() {
        let history = SGR.bg(55, 55, 55) + "❯ fix the tests" + SGR.reset
        #expect(claude([history]) == .unknown("Claude's input box is not on screen."))
        let screen = ScreenFixture.synthetic(["⏺ Working on it…", "", "  ⎿  Running tests"])
        #expect(InputBoxStateDetector.detect(screen, program: .claude) == .unknown("Claude's input box is not on screen."))
    }

    // MARK: Codex, synthetic until captured

    /// Codex's composer rows, a blank row, `below`, and the footer.
    private func codex(_ rows: [String], above: [String] = [], below: [String] = []) -> InputBoxState {
        let screen = ScreenFixture.synthetic(
            ["• Done.", ""] + above + rows + [""] + below + ["  " + SGR.bold + "? " + SGR.reset + "for shortcuts"])
        return InputBoxStateDetector.detect(screen, program: .codex)
    }

    private static let prompt = SGR.bold + "›" + SGR.reset + " "

    @Test("Codex: a draft, on one row or wrapped (synthetic)")
    func codexText() {
        #expect(codex([Self.prompt + "fix the tests"]) == .text("fix the tests"))
        #expect(codex([Self.prompt + "first line", "  second line"]) == .text("first line\nsecond line"))
    }

    @Test("Codex: placeholders, including one cut short (synthetic)")
    func codexPlaceholder() {
        func placeholder(_ text: String) -> String { Self.prompt + SGR.dim + text + SGR.reset }
        #expect(codex([placeholder("Ask a follow-up question")]) == .empty(placeholder: "Ask a follow-up question"))
        #expect(codex([placeholder("Ask Codex to do a…")]) == .empty(placeholder: "Ask Codex to do a…"))
        #expect(
            codex([placeholder("Something else")])
                == .unknown("The composer shows \u{201C}Something else\u{201D}, which Heeler does not know."))
    }

    @Test("Codex: shell mode and disabled input (synthetic)")
    func codexModes() {
        #expect(codex([SGR.bold + SGR.fg(255, 100, 100) + "!" + SGR.reset + " ls"]) == .shellMode("ls"))
        #expect(codex([SGR.dim + "› Input disabled." + SGR.reset]) == .disabled("Input disabled."))
        let subAgent = "Viewing sub-agent \u{2014} direct input is disabled"
        #expect(codex([SGR.dim + "› " + subAgent + SGR.reset]) == .disabled(subAgent))
    }

    @Test("Codex: hints and popups around an empty composer (synthetic)")
    func codexOverlays() {
        let empty = Self.prompt + SGR.dim + "Ask Codex to do anything" + SGR.reset
        #expect(
            codex([empty], below: ["  esc again to edit previous message"])
                == .overlay("esc again to edit previous message"))
        #expect(
            codex([empty], above: ["  /model    choose what model to use", "  /review   review my changes", ""])
                == .overlay("/review   review my changes"))
    }

    @Test("Codex: no composer on screen (synthetic)")
    func codexMissing() {
        let screen = ScreenFixture.synthetic([
            "• Working (3s • esc to interrupt)", "", SGR.bold + SGR.dim + "›" + SGR.reset + " an earlier prompt",
        ])
        #expect(InputBoxStateDetector.detect(screen, program: .codex) == .unknown("Codex's composer is not on screen."))
    }
}
