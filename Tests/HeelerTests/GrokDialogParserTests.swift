import Foundation
import Testing

@testable import Heeler

/// Grok Build's cards, read from Grok Build 1.0.62 captures and from
/// synthetic cards `GrokCardBuilder` lays out the way Grok does.
@Suite("Grok Build dialog parser")
struct GrokDialogParserTests {
    private static let reject = "No, reject (type to add feedback)"

    /// grok-12: the cursor starts on `Yes, proceed`. Chat offers the rule,
    /// the single approval and the reject, each by the digit Grok draws.
    @Test func readsTheCommandPermissionCard() throws {
        let dialog = try GrokCards.dialog("grok-12-permission-command")

        #expect(dialog.kind == .grokPermission)
        #expect(dialog.program == .grok)
        #expect(dialog.title == "Allow Command")
        #expect(dialog.subject.command == "chmod 644 README.md")
        #expect(dialog.subject.commandDescription == "Set README.md permissions to 644")
        #expect(dialog.options.map(\.label) == ["Always allow: chmod 644 README.md", "Yes, proceed", Self.reject])
        #expect(dialog.options.map(\.number) == [2, 3, 4])
        #expect(dialog.options.map(\.role) == [.approvePersistent, .approve, .decline])
        #expect(dialog.options.map(\.detail) == [nil, nil, "Ends the turn"])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 2))
        #expect(dialog.options.map(\.isFocused) == [false, true, false])
        #expect(dialog.rows == 33..<44)
        #expect(
            dialog.options[0].persistenceNote(program: .grok)
                == "Grok Build saves this rule for the project and won't ask again.")
    }

    /// grok-13: a compound command offers no rule, and the cursor starts on
    /// the second row.
    @Test func readsTheCompoundCommandCard() throws {
        let dialog = try GrokCards.dialog("grok-13-permission-compound")

        #expect(dialog.kind == .grokPermission)
        #expect(dialog.subject.command == #"chmod 600 README.md; echo "EXIT_CODE:$?"; ls -l README.md"#)
        #expect(dialog.subject.commandDescription == "Set README.md to mode 600 and show result")
        #expect(dialog.options.map(\.label) == ["Yes, proceed", Self.reject])
        #expect(dialog.options.map(\.number) == [2, 3])
        #expect(dialog.focus.focusedOrdinal == 1)
    }

    /// grok-14: an edit names its file in the description, and its
    /// persistent row lasts the session.
    @Test func readsTheEditPermissionCard() throws {
        let dialog = try GrokCards.dialog("grok-14-permission-edit")

        #expect(dialog.kind == .grokPermission)
        #expect(dialog.title == "Allow Edit")
        #expect(dialog.subject.filePath == "/Users/developer/scratch/cap-grok-a/proj/notes.txt")
        #expect(dialog.subject.command == nil)
        #expect(dialog.options.map(\.label) == ["Yes, allow all edits during this session", "Yes", Self.reject])
        #expect(dialog.options.map(\.number) == [2, 3, 4])
        #expect(dialog.options.map(\.role) == [.approvePersistent, .approve, .decline])
        #expect(dialog.focus.focusedOrdinal == 2)
        #expect(
            dialog.options[0].persistenceNote(program: .grok)
                == "Grok Build won't ask about edits again in this session.")
    }

    /// grok-35: the approval Grok asks before a subagent starts, at the
    /// phone's grid. `Yes, send once` approves this one subagent and the
    /// reject row denies it, as on a command; the title is the card's own
    /// question.
    @Test func readsTheSubagentApprovalCard() throws {
        let dialog = try GrokCards.dialog("grok-35-permission-subagent-62")

        #expect(dialog.kind == .grokPermission)
        #expect(dialog.title == "Allow Sleep 60 then reply done")
        #expect(dialog.subject == DialogSubject())
        #expect(dialog.options.map(\.label) == ["Yes, send once", Self.reject])
        #expect(dialog.options.map(\.number) == [2, 3])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.options.map(\.detail) == [nil, "Ends the turn"])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 31..<38)
    }

    /// grok-36, derived from a read at 40 columns: Grok cut the rule's
    /// scope to fit, `Always allow: chmod 644…`, which hides how far the
    /// rule reaches. Chat leaves the rule to the terminal, keeps Yes and
    /// No, and says how to see it. The description is cut too, so the
    /// command stands for the card on its own.
    @Test func withholdsALastingRuleGrokCutToFit() throws {
        let dialog = try GrokCards.dialog("grok-36-permission-command-40")

        #expect(dialog.kind == .grokPermission)
        #expect(dialog.title == "Allow Command")
        #expect(dialog.subject.command == "chmod 644 README.md")
        #expect(dialog.subject.commandDescription == nil)
        #expect(dialog.options.map(\.label) == ["Yes, proceed", Self.reject])
        #expect(dialog.options.map(\.number) == [3, 4])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.body.contains("Always allow: chmod 644…"))
        #expect(dialog.note == "Widen the terminal to see the lasting rule.")
    }

    /// grok-37: the same card at the phone's 62 columns shows the rule in
    /// full, so Chat offers it.
    @Test func offersALastingRuleShownInFull() throws {
        let dialog = try GrokCards.dialog("grok-37-permission-command-62")

        #expect(dialog.subject.commandDescription == "Set README.md permissions to 644")
        #expect(dialog.options.map(\.label) == ["Always allow: chmod 644 README.md", "Yes, proceed", Self.reject])
        #expect(dialog.options.map(\.number) == [2, 3, 4])
        #expect(dialog.options.map(\.role) == [.approvePersistent, .approve, .decline])
        #expect(dialog.note == nil)
    }

    /// The session's edit rule, were Grok to cut it with `…`, stays in the
    /// terminal the same way (synthetic).
    @Test func withholdsASessionRuleCutToFit() throws {
        let dialog = try GrokCards.dialog("synthetic-edit-permission-session-cut")

        #expect(dialog.title == "Allow Edit")
        #expect(dialog.options.map(\.label) == ["Yes", Self.reject])
        #expect(dialog.options.map(\.number) == [3, 4])
        #expect(dialog.note == "Widen the terminal to see the lasting rule.")
    }

    /// Always-approve mode and `Never allow:` stay on screen and in the
    /// body, never among the options, cut at the card's edge or not.
    @Test func neverOffersAlwaysApproveOrNeverAllow() throws {
        let alwaysApprove = "Yes, and don't ask again for anything (always-approve mode)"
        for stem in [
            "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit",
            "grok-35-permission-subagent-62",
        ] {
            let dialog = try GrokCards.dialog(stem)
            let labels = dialog.options.map(\.label)

            #expect(!labels.contains { $0.contains("always-approve") || $0.hasPrefix("Never allow") }, "\(stem)")
            #expect(dialog.body.contains(alwaysApprove), "\(stem)")
        }
        let command = try GrokCards.dialog("grok-12-permission-command")
        #expect(
            command.body == [
                "Set README.md permissions to 644", "chmod 644 README.md", alwaysApprove, "Never allow: chmod 644",
            ])
        #expect(command.rows.contains(38))
        #expect(command.rows.contains(42))
    }

    /// grok-15: the cursor's band marks the first answer; nothing is chosen
    /// yet. `(Recommended)` stays in the label, as Grok prints it.
    @Test func readsASingleSelectQuestion() throws {
        let dialog = try GrokCards.dialog("grok-15-question")
        let question = "How should we handle the README rename plan?"

        #expect(dialog.kind == .grokQuestion)
        #expect(dialog.title == question)
        #expect(dialog.subject.question == question)
        #expect(dialog.body == [question])
        #expect(
            dialog.options.map(\.label) == [
                "Keep it as a todo (Recommended)", "Rename it now", "Type your answer here",
            ])
        #expect(
            dialog.options.map(\.detail) == [
                "Leave the three-step plan in the todos and change no files.",
                "Start the rename with the three steps in the todos.", nil,
            ])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(dialog.options.map(\.shortcut) == ["1", "2", "z"])
        #expect(dialog.options.map(\.number) == [1, 2, nil])
        #expect(dialog.focus.focusedOrdinal == 1)
    }

    /// grok-16: Ctrl+C while a subagent runs. Both `Always` rows write
    /// config, so Chat leaves them to the terminal.
    @Test func readsTheSubagentPanel() throws {
        let dialog = try GrokCards.dialog("grok-16-subagent-panel")

        #expect(dialog.kind == .grokCancelTurn)
        #expect(dialog.title == "Subagents are still running. Stop them?")
        #expect(dialog.body == ["1 subagent running"])
        #expect(dialog.options.map(\.label) == ["Stop running", "Continue to run"])
        #expect(dialog.options.map(\.role) == [.cancel, .answer])
        #expect(
            dialog.options.map(\.detail) == [
                "Stops the turn and its subagents", "Ends the turn; subagents keep running",
            ])
        #expect(dialog.options.map(\.number) == [1, 2])
        #expect(dialog.focus.focusedOrdinal == 1)
    }

    /// `/fork`'s worktree question, at 182 columns and at the phone's
    /// grid: Yes and No, each of which forks, by their keys. Always
    /// worktree and Never worktree save the choice in Grok's config, so
    /// they stay in the terminal, as does a typed answer. The title is the
    /// question.
    @Test(arguments: ["grok-25-fork-question", "grok-38-fork-question-62"])
    func readsTheForkQuestion(stem: String) throws {
        let dialog = try GrokCards.dialog(stem)
        let question = "Run this fork in an isolated git worktree?"

        #expect(dialog.kind == .grokFork)
        #expect(dialog.program == .grok)
        #expect(dialog.title == question)
        #expect(dialog.body == [question, "Always worktree", "Never worktree"])
        #expect(dialog.options.map(\.label) == ["Yes", "No", "Type your answer here"])
        #expect(
            dialog.options.map(\.detail) == ["Fork in a new isolated git worktree", "Fork in the current cwd", nil])
        #expect(dialog.options.map(\.number) == [1, 2, nil])
        #expect(dialog.options.map(\.shortcut) == ["1", "2", "z"])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
    }

    /// The rewind confirmation, the fork question at 40 columns, where
    /// Grok's card scrolls No out of view, or with its cursor out of view,
    /// which may be on the answer field, several questions at once and a
    /// card Heeler doesn't know hold sending as excerpts. Without numbers
    /// the generic card offers only its key pad.
    @Test(arguments: [
        "grok-23-rewind-confirm", "grok-39-fork-question-40", "synthetic-fork-cursor-unseen",
        "synthetic-multi-question", "synthetic-unknown-card",
    ])
    func leavesOtherCardsGenericWithoutNumbers(stem: String) throws {
        let screen = try GrokCards.screen(stem)
        let result = GrokDialogParser.parse(screen)
        let excerpt = try #require(result.excerpt, "\(stem) parsed as \(result)")
        let card = try #require(GrokScreen(screen).card)

        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows == Array(screen.rows[card]))
        #expect(!excerpt.reason.isEmpty)
        // The bar and the scrollbar stay off the card.
        let lines = try #require(excerpt.displayLines)
        #expect(!lines.contains { $0.contains("┃") || $0.contains("█") })
        #expect(BlockedDialogParser.parse(screen, program: .grok) == result)
    }

    /// `/fork`'s worktree question left generic says it is `/fork`'s, that
    /// every answer forks and that two rows save a lasting choice, then
    /// where to answer: at 40 columns, where Grok scrolls those rows out of
    /// view, and with every row in view but the cursor unseen. The key pad
    /// stays.
    @Test func explainsTheForkQuestionItLeavesGeneric() throws {
        let narrow = try #require(try GrokCards.parse("grok-39-fork-question-40").excerpt)
        let unseen = try #require(try GrokCards.parse("synthetic-fork-cursor-unseen").excerpt)

        #expect(
            narrow.reason
                == "Grok Build's /fork asks this, and every answer forks. Always worktree and Never worktree, which "
                + "this width hides, also save a lasting choice. Answer in the terminal or with these keys.")
        #expect(
            unseen.reason
                == "Grok Build's /fork asks this, and every answer forks. Always worktree and Never worktree also "
                + "save a lasting choice. Answer in the terminal or with these keys.")
        #expect(narrow.numbered.isEmpty)
        #expect(unseen.numbered.isEmpty)
    }

    /// Esc parks the keyboard in the scrollback with the card still drawn.
    /// The cursor keeps its `(●)` and bold label, but the band goes and
    /// the footer offers the card back, and digits would miss it.
    @Test func aCardWithoutFocusHasNoFocusedOption() throws {
        let permission = try GrokCards.dialog("synthetic-unfocused-permission")
        let question = try GrokCards.dialog("synthetic-unfocused-question")

        #expect(permission.kind == .grokPermission)
        #expect(permission.focus == DialogFocusState(keysMissOptions: true))
        #expect(permission.options.filter(\.isFocused).isEmpty)
        #expect(question.kind == .grokQuestion)
        #expect(question.focus == DialogFocusState(keysMissOptions: true))
        // The same card with the keyboard reads its cursor.
        #expect(try GrokCards.dialog("synthetic-question-ten-answers").focus == DialogFocusState(focusedOrdinal: 1))
    }

    /// A row's key selects it wherever the cursor is, so the cursor on a
    /// row Chat leaves to the terminal leaves the keys on the card: no
    /// option Chat offers has focus, and the keys still reach them.
    @Test(arguments: [
        "synthetic-permission-cursor-on-always-approve", "synthetic-permission-cursor-on-never-allow",
        "synthetic-subagents-cursor-on-always-stop",
    ])
    func theCursorOnARowLeftToTheTerminalKeepsTheKeysOnTheCard(stem: String) throws {
        let dialog = try GrokCards.dialog(stem)

        #expect(dialog.focus == DialogFocusState())
        #expect(dialog.options.filter(\.isFocused).isEmpty)
        #expect(dialog.options.map(\.number) == (dialog.kind == .grokPermission ? [2, 3, 4] : [1, 2]))
    }

    /// The dashboard can show another agent's card, and the card's hints
    /// replace the footer's, so the header's switcher tells. Such a card
    /// holds sending as an excerpt without numbers.
    @Test func aCardOnTheDashboardsViewOfAnAgentStaysGeneric() throws {
        let screen = try GrokCards.screen("synthetic-permission-dashboard-overlay")
        let result = GrokDialogParser.parse(screen)
        let excerpt = try #require(result.excerpt, "parsed as \(result)")

        #expect(excerpt.numbered.isEmpty)
        #expect(
            excerpt.reason
                == "Grok Build is showing this card for an agent from its dashboard, which may not be this "
                + "conversation. Answer it with these keys or in the terminal.")
        #expect(BlockedDialogParser.parse(screen, program: .grok) == result)
        // The same card on the conversation's own view.
        #expect(try GrokCards.dialog("synthetic-permission-120").kind == .grokPermission)
    }

    /// Phone widths (synthetic): rows stop at the card's edge, so a label
    /// cut there still names its option; a question wraps its text and its
    /// cursor's answer; the turn status label shrinks to `Waiting on …`.
    /// The terminal theme draws the band in reverse video.
    @Test(arguments: [
        "synthetic-permission-40", "synthetic-permission-62", "synthetic-permission-40-terminal-theme",
        "synthetic-question-40", "synthetic-question-62", "synthetic-subagents-40",
    ])
    func readsCardsAtPhoneWidth(stem: String) throws {
        let dialog = try GrokCards.dialog(stem)

        switch dialog.kind {
        case .grokPermission:
            #expect(dialog.title == "Allow Command")
            #expect(dialog.subject.command == "ls -l")
            #expect(dialog.options.map(\.number) == [2, 3, 4])
            #expect(dialog.options.map(\.role) == [.approvePersistent, .approve, .decline])
            #expect(dialog.options.map(\.label) == ["Always allow: ls -l", "Yes, proceed", Self.reject])
            #expect(dialog.focus.focusedOrdinal == 2)
            #expect(dialog.body.count == 4)
        case .grokQuestion:
            #expect(dialog.subject.question == "How should we handle the README rename plan?")
            #expect(dialog.options.map(\.shortcut) == ["1", "2", "z"])
            #expect(dialog.options.first?.label == "Keep it as a todo (Recommended)")
            #expect(dialog.options.first?.detail == "Leave the three-step plan in the todos and change no files.")
            #expect(dialog.options[1].label == "Rename it now")
            #expect(dialog.focus.focusedOrdinal == 1)
        case .grokCancelTurn:
            #expect(dialog.options.map(\.label) == ["Stop running", "Continue to run"])
            #expect(dialog.focus.focusedOrdinal == 1)
        default:
            Issue.record("\(stem) parsed as \(dialog.kind)")
        }
    }

    /// Focus stays out of the fingerprint: the same card with the keyboard
    /// and without it is the same card. A label the card's edge cuts reads
    /// as the whole label Grok prints.
    @Test func focusStaysOutOfTheFingerprint() throws {
        let focused = try GrokCards.dialog("synthetic-permission-120")
        let unfocused = try GrokCards.dialog("synthetic-unfocused-permission")
        let narrow = try GrokCards.dialog("synthetic-permission-62")

        #expect(focused.focus.focusedOrdinal == 2)
        #expect(focused.fingerprint == unfocused.fingerprint)
        #expect(narrow.fingerprint == focused.fingerprint)
    }

    @Test func screensWithoutACardHaveNoDialog() throws {
        for stem in ["grok-01-idle-empty", "grok-03-working", "grok-22-rewind-picker", "grok-26-waiting-subagent"] {
            #expect(GrokDialogParser.parse(try ScreenFixture.screen(stem)) == .none, "\(stem)")
        }
    }
}
