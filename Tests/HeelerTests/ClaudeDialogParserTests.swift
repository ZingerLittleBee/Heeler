import Foundation
import Testing

@testable import Heeler

@Suite("Claude dialog parser")
struct ClaudeDialogParserTests {
    private static let probeDirectory = "/private/tmp/heeler-tmp-chat2/probe-claude"

    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = ClaudeDialogParser.parse(try ScreenFixture.screen(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    @Test("A Bash permission dialog")
    func bash() throws {
        let dialog = try dialog("claude-02-c1-bash-blocked")
        #expect(dialog.kind == .claudeBash)
        #expect(dialog.program == .claude)
        #expect(dialog.title == "Bash command")
        #expect(dialog.sourceSuffix == nil)
        #expect(dialog.positionLabel == nil)
        #expect(dialog.body == ["Create empty file c1.txt", "touch c1.txt", "Do you want to proceed?"])
        #expect(
            dialog.options.map(\.label) == [
                "Yes", "Yes, and always allow access to \(Self.probeDirectory) from this project",
                "Yes, and switch to auto mode", "No",
            ])
        #expect(dialog.options.map(\.number) == [1, 2, 3, 4])
        #expect(dialog.options.map(\.ordinal) == [1, 2, 3, 4])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .approveModeSwitch, .decline])
        #expect(dialog.options[2].detail == "auto mode handles these prompts for you")
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.subject.command == "touch c1.txt")
        #expect(dialog.subject.commandDescription == "Create empty file c1.txt")
        #expect(dialog.rows == 11..<25)
    }

    @Test(
        "Bash dialogs from every probe name their command",
        arguments: [
            "claude-03-c1-focus-no", "claude-03-bash-touch-permission", "claude-26-c10-subagent-ask",
            "claude-27-n1-narrow-bash", "claude-28-n1-narrow-bash-later", "claude-30-par-first",
            "claude-31-par-second",
        ])
    func bashCommands(stem: String) throws {
        let expected: [String: (command: String, description: String)] = [
            "claude-03-c1-focus-no": ("touch c1.txt", "Create empty file c1.txt"),
            "claude-03-bash-touch-permission": ("touch heeler-probe.txt", "Create empty probe file"),
            "claude-26-c10-subagent-ask": ("touch sub.txt && echo ok", "Create empty file sub.txt"),
            "claude-27-n1-narrow-bash": ("touch n1.txt", "Create empty file n1.txt"),
            "claude-28-n1-narrow-bash-later": ("touch n1.txt", "Create empty file n1.txt"),
            "claude-30-par-first": ("touch par-a.txt", "Create empty file par-a.txt"),
            "claude-31-par-second": ("touch par-b.txt", "Create empty file par-b.txt"),
        ]
        let want = try #require(expected[stem])
        let dialog = try dialog(stem)
        #expect(dialog.kind == .claudeBash)
        #expect(dialog.title == "Bash command")
        #expect(dialog.subject.command == want.command)
        #expect(dialog.subject.commandDescription == want.description)
        #expect(dialog.body == [want.description, want.command, "Do you want to proceed?"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .approveModeSwitch, .decline])
    }

    @Test(
        "A 40-column redraw: residue after No, a path cut mid-word, a cut description",
        arguments: [
            "claude-27-n1-narrow-bash", "claude-28-n1-narrow-bash-later", "claude-30-par-first",
            "claude-31-par-second",
        ])
    func narrowRedraw(stem: String) throws {
        let dialog = try dialog(stem)
        // `4. No` is followed by a stale grey `r you`.
        #expect(dialog.options[3].label == "No")
        #expect(dialog.options[3].detail == nil)
        // The path breaks at the box's edge: `…/prob` + `e-claude`.
        #expect(dialog.options[1].label == "Yes, and always allow access to \(Self.probeDirectory) from this project")
        #expect(dialog.options[2].label == "Yes, and switch to auto mode")
        #expect(dialog.options[2].detail == "auto mode handles these prompts")
    }

    @Test("The arrow keys move focus without changing the dialog")
    func focusMoves() throws {
        let start = try dialog("claude-02-c1-bash-blocked")
        let onNo = try dialog("claude-03-c1-focus-no")
        #expect(onNo.focus == DialogFocusState(focusedOrdinal: 4))
        #expect(onNo.options.map(\.isFocused) == [false, false, false, true])
        #expect(onNo.fingerprint == start.fingerprint)
    }

    @Test("Tab turns the No row into a note field")
    func declineNoteField() throws {
        let start = try dialog("claude-02-c1-bash-blocked")
        let empty = try dialog("claude-04-c1-tab-on-no")
        #expect(empty.options[3].label == "No")
        #expect(empty.options[3].role == .decline)
        #expect(empty.options[3].input == .placeholder("and tell Claude what to do differently"))
        #expect(empty.focus == DialogFocusState(focusedOrdinal: 4, feedbackOrdinal: 4))

        let note = "Do not create it; reply with the single word skipped"
        let typed = try dialog("claude-05-c1-pasted-feedback")
        #expect(typed.options[3].label == "No")
        #expect(typed.options[3].input == .text(note))
        #expect(typed.focus == DialogFocusState(focusedOrdinal: 4, inputText: note, feedbackOrdinal: 4))
        #expect(empty.fingerprint == start.fingerprint)
        #expect(typed.fingerprint == start.fingerprint)
    }

    @Test("Tab turns the Yes row into a note field")
    func approveNoteField() throws {
        let empty = try dialog("claude-06-c2-tab-on-yes")
        #expect(empty.options[0].label == "Yes")
        #expect(empty.options[0].role == .approve)
        #expect(empty.options[0].input == .placeholder("and tell Claude what to do next"))
        #expect(empty.focus == DialogFocusState(focusedOrdinal: 1, feedbackOrdinal: 1))

        let typed = try dialog("claude-07-c2-pasted")
        #expect(typed.focus.inputText == "after it succeeds, reply with the single word created")
        #expect(typed.focus.feedbackOrdinal == 1)
        #expect(typed.fingerprint == empty.fingerprint)
    }

    @Test("A multi-select question page")
    func multiSelectQuestion() throws {
        let dialog = try dialog("claude-08-c4-auq-q1")
        #expect(dialog.kind == .claudeQuestion)
        #expect(dialog.title == "Which colors?")
        #expect(dialog.body.isEmpty)
        #expect(dialog.progress == "Colors")
        #expect(dialog.subject.question == "Which colors?")
        #expect(dialog.subject.questionHeaders == ["Colors", "Size"])
        #expect(
            dialog.options.map(\.label) == ["Red", "Green", "Blue", "Type something", "Next", "Chat about this"])
        #expect(dialog.options.map(\.number) == [1, 2, 3, 4, nil, 5])
        #expect(dialog.options.map(\.ordinal) == [1, 2, 3, 4, 5, 6])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .answer, .otherText, .next, .chat])
        #expect(dialog.options.map(\.isChecked) == [false, false, false, false, nil, nil])
        #expect(dialog.options.map(\.detail) == ["Red", "Green", "Blue", nil, nil, nil])
        #expect(dialog.options[3].input == .placeholder("Type something"))
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 23..<40)
    }

    @Test("Digits check answers in place; arrows reach Next")
    func multiSelectChecks() throws {
        let start = try dialog("claude-08-c4-auq-q1")
        let toggled = try dialog("claude-09-c4-toggled")
        #expect(toggled.options.map(\.isChecked) == [true, false, true, false, nil, nil])
        #expect(toggled.focus == DialogFocusState(focusedOrdinal: 1, checked: [1, 3]))

        let onNext = try dialog("claude-10-c4-focus-next")
        #expect(onNext.options[4].isFocused)
        #expect(onNext.focus == DialogFocusState(focusedOrdinal: 5, checked: [1, 3]))
        #expect(toggled.fingerprint == start.fingerprint)
        #expect(onNext.fingerprint == start.fingerprint)
    }

    @Test("A single-select page and its Other row as the user types into it")
    func singleSelectQuestion() throws {
        let page = try dialog("claude-11-c4-q2")
        #expect(page.kind == .claudeQuestion)
        #expect(page.title == "Which size?")
        #expect(page.progress == "Size")
        #expect(page.options.map(\.label) == ["Small", "Large", "Type something.", "Chat about this"])
        #expect(page.options.map(\.number) == [1, 2, 3, 4])
        #expect(page.options.map(\.role) == [.answer, .answer, .otherText, .chat])
        #expect(page.options.map(\.isChecked) == [nil, nil, nil, nil])
        #expect(page.options[2].input == .placeholder("Type something."))
        #expect(page.focus == DialogFocusState(focusedOrdinal: 1))

        let focused = try dialog("claude-12-c4-q2-digit3")
        #expect(focused.focus == DialogFocusState(focusedOrdinal: 3))
        #expect(focused.options[2].input == .placeholder("Type something."))

        let typed = try dialog("claude-13-c4-q2-pasted")
        #expect(typed.options[2].label == "Type something.")
        #expect(typed.options[2].input == .text("Medium"))
        #expect(typed.focus == DialogFocusState(focusedOrdinal: 3, inputText: "Medium"))
        #expect(focused.fingerprint == page.fingerprint)
        #expect(typed.fingerprint == page.fingerprint)
    }

    @Test("The review page after the last question")
    func reviewPage() throws {
        let dialog = try dialog("claude-14-c4-review")
        #expect(dialog.kind == .claudeQuestionReview)
        #expect(dialog.title == "Review your answers")
        #expect(dialog.progress == "Review your answers")
        #expect(
            dialog.body == [
                "● Which colors?", "→ Red, Blue", "● Which size?", "→ Medium", "Ready to submit your answers?",
            ])
        #expect(dialog.options.map(\.label) == ["Submit answers", "Cancel"])
        #expect(dialog.options.map(\.role) == [.submit, .cancel])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.subject.questionHeaders == ["Colors", "Size"])
        #expect(
            dialog.subject.reviewAnswers == [
                .init(question: "Which colors?", answer: "Red, Blue"), .init(question: "Which size?", answer: "Medium"),
            ])
    }

    @Test("A plan, whose numbered steps are not options")
    func plan() throws {
        let dialog = try dialog("claude-16-c6-exitplan-1")
        #expect(dialog.kind == .claudePlan)
        #expect(dialog.title == "Ready to code?")
        #expect(
            dialog.body == [
                "1. Create p.txt in \(Self.probeDirectory) containing the single word \"probe\".",
                "2. Verify by reading p.txt back and confirming its content is \"probe\".",
                "Claude has written up a plan and is ready to execute. Would you like to proceed?",
            ])
        #expect(
            dialog.options.map(\.label) == [
                "Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change",
            ])
        #expect(dialog.options.map(\.number) == [1, 2, 3])
        #expect(dialog.options.map(\.role) == [.approveModeSwitch, .approve, .otherText])
        #expect(dialog.options[2].detail == "shift+tab to approve with this feedback")
        #expect(dialog.options[2].input == .placeholder("Tell Claude what to change"))
        #expect(dialog.subject.planFilePath == "~/.claude/plans/spicy-dazzling-crescent.md")
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 4..<40)
    }

    @Test("The plan's feedback row as the user types into it")
    func planFeedbackRow() throws {
        let start = try dialog("claude-16-c6-exitplan-1")
        let focused = try dialog("claude-17-c6-digit3")
        #expect(focused.focus == DialogFocusState(focusedOrdinal: 3))

        let typed = try dialog("claude-18-c6-pasted")
        #expect(typed.options[2].label == "Tell Claude what to change")
        #expect(typed.options[2].input == .text("Name the file q.txt instead"))
        #expect(typed.focus == DialogFocusState(focusedOrdinal: 3, inputText: "Name the file q.txt instead"))
        #expect(focused.fingerprint == start.fingerprint)
        #expect(typed.fingerprint == start.fingerprint)

        let revised = try dialog("claude-20-c6-pasted-2")
        #expect(revised.body.first == "1. Create q.txt in \(Self.probeDirectory) containing the single word \"probe\".")
        #expect(revised.focus.inputText == "Also reply with the word done at the end")
    }

    @Test("A file edit, with the session option's key hint split off")
    func fileEdit() throws {
        let dialog = try dialog("claude-22-c7-edit")
        #expect(dialog.kind == .claudeFileEdit)
        #expect(dialog.title == "Edit file")
        #expect(dialog.subject.filePath == "q.txt")
        #expect(dialog.body == ["q.txt", "1 -probe", "1 +probe2", "Do you want to make this edit to q.txt?"])
        #expect(
            dialog.options.map(\.label) == [
                "Yes",
                "Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session",
                "No",
            ])
        #expect(dialog.options.map(\.shortcut) == [nil, "shift+tab", nil])
        #expect(dialog.options.map(\.role) == [.approve, .approveModeSwitch, .decline])
    }

    @Test("A web fetch, which has no footer")
    func webFetch() throws {
        let dialog = try dialog("claude-24-c8-webfetch")
        #expect(dialog.kind == .claudeFetch)
        #expect(dialog.title == "Fetch")
        #expect(
            dialog.body == [
                "Claude wants to fetch content from example.com", "url: https://example.com/",
                "prompt: What is the page title (the <title> text)?",
                "Do you want to allow Claude to fetch this content?",
            ])
        #expect(dialog.subject.url == "https://example.com/")
        #expect(dialog.subject.host == "example.com")
        #expect(dialog.subject.prompt == "What is the page title (the <title> text)?")
        #expect(
            dialog.options.map(\.label) == [
                "Yes", "Yes, and don't ask again for example.com", "No, and tell Claude what to do differently",
            ])
        #expect(dialog.options.map(\.shortcut) == [nil, nil, "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .decline])
        #expect(dialog.rows == 29..<40)
    }

    @Test("A subagent's request names the agent after the title")
    func subagentSuffix() throws {
        let dialog = try dialog("claude-26-c10-subagent-ask")
        #expect(dialog.title == "Bash command")
        #expect(dialog.sourceSuffix == "from the general-purpose agent")
        #expect(dialog.positionLabel == nil)
        #expect(dialog.options[2].detail == "auto mode handles these prompts for you")
    }

    @Test("The folder trust dialog at startup")
    func workspaceTrust() throws {
        let dialog = try dialog("claude-00-trust")
        #expect(dialog.kind == .claudeWorkspaceTrust)
        #expect(dialog.title == "Accessing workspace:")
        #expect(dialog.subject.workspacePath == Self.probeDirectory)
        #expect(dialog.body.first == Self.probeDirectory)
        #expect(dialog.body.last == "Claude Code'll be able to read, edit, and execute files here.")
        #expect(dialog.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(dialog.options.map(\.number) == [nil, nil])
        #expect(dialog.options.map(\.role) == [.exitProgram, .trust])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
    }

    @Test(
        "Screens with the input box show no dialog",
        arguments: [
            "claude-01-ready", "claude-15-c9-enterplanmode", "claude-21-c6-after", "claude-23-c7-after-esc",
            "claude-25-c8-after-digit3", "claude-29-c3-after-immediate",
        ])
    func inputBoxScreens(stem: String) throws {
        #expect(ClaudeDialogParser.parse(try ScreenFixture.screen(stem)) == DialogParseResult.none)
    }

    // MARK: Synthetic screens

    @Test("Numbered lines in a reply are not options (synthetic)")
    func replyNumbers() {
        let screen = ScreenFixture.synthetic([
            "⏺ Here is the plan:",
            "  1. Create the file",
            "  2. Verify it",
            "",
        ])
        #expect(ClaudeDialogParser.parse(screen) == DialogParseResult.none)
    }

    @Test("Default-colored text about cancelling is not a dialog footer (synthetic)")
    func plainCancelText() {
        let screen = ScreenFixture.synthetic([
            "⏺ Pick one:",
            " ❯ the first",
            "   the second",
            "",
            "Press Esc to cancel the run.",
        ])
        #expect(ClaudeDialogParser.parse(screen) == DialogParseResult.none)
    }

    @Test("A dialog Heeler does not know goes to the generic card (synthetic)")
    func unknownTitle() throws {
        let screen = ClaudeDialogRows.screen(
            title: "Tool use", body: ["1. Run the migration"], options: ["Yes", "No"])
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "Heeler does not know the dialog \u{201C}Tool use\u{201D}.")
        // The body's plain `1.` is not an option; the colored numbers are.
        #expect(excerpt.numbered == [1: "Yes", 2: "No"])
        #expect(excerpt.rows.first?.trimmedText.hasPrefix("───") == true)
        #expect(excerpt.rows.last?.trimmedText == "Esc to cancel · Tab to amend")
    }

    @Test("An unknown option label sends a known dialog to the generic card (synthetic)")
    func unknownLabel() throws {
        let screen = ClaudeDialogRows.screen(title: "Bash command", options: ["Yes", "Maybe later", "No"])
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "Option 2 reads \u{201C}Maybe later\u{201D}, which is not a label Heeler knows.")
        #expect(excerpt.numbered == [1: "Yes", 2: "Maybe later", 3: "No"])
    }

    @Test("A remapped key in the footer sends the dialog to the generic card (synthetic)")
    func reboundFooter() throws {
        let screen = ClaudeDialogRows.screen(
            title: "Bash command", options: ["Yes", "No"], footer: "Esc to cancel · ctrl+t to amend")
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason.contains("ctrl+t to amend"))
    }

    @Test("Options that do not start at 1 may be scrolled (synthetic)")
    func scrolledOptions() throws {
        let screen = ClaudeDialogRows.screen(title: "Bash command", options: ["Yes", "No"], firstNumber: 3)
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "The options do not start at 1, so the list may be scrolled.")
    }

    @Test("A dialog without Yes or No goes to the generic card (synthetic)")
    func missingDecline() throws {
        let screen = ClaudeDialogRows.screen(title: "Bash command", options: ["Yes", "Yes, and don't ask again"])
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "The dialog lacks a Yes or a No option.")
    }

    @Test("Moving focus keeps a generic excerpt's fingerprint (synthetic)")
    func genericFingerprint() throws {
        let first = ClaudeDialogRows.screen(title: "Tool use", options: ["Yes", "No"], focused: 1)
        let second = ClaudeDialogRows.screen(title: "Tool use", options: ["Yes", "No"], focused: 2)
        let other = ClaudeDialogRows.screen(title: "Tool use", options: ["Yes", "Never"], focused: 1)
        let firstExcerpt = try #require(ClaudeDialogParser.parse(first).excerpt)
        let secondExcerpt = try #require(ClaudeDialogParser.parse(second).excerpt)
        let otherExcerpt = try #require(ClaudeDialogParser.parse(other).excerpt)
        #expect(firstExcerpt.fingerprint == secondExcerpt.fingerprint)
        #expect(firstExcerpt.fingerprint != otherExcerpt.fingerprint)
    }

    @Test("Unnumbered options outside the trust dialog go to the generic card (synthetic)")
    func unnumberedOptions() throws {
        let screen = ScreenFixture.synthetic([
            SGR.claudeAccent + String(repeating: "─", count: 60) + SGR.reset,
            " " + SGR.bold + SGR.claudeAccent + "Enter plan mode?" + SGR.reset,
            "",
            " " + SGR.claudeAccent + "❯ Yes, enter plan mode" + SGR.reset,
            "   No, start implementing now",
            "",
            " " + SGR.claudeInactive + "Enter to confirm · Esc to cancel" + SGR.reset,
        ])
        let excerpt = try #require(ClaudeDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "The dialog's options are not numbered.")
        #expect(excerpt.numbered.isEmpty)
    }
}

/// Synthetic Claude dialogs in the dark theme's colors, laid out like the
/// captured Bash dialog.
enum ClaudeDialogRows {
    /// A dialog `width` columns wide. A label may hold `\r\n` and an indent
    /// to wrap onto the next row.
    static func screen(
        title: String, body: [String] = [], options: [String], focused: Int = 1, firstNumber: Int = 1,
        footer: String = "Esc to cancel · Tab to amend", width: Int = 60
    ) -> ANSIScreen {
        var rows = [
            SGR.reset + SGR.claudeAccent + String(repeating: "─", count: width) + SGR.reset,
            SGR.reset + " " + SGR.bold + SGR.claudeAccent + title + SGR.reset,
        ]
        rows += body.map { " " + $0 }
        rows.append(" Do you want to proceed?")
        for (index, label) in options.enumerated() {
            let number = "\(firstNumber + index). "
            if index + 1 == focused {
                rows.append(
                    SGR.reset + " " + SGR.claudeAccent + "❯ " + SGR.claudeInactive + number + SGR.claudeAccent + label
                        + SGR.reset)
            } else {
                rows.append(SGR.reset + "   " + SGR.claudeInactive + number + SGR.reset + label)
            }
        }
        rows += ["", SGR.reset + " " + SGR.claudeInactive + footer + SGR.reset]
        return ScreenFixture.synthetic(rows)
    }
}
