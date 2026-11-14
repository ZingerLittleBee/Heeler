import Foundation
import Testing

@testable import Heeler

@Suite("Pre-send gate")
struct PreSendGateTests {
    @Test("An empty box passes unless the Agent is Blocked")
    func emptyBox() {
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .idle) == .send)
        #expect(PreSendGate.check(.empty(placeholder: "Ask Codex to do anything"), activity: .working) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .unknown) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .blocked) == .holdBlocked)
    }

    @Test(
        "Every other state holds the message",
        arguments: [
            InputBoxState.text("draft"), .shellMode("ls"), .shellMode(""), .disabled("Input disabled."),
            .overlay("/compact"), .dialog(title: nil), .unknown("Claude's input box is not on screen."),
            .noComposer("Open this conversation in the terminal first."),
        ])
    func holds(state: InputBoxState) {
        #expect(PreSendGate.check(state, activity: .idle) == .hold(state))
        #expect(PreSendGate.check(state, activity: .blocked) == .holdBlocked)
    }

    @Test("Captured screens")
    func capturedScreens() throws {
        #expect(PreSendGate.check(try ScreenFixture.screen("claude-01-ready"), program: .claude, activity: .idle) == .send)
        #expect(PreSendGate.check(try ScreenFixture.screen("codex-00-ready"), program: .codex, activity: .idle) == .send)
        let bash = try ScreenFixture.screen("claude-02-c1-bash-blocked")
        #expect(PreSendGate.check(bash, program: .claude, activity: .blocked) == .holdBlocked)
        #expect(PreSendGate.check(bash, program: .claude, activity: .unknown) == .hold(.dialog(title: nil)))
        // The composer stays in view while asynchronous questions wait.
        let collapsed = try ScreenFixture.screen("codex-08-x4-async-collapsed")
        #expect(PreSendGate.check(collapsed, program: .codex, activity: .working) == .hold(.dialog(title: nil)))
        // herdr reports Codex idle under its plan selector.
        let plan = try ScreenFixture.screen("codex-19-x3-implement-plan")
        #expect(PreSendGate.check(plan, program: .codex, activity: .idle) == .hold(.dialog(title: "Implement this plan?")))
    }

    /// Grok Build takes a message only into an empty composer with prompt
    /// focus, working or not, or under its Welcome view. herdr reports
    /// menus, pickers and the dashboard idle, so the screen holds those.
    /// The dashboard's view of an agent passes here, and the session check
    /// reads whose agent it shows.
    @Test("Grok Build sends only into a focused, empty composer", arguments: ScreenFixture.grok)
    func grokSendsOnlyIntoAFocusedEmptyComposer(stem: String) throws {
        let sendable: Set = [
            "grok-01-idle-empty", "grok-03-working", "grok-05-queued", "grok-06-esc-toast", "grok-17-session-new",
            "grok-18-session-fork", "grok-19-resumed-other", "grok-20-welcome", "grok-27-compacting",
            "grok-28-welcome-62", "grok-29-welcome-40", "grok-30-idle-62x20", "grok-32-working-62x20",
            "grok-40-agent-view-other-62", "grok-41-agent-view-this-62", "grok-42-agent-view-dispatched-62",
            "grok-43-resumed-from-welcome-120", "grok-45-compaction-cancelled-62",
        ]
        let screen = try ScreenFixture.screen(stem)

        let decision = PreSendGate.check(screen, program: .grok, activity: .idle)

        if sendable.contains(stem) {
            #expect(decision == .send)
        } else {
            #expect(decision != .send)
        }
        #expect(PreSendGate.check(screen, program: .grok, activity: .blocked) == .holdBlocked)
    }

    /// Of OpenCode's captures, only an empty box in a conversation with no
    /// turn running takes a message, whatever herdr reports short of
    /// Blocked.
    @Test(arguments: ScreenFixture.opencode)
    func openCodeScreensHoldOrSend(stem: String) throws {
        let sendable = [
            "opencode-02-session-empty-180", "opencode-21-done-interrupted-180", "opencode-24-after-ctrl-u-180",
            "opencode-32-session-empty-62",
        ]
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .opencode)
        let decision: PreSendDecision = sendable.contains(stem) ? .send : .hold(state)
        for activity in [ChatAgentActivity.idle, .working, .unknown] {
            #expect(PreSendGate.check(screen, program: .opencode, activity: activity) == decision)
        }
        #expect(PreSendGate.check(screen, program: .opencode, activity: .blocked) == .holdBlocked)
    }

    /// Antigravity CLI takes a message into an empty box with nothing drawn
    /// under it, idle or while a turn runs. herdr 0.9.5 reports its file
    /// edit dialog and popups idle, so the screen holds those.
    @Test(arguments: ScreenFixture.agy)
    func agyScreensHoldOrSend(stem: String) throws {
        let sendable: Set = [
            "agy-01-welcome-after-attach-120x40", "agy-02-idle-empty-120x40", "agy-03-ctrlc-idle-once-120x40",
            "agy-06-esc-esc-idle-draft-120x40",
            "agy-09-welcome-after-trust-answered-elsewhere-190x49", "agy-13-first-screen-welcome-120x40",
            "agy-17-prompt-newline-just-sent-120x40", "agy-18-idle-after-reply-120x40",
            "agy-32-perm-after-digit2-120x40", "agy-34-working-submitted-while-working-120x40",
            "agy-35-done-after-queued-120x40", "agy-36-done-final-120x40", "agy-38-esc-while-working-120x40",
            "agy-39-ctrlc-while-working-120x40", "agy-43-ask-question-after-digit2-120x40",
            "agy-46-ask-question-multi-after-esc-120x40", "agy-49-prompt-sent-into-edit-dialog-120x40",
            "agy-50-after-edit-accepted-by-prompt-120x40",
            "agy-51-perm-run-command-after-esc-120x40", "agy-54-idle-after-esc-amend-heeler-client-59x41",
            "agy-56-perm-run-command-after-digit4-190x49", "agy-57-idle-empty-62x41", "agy-63-idle-empty-40x30",
            "agy-63-idle-empty-62x20", "agy-66-working-nodraft-62x41", "agy-67-working-tool-running-62x41",
            "agy-70-working-queued-after-approve-62x41", "agy-72-working-altm-send-now-62x41",
            "agy-73-done-after-altm-62x41", "agy-74-compacting-or-after-62x41", "agy-75-after-compact-62x41",
            "agy-76-mode-cycle-1-120x40", "agy-76-mode-cycle-2-120x40", "agy-76-mode-cycle-3-120x40",
            "agy-76-mode-cycle-4-120x40", "agy-78-auto-mode-result-120x40", "agy-79-plan-mode-result-120x40",
            "agy-81-artifact-review-after-y-120x40", "agy-83-plan-edit-rejected-120x40",
            "agy-84-footer-modes-40x30-40x30", "agy-84-footer-modes-62x20-62x20", "agy-84-footer-modes-62x41-62x41",
            "agy-87-perm-after-ctrlc-120x40", "agy-89-warning-notice-bad-model-120x40",
            "agy-90-first-screen-welcome-40x30", "agy-90-first-screen-welcome-62x20",
            "agy-90-first-screen-welcome-62x41", "agy-94-working-nodraft-40x30", "agy-96-working-queued-40x30",
            "agy-98-working-nodraft-62x20", "agy-103-ask-question-multiselect-after-enter-62x41",
            "agy-107-ask-question-multi-q2-after-digit2-62x41", "agy-115-ask-question-single-after-esc-62x41",
            // agy under `NO_COLOR`.
            "agy-116-nocolor-idle-empty-45x45", "agy-118-nocolor-draft-cleared-45x45",
            "agy-121-nocolor-after-bash-mode-45x45", "agy-122-nocolor-accept-edits-hint-cut-45x45",
            "agy-123-nocolor-mode-cycle-accept-edits-92x47", "agy-124-nocolor-mode-cycle-auto-92x47",
            "agy-125-nocolor-mode-cycle-plan-92x47", "agy-126-nocolor-mode-cycle-default-92x47",
            "agy-127-nocolor-mode-cycle-accept-edits-again-92x47", "agy-128-nocolor-idle-accept-edits-92x47",
            "agy-130-nocolor-back-to-default-92x47", "agy-133-nocolor-after-help-92x47",
            "agy-134-nocolor-working-nodraft-92x47", "agy-136-nocolor-working-after-run-command-92x47",
            "agy-137-nocolor-working-markdown-prompt-92x47",
            "agy-138-nocolor-idle-after-markdown-reply-92x47", "agy-140-nocolor-working-after-file-create-92x47",
            "agy-143-nocolor-idle-after-file-edit-declined-92x47", "agy-147-nocolor-working-after-questions-92x47",
            "agy-150-nocolor-idle-after-multiselect-92x47",
            // Read through tmux.
            "agy-159-working-after-multiselect-writein-120x40",
            "agy-168-idle-after-writein-and-skipped-question-120x40",
            // A command still running in the background lists its task under
            // the box; the footer under it decides.
            "agy-169-plain-working-background-task-120x40",
            "agy-170-plain-idle-background-task-after-esc-120x40", "agy-175-plain-idle-after-tasks-120x40",
            "agy-181-idle-background-task-after-esc-62x46", "agy-185-idle-after-tasks-62x46",
        ]
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .agy)
        let decision: PreSendDecision = sendable.contains(stem) ? .send : .hold(state)
        for activity in [ChatAgentActivity.idle, .working, .unknown] {
            #expect(PreSendGate.check(screen, program: .agy, activity: activity) == decision)
        }
        #expect(PreSendGate.check(screen, program: .agy, activity: .blocked) == .holdBlocked)
    }
}

@Suite("Delivery check")
struct DeliveryCheckTests {
    @Test("The box emptied, or a dialog or Blocked took over: delivered")
    func delivered() {
        #expect(DeliveryCheck.verdict(.empty(placeholder: nil), activity: .working) == .delivered)
        #expect(DeliveryCheck.verdict(.dialog(title: nil), activity: .unknown) == .delivered)
        #expect(DeliveryCheck.verdict(.unknown("why"), activity: .blocked) == .delivered)
    }

    @Test("Text left in the box: not delivered, with the text")
    func notDelivered() {
        #expect(DeliveryCheck.verdict(.text("fix the tests"), activity: .idle) == .notDelivered("fix the tests"))
        #expect(DeliveryCheck.verdict(.shellMode("ls"), activity: .working) == .notDelivered("ls"))
    }

    @Test(
        "Anything else leaves the message marked as sent",
        arguments: [
            InputBoxState.shellMode(""), .disabled("Input disabled."), .overlay("/compact"),
            .unknown("Codex's composer is not on screen."),
            .noComposer("Open this conversation in the terminal first."),
        ])
    func unconfirmed(state: InputBoxState) {
        #expect(DeliveryCheck.verdict(state, activity: .idle) == .unconfirmed)
    }

    @Test("Captured screens after sending")
    func capturedScreens() throws {
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-29-c3-after-immediate"), program: .claude, activity: .idle)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-02-c1-bash-blocked"), program: .claude, activity: .unknown)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("codex-03-x2-after-esc"), program: .codex, activity: .idle)
                == .delivered)
    }

    /// OpenCode's captures as a re-read after sending would find them: an
    /// emptied box, or a prompt in its place, took the message; text left
    /// in the box did not; a running turn, a menu, shell mode, the home
    /// screen or the subagent panel leaves it marked as sent.
    @Test(arguments: ScreenFixture.opencode)
    func openCodeVerdicts(stem: String) throws {
        let delivered = [
            "opencode-02-session-empty-180", "opencode-10-permission-180", "opencode-11-permission-right1-180",
            "opencode-12-permission-right2-180", "opencode-13-question-180", "opencode-21-done-interrupted-180",
            "opencode-24-after-ctrl-u-180", "opencode-25-reject-feedback-180", "opencode-27-permission-shell-180",
            "opencode-28-permission-shell-right1-180", "opencode-29-permission-shell-next-180",
            "opencode-32-session-empty-62", "opencode-37-permission-long-62", "opencode-38-question-long-62",
            "opencode-42-reject-feedback-62",
        ]
        let notDelivered = [
            "opencode-03-session-draft-180", "opencode-05-slash-space-180", "opencode-17-recalled-draft-180",
            "opencode-19-undo-draft-180", "opencode-20-pasted-lines-180", "opencode-22-home-draft-180",
            "opencode-23-at-space-180", "opencode-26-session-command-draft-180", "opencode-31-home-draft-62",
            "opencode-33-wrapped-draft-62", "opencode-34-pasted-lines-62",
        ]
        let screen = try ScreenFixture.screen(stem)
        for activity in [ChatAgentActivity.idle, .working] {
            let verdict = DeliveryCheck.verdict(screen, program: .opencode, activity: activity)
            if delivered.contains(stem) {
                #expect(verdict == .delivered)
            } else if notDelivered.contains(stem) {
                guard case .notDelivered(let draft) = verdict else {
                    Issue.record("Expected notDelivered, got \(verdict)")
                    continue
                }
                #expect(!draft.isEmpty)
            } else {
                #expect(verdict == .unconfirmed)
            }
        }
    }

    @Test("The re-read waits three seconds")
    func delay() {
        #expect(DeliveryCheck.delay == .seconds(3))
    }

    /// Whitespace doesn't count: the box wraps a long message across rows,
    /// trims each, and may show only its end.
    @Test("Grok Build: the sent text left in the box is not delivered")
    func grokTextLeftFromTheSendIsNotDelivered() throws {
        let draft = try ScreenFixture.screen("grok-02-idle-draft")
        let sent = "Reply with the word kiwi."

        #expect(
            DeliveryCheck.verdict(draft, program: .grok, activity: .idle, sent: "hello draft ")
                == .notDelivered("hello draft"))
        #expect(
            DeliveryCheck.verdict(.text("Reply with the\nword kiwi."), program: .grok, activity: .working, sent: sent)
                == .notDelivered("Reply with the\nword kiwi."))
        #expect(
            DeliveryCheck.verdict(.text("word kiwi."), program: .grok, activity: .idle, sent: sent)
                == .notDelivered("word kiwi."))
    }

    /// Grok Build puts a draft stashed with Ctrl+S back after the next send,
    /// so other text there says nothing about the message.
    @Test("Grok Build: other text after the send is unconfirmed")
    func otherTextAfterAGrokSendIsUnconfirmed() throws {
        let restored = try ScreenFixture.screen("grok-24-restored-draft")

        #expect(
            DeliveryCheck.verdict(restored, program: .grok, activity: .working, sent: "Summarize the README ")
                == .unconfirmed)
        #expect(DeliveryCheck.verdict(.shellMode("ls"), program: .grok, activity: .idle, sent: "hello") == .unconfirmed)
        // Without the sent text, the plain verdict.
        #expect(
            DeliveryCheck.verdict(restored, program: .grok, activity: .idle)
                == .notDelivered("Reply with the word kiwi."))
    }

    @Test("Grok Build: a suggestion drawn after the send is delivered")
    func aGhostSuggestionAfterAGrokSendIsDelivered() {
        let suggestion = GrokScreenBuilder(
            ghost: "Now run the tests", hints: ["Tab/→:accept suggestion", "Shift+Tab:mode", "Ctrl+.:shortcuts"]
        ).screen

        #expect(
            DeliveryCheck.verdict(suggestion, program: .grok, activity: .idle, sent: "Fix the build ") == .delivered)
    }

    /// A send the dashboard's view of an agent took is checked in that
    /// view's box (grok-41; synthetic, the send left behind).
    @Test("Grok Build: the dashboard's view of an agent confirms a send")
    func theDashboardsViewOfAGrokAgentConfirmsASend() throws {
        let emptied = try ScreenFixture.screen("grok-41-agent-view-this-62")
        let left = GrokScreenBuilder(
            columns: 62, typed: "Reply with the word pear",
            hints: ["Ctrl+\\:dashboard", "Ctrl+[/]:prev/next agent", "Ctrl+x:stop"],
            header: "Se… │ main /p/t/hcl/pr… 21K / 256K │ ‹ 2/3 › │ [Dashboard]"
        ).screen

        #expect(
            DeliveryCheck.verdict(emptied, program: .grok, activity: .idle, sent: "Reply with the word pear ")
                == .delivered)
        #expect(
            DeliveryCheck.verdict(left, program: .grok, activity: .idle, sent: "Reply with the word pear ")
                == .notDelivered("Reply with the word pear"))
    }

    @Test(
        "Other programs: any text left in the box is not delivered",
        arguments: ChatProgram.allCases.filter { !$0.mayRefillInputBoxAfterSend })
    func otherProgramsKeepTheirVerdictForOtherText(program: ChatProgram) {
        #expect(
            DeliveryCheck.verdict(.text("draft"), program: program, activity: .idle, sent: "hello")
                == .notDelivered("draft"))
        #expect(
            DeliveryCheck.verdict(.shellMode("ls"), program: program, activity: .working, sent: "hello")
                == .notDelivered("ls"))
    }
}
