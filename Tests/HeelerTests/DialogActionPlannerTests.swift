import Foundation
import Testing

@testable import Heeler

@Suite("Dialog action planner")
struct DialogActionPlannerTests {
    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private func plan(_ action: DialogAction, _ stem: String, toolUseID: String? = nil) throws -> DialogActionPlan {
        try DialogActionPlanner.plan(action, for: dialog(stem), toolUseID: toolUseID)
    }

    // MARK: Claude permissions

    @Test("A digit picks a permission option; Esc declines")
    func permissionChoice() throws {
        #expect(
            try plan(.choose(ordinal: 1), "claude-02-c1-bash-blocked")
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .fingerprintChange))
        #expect(
            try plan(.choose(ordinal: 4), "claude-02-c1-bash-blocked", toolUseID: "toolu_01")
                == DialogActionPlan(steps: [.keys(["4"])], confirmation: .toolResult(id: "toolu_01")))
        #expect(
            try plan(.dismiss, "claude-02-c1-bash-blocked")
                == DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChange))
        #expect(try plan(.choose(ordinal: 2), "claude-22-c7-edit").steps == [.keys(["2"])])
        #expect(try plan(.choose(ordinal: 3), "claude-24-c8-webfetch").steps == [.keys(["3"])])
        #expect(
            try plan(.choose(ordinal: 1), "claude-43-c12-read-file", toolUseID: "toolu_r")
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .toolResult(id: "toolu_r")))
        #expect(throws: DialogPlanError.noSuchOption(5)) {
            try plan(.choose(ordinal: 5), "claude-02-c1-bash-blocked")
        }
    }

    @Test("A note on No: arrows to the row, Tab, paste, check, Enter")
    func declineWithNote() throws {
        let note = "Do not create it; reply with the single word skipped"
        let tail: [DialogStep] = [.paste(note), .expect(.inputText(note)), .keys(["enter"])]
        #expect(
            try plan(.amend(ordinal: 4, note: note), "claude-02-c1-bash-blocked").steps
                == [
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["down"]), .expect(.focus(ordinal: 4)), .keys(["tab"]), .expect(.feedbackMode(ordinal: 4)),
                ] + tail)
        // The probe's own path: focus already on No, then the field open.
        #expect(
            try plan(.amend(ordinal: 4, note: note), "claude-03-c1-focus-no").steps
                == [.keys(["tab"]), .expect(.feedbackMode(ordinal: 4))] + tail)
        #expect(try plan(.amend(ordinal: 4, note: note), "claude-04-c1-tab-on-no").steps == tail)
    }

    @Test("A note on Yes")
    func approveWithNote() throws {
        let note = "after it succeeds, reply with the single word created"
        let tail: [DialogStep] = [.paste(note), .expect(.inputText(note)), .keys(["enter"])]
        #expect(
            try plan(.amend(ordinal: 1, note: note), "claude-02-c1-bash-blocked").steps
                == [.keys(["tab"]), .expect(.feedbackMode(ordinal: 1))] + tail)
        #expect(try plan(.amend(ordinal: 1, note: note), "claude-06-c2-tab-on-yes").steps == tail)
        // File dialogs take notes like Bash; inferred from Claude's code, not yet captured.
        #expect(
            try plan(.amend(ordinal: 3, note: note), "claude-22-c7-edit").steps.prefix(4)
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3))])
        // Read file's footer offers Tab to amend too.
        #expect(
            try plan(.amend(ordinal: 2, note: note), "claude-43-c12-read-file").steps
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["tab"]), .expect(.feedbackMode(ordinal: 2))]
                + tail)
    }

    @Test("Notes go only on the Yes and No rows of Bash and file dialogs")
    func noteLimits() throws {
        #expect(throws: DialogPlanError.unsupported("Only the Yes and No rows take a note.")) {
            try plan(.amend(ordinal: 2, note: "note"), "claude-02-c1-bash-blocked")
        }
        #expect(
            throws: DialogPlanError.unsupported("Only Claude's Bash and file dialogs take a note with the answer.")
        ) {
            try plan(.amend(ordinal: 3, note: "note"), "claude-24-c8-webfetch")
        }
        #expect(throws: DialogPlanError.multilineText) {
            try plan(.amend(ordinal: 4, note: "one\ntwo"), "claude-02-c1-bash-blocked")
        }
    }

    @Test(
        "Text typed in the terminal stops every plan but Esc",
        arguments: [
            "claude-05-c1-pasted-feedback", "claude-07-c2-pasted", "claude-13-c4-q2-pasted", "claude-18-c6-pasted",
            "claude-35-c7-phone-pasted-truncated", "claude-37-c7-phone-yes-pasted-wrapped",
        ])
    func typedText(stem: String) throws {
        let dialog = try dialog(stem)
        #expect(dialog.hasTypedText)
        for option in dialog.options {
            #expect(throws: DialogPlanError.textFieldNotEmpty) {
                try DialogActionPlanner.plan(.choose(ordinal: option.ordinal), for: dialog)
            }
        }
        let field = try #require(dialog.options.first { $0.input != nil })
        let typing: DialogAction =
            dialog.kind == .claudeBash
            ? .amend(ordinal: field.ordinal, note: "more") : .respond(ordinal: field.ordinal, text: "more")
        #expect(throws: DialogPlanError.textFieldNotEmpty) { try DialogActionPlanner.plan(typing, for: dialog) }
        #expect(try DialogActionPlanner.plan(.dismiss, for: dialog).steps == [.keys(["esc"])])
    }

    @Test("Digits step off a focused empty field first")
    func leaveField() throws {
        // No's note field is open: up to option 3, then the digit.
        #expect(
            try plan(.choose(ordinal: 1), "claude-04-c1-tab-on-no").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 3)), .keys(["1"])])
        // Yes's note field is open on the first row: down instead.
        #expect(
            try plan(.choose(ordinal: 4), "claude-06-c2-tab-on-yes").steps
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["4"])])
        #expect(
            try plan(.choose(ordinal: 2), "claude-17-c6-digit3").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 2)), .keys(["2"])])
        #expect(
            try plan(.choose(ordinal: 1), "claude-12-c4-q2-digit3").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 2)), .keys(["1"]), .expect(.page("Review your answers"))])
    }

    // MARK: Claude plans and questions

    @Test("Plan: approve by digit, send back or approve with a note")
    func planActions() throws {
        let stem = "claude-16-c6-exitplan-1"
        let note = "Name the file q.txt instead"
        #expect(try plan(.choose(ordinal: 2), stem).steps == [.keys(["2"])])
        #expect(throws: DialogPlanError.needsText) { try plan(.choose(ordinal: 3), stem) }
        #expect(
            try plan(.respond(ordinal: 3, text: note), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste(note), .expect(.inputText(note)),
                    .keys(["enter"]),
                ])
        #expect(
            try plan(.approvePlan(note: note), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste(note), .expect(.inputText(note)),
                    .keys(["shift+tab"]),
                ])
        // With the row focused already, no digit.
        #expect(
            try plan(.respond(ordinal: 3, text: note), "claude-17-c6-digit3").steps
                == [.paste(note), .expect(.inputText(note)), .keys(["enter"])])
        #expect(throws: DialogPlanError.unsupported("Option 1 is not a text field.")) {
            try plan(.respond(ordinal: 1, text: note), stem)
        }
        #expect(throws: DialogPlanError.unsupported("This dialog does not offer approving with feedback.")) {
            try plan(.approvePlan(note: note), "claude-02-c1-bash-blocked")
        }
    }

    @Test("Multi-select: a checked digit each, arrows to Next, Enter, the next page")
    func multiSelect() throws {
        // The probe pressed `1`, `3`, `down` four times and `enter`.
        #expect(
            try plan(.submitSelection([1, 3]), "claude-08-c4-auq-q1").steps
                == [
                    .keys(["1"]), .expect(.checked([1])), .keys(["3"]), .expect(.checked([1, 3])),
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["down"]), .expect(.focus(ordinal: 4)), .keys(["down"]), .expect(.focus(ordinal: 5)),
                    .keys(["enter"]), .expect(.page("Size")),
                ])
        #expect(
            try plan(.submitSelection([1, 3]), "claude-09-c4-toggled").keys
                == ["down", "down", "down", "down", "enter"])
        #expect(
            Array(try plan(.submitSelection([2]), "claude-09-c4-toggled").steps.prefix(6))
                == [
                    .keys(["1"]), .expect(.checked([3])), .keys(["2"]), .expect(.checked([2, 3])), .keys(["3"]),
                    .expect(.checked([2])),
                ])
        #expect(
            try plan(.submitSelection([1, 3]), "claude-10-c4-focus-next").steps
                == [.keys(["enter"]), .expect(.page("Size"))])
        #expect(
            try plan(.choose(ordinal: 5), "claude-10-c4-focus-next").steps
                == [.keys(["enter"]), .expect(.page("Size"))])
        // Chat about this keeps its own number.
        #expect(try plan(.choose(ordinal: 6), "claude-08-c4-auq-q1").steps == [.keys(["5"])])
    }

    @Test("Multi-select refusals")
    func multiSelectLimits() throws {
        let stem = "claude-08-c4-auq-q1"
        #expect(throws: DialogPlanError.unsupported("A multi-select question takes its answers as a set.")) {
            try plan(.choose(ordinal: 1), stem)
        }
        #expect(throws: DialogPlanError.emptySelection) { try plan(.submitSelection([]), stem) }
        #expect(throws: DialogPlanError.unsupported("Option 4 is not an answer Heeler can check.")) {
            try plan(.submitSelection([4]), stem)
        }
        #expect(throws: DialogPlanError.noSuchOption(9)) { try plan(.submitSelection([9]), stem) }
        #expect(throws: DialogPlanError.unsupported("Heeler does not type into a multi-select question's Other row.")) {
            try plan(.respond(ordinal: 4, text: "Teal"), stem)
        }
        // Only Antigravity CLI's set takes a written answer.
        #expect(throws: DialogPlanError.unsupported("Heeler does not type into a multi-select question's Other row.")) {
            try plan(.submitSelection([1], text: "Teal"), stem)
        }
        #expect(throws: DialogPlanError.unsupported("Only a multi-select question takes a set of answers.")) {
            try plan(.submitSelection([1]), "claude-11-c4-q2")
        }
    }

    @Test("Single select: a digit answers and turns the page; Other takes text")
    func singleSelect() throws {
        let stem = "claude-11-c4-q2"
        let review: DialogStep = .expect(.page("Review your answers"))
        #expect(try plan(.choose(ordinal: 2), stem).steps == [.keys(["2"]), review])
        #expect(try plan(.choose(ordinal: 4), stem).steps == [.keys(["4"])])
        #expect(throws: DialogPlanError.needsText) { try plan(.choose(ordinal: 3), stem) }
        #expect(
            try plan(.respond(ordinal: 3, text: "Medium"), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste("Medium"), .expect(.inputText("Medium")),
                    .keys(["enter"]), review,
                ])
        #expect(
            try plan(.respond(ordinal: 3, text: "Medium"), "claude-12-c4-q2-digit3").steps
                == [.paste("Medium"), .expect(.inputText("Medium")), .keys(["enter"]), review])
    }

    @Test("Review page: a digit submits or cancels")
    func reviewPage() throws {
        #expect(try plan(.choose(ordinal: 1), "claude-14-c4-review").steps == [.keys(["1"])])
        #expect(try plan(.choose(ordinal: 2), "claude-14-c4-review").steps == [.keys(["2"])])
    }

    @Test("Trust: arrows and Enter, since the options have no numbers")
    func trust() throws {
        let stem = "claude-00-trust"
        #expect(
            try plan(.choose(ordinal: 2), stem)
                == DialogActionPlan(
                    steps: [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])],
                    confirmation: .fingerprintChange))
        #expect(try plan(.choose(ordinal: 1), stem).steps == [.keys(["enter"])])
        #expect(try plan(.dismiss, stem).steps == [.keys(["esc"])])
        #expect(throws: DialogPlanError.unsupported("Only Codex queues questions.")) {
            try plan(.skipQuestion, stem)
        }
    }

    // MARK: Codex

    @Test("Codex approval: a digit acts; a decline hands over to the composer")
    func codexApproval() throws {
        let stem = "codex-01-x1-exec"
        #expect(
            try plan(.choose(ordinal: 1), stem)
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .fingerprintChangeOrUnblocked))
        #expect(
            try plan(.choose(ordinal: 3), stem)
                == DialogActionPlan(
                    steps: [.keys(["3"])], confirmation: .fingerprintChangeOrUnblocked, focusesComposer: true))
        #expect(
            try plan(.dismiss, stem)
                == DialogActionPlan(
                    steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked, focusesComposer: true))
        #expect(try plan(.choose(ordinal: 2), "codex-02-x2-patch").steps == [.keys(["2"])])
        #expect(
            throws: DialogPlanError.unsupported(
                "Codex ignores text on approvals; decline, then tell Codex in the composer.")
        ) {
            try plan(.amend(ordinal: 3, note: "note"), stem)
        }
    }

    /// Codex 0.165.0 ignores `1` on its trust screen, and herdr can report
    /// the screen Idle throughout, so leaving Blocked confirms nothing.
    @Test("Codex trust: arrows and Enter rather than digits, confirmed by the screen changing")
    func codexTrust() throws {
        #expect(
            try plan(.choose(ordinal: 1), "codex-20-x8-trust")
                == DialogActionPlan(steps: [.keys(["enter"])], confirmation: .fingerprintChange))
        #expect(
            try plan(.choose(ordinal: 2), "codex-20-x8-trust")
                == DialogActionPlan(
                    steps: [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])],
                    confirmation: .fingerprintChange))
        #expect(
            try plan(.choose(ordinal: 1), "codex-22-x8-phone-trust-focus-quit").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 1)), .keys(["enter"])])
        #expect(
            try plan(.dismiss, "codex-23-x8-trust-command-center")
                == DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChange))
        #expect(throws: DialogPlanError.unsupported("The trust screen has no such action.")) {
            try plan(.skipQuestion, "codex-20-x8-trust")
        }
    }

    @Test("Codex question: a digit answers and moves on; notes go on None of the above")
    func codexQuestion() throws {
        let note = "Medium please"
        #expect(try plan(.choose(ordinal: 2), "codex-04-x3-q1").steps == [.keys(["2"]), .expect(.page("Question 2/2"))])
        #expect(try plan(.choose(ordinal: 1), "codex-05-x3-q2").steps == [.keys(["1"])])
        #expect(
            try plan(.respond(ordinal: 3, text: note), "codex-05-x3-q2").steps
                == [
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["tab"]), .expect(.notes("")), .paste(note), .expect(.notes(note)), .keys(["enter"]),
                ])
        // The probe's path: `up` had already reached None of the above.
        #expect(
            try plan(.respond(ordinal: 3, text: note), "codex-06-x3-q2-up").steps
                == [.keys(["tab"]), .expect(.notes("")), .paste(note), .expect(.notes(note)), .keys(["enter"])])
        // Codex 0.162.1 at phone width: Tab opens the notes before the paste.
        #expect(
            try plan(.respond(ordinal: 3, text: note), "codex-16-x7-phone-question-pointed").steps
                == [.keys(["tab"]), .expect(.notes("")), .paste(note), .expect(.notes(note)), .keys(["enter"])])
        #expect(
            try plan(.respond(ordinal: 3, text: "Teal"), "codex-04-x3-q1").steps.last
                == .expect(.page("Question 2/2")))
        #expect(throws: DialogPlanError.unsupported("Heeler adds notes only to None of the above.")) {
            try plan(.respond(ordinal: 1, text: note), "codex-05-x3-q2")
        }
        let interrupt = try plan(.dismiss, "codex-05-x3-q2")
        #expect(interrupt.steps == [.keys(["esc"])])
        #expect(interrupt.focusesComposer)
    }

    @Test("Codex notes: typed notes stop every plan; blank open notes take a paste")
    func codexNotes() throws {
        for action in [DialogAction.choose(ordinal: 1), .respond(ordinal: 3, text: "Large"), .dismiss] {
            #expect(throws: DialogPlanError.textFieldNotEmpty) { try plan(action, "codex-07-x3-q2-pasted") }
        }
        let blank = try #require(
            CodexDialogParser.parse(CodexRows.question(notes: [CodexRows.notesPlaceholder])).dialog)
        #expect(
            try DialogActionPlanner.plan(.respond(ordinal: 2, text: "Medium"), for: blank).steps
                == [.paste("Medium"), .expect(.notes("Medium")), .keys(["enter"])])
        #expect(throws: DialogPlanError.unsupported("Codex's notes field is open, so keys would be typed into it.")) {
            try DialogActionPlanner.plan(.choose(ordinal: 1), for: blank)
        }
        #expect(throws: DialogPlanError.unsupported("Esc would clear Codex's notes rather than interrupt.")) {
            try DialogActionPlanner.plan(.dismiss, for: blank)
        }
    }

    @Test("Codex asynchronous questions: open them, answer into the queue, or skip")
    func codexAsync() throws {
        let collapsed = "codex-08-x4-async-collapsed"
        #expect(
            try plan(.expandQuestions, collapsed)
                == DialogActionPlan(steps: [.keys(["shift+left"])], confirmation: .fingerprintChange))
        #expect(throws: DialogPlanError.unsupported("Open the questions first.")) {
            try plan(.choose(ordinal: 1), collapsed)
        }
        #expect(try plan(.dismiss, collapsed).focusesComposer)

        let expanded = "codex-09-x4-expanded"
        #expect(
            try plan(.choose(ordinal: 1), expanded)
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .queuedNotice("Pick a fruit")))
        #expect(
            try plan(.skipQuestion, expanded)
                == DialogActionPlan(steps: [.keys(["ctrl+]"])], confirmation: .fingerprintChangeOrUnblocked))
        #expect(throws: DialogPlanError.unsupported("Heeler does not answer with Codex's Other yet.")) {
            try plan(.choose(ordinal: 3), expanded)
        }
        #expect(throws: DialogPlanError.unsupported("Codex offers only an answer or a skip here.")) {
            try plan(.dismiss, expanded)
        }
    }

    @Test("Codex plans the same with the matched call's id as without it")
    func codexPlansIgnoreAToolUseID() throws {
        let planned: [(DialogAction, String)] = [
            (.choose(ordinal: 1), "codex-01-x1-exec"), (.choose(ordinal: 3), "codex-01-x1-exec"),
            (.dismiss, "codex-01-x1-exec"), (.choose(ordinal: 2), "codex-04-x3-q1"),
            (.respond(ordinal: 3, text: "Teal"), "codex-04-x3-q1"),
        ]
        for (action, stem) in planned {
            #expect(try plan(action, stem, toolUseID: "call_1") == plan(action, stem), "\(action) on \(stem)")
        }
    }

    // MARK: Oh My Pi

    @Test("OMP's Approve is ctrl+q alone, confirmed by leaving the panel or Blocked")
    func ompApprovalApproveSendsCtrlQOnly() throws {
        let approve = try plan(.choose(ordinal: 1), "omp-24-approval-a-dialog")
        #expect(approve == DialogActionPlan(steps: [.keys(["ctrl+q"])], confirmation: .fingerprintChangeOrUnblocked))
        #expect(!approve.focusesComposer)
        // A draft in the prompt below does not change the keys.
        #expect(try plan(.choose(ordinal: 1), "omp-24-approval-d-typed-abc") == approve)
        #expect(HerdrKeyGrammar.accepts("ctrl+q"))
    }

    @Test("OMP's Deny and Stop are Esc, and the Composer keeps its focus")
    func ompApprovalDenyAndStopSendEsc() throws {
        let esc = DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)
        #expect(try plan(.choose(ordinal: 2), "omp-24-approval-a-dialog") == esc)
        #expect(try plan(.dismiss, "omp-24-approval-a-dialog") == esc)
        #expect(throws: DialogPlanError.noSuchOption(3)) { try plan(.choose(ordinal: 3), "omp-24-approval-a-dialog") }
        #expect(throws: DialogPlanError.unsupported("Oh My Pi takes no note with an approval.")) {
            try plan(.amend(ordinal: 2, note: "no"), "omp-24-approval-a-dialog")
        }
    }

    @Test("OMP's session approval moves to its row one arrow at a time, checked, then presses Enter")
    func ompSessionApprovalMovesByArrowsWithAFocusCheck() throws {
        let confirmation = ConfirmationRule.fingerprintChangeOrUnblocked
        #expect(
            try plan(.choose(ordinal: 2), "omp-36-approval-edit-18-12")
                == DialogActionPlan(
                    steps: [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])],
                    confirmation: confirmation))
        // Already on the row: Enter alone.
        #expect(
            try plan(.choose(ordinal: 2), "omp-37-approval-session-a-after-down")
                == DialogActionPlan(steps: [.keys(["enter"])], confirmation: confirmation))
        // The panel's other answers keep their keys.
        for stem in ["omp-36-approval-edit-18-12", "omp-37-approval-session-a-after-down"] {
            #expect(try plan(.choose(ordinal: 1), stem).keys == ["ctrl+q"], "\(stem)")
            #expect(try plan(.choose(ordinal: 3), stem).keys == ["esc"], "\(stem)")
            #expect(try plan(.dismiss, stem).keys == ["esc"], "\(stem)")
        }
    }

    @Test("A draft under OMP's approval refuses only the session approval")
    func ompSessionApprovalRefusedUnderADraft() throws {
        let stem = "omp-37-approval-session-b-draft"
        let message =
            "Oh My Pi's input box holds a draft, which would take the arrow keys. Clear it in the terminal "
            + "to approve for the session."
        #expect(throws: DialogPlanError.unsupported(message)) {
            try plan(.choose(ordinal: 2), stem)
        }
        #expect(try plan(.choose(ordinal: 1), stem).keys == ["ctrl+q"])
        #expect(try plan(.choose(ordinal: 3), stem).keys == ["esc"])
    }

    @Test("No OMP approval plan sends a digit or ctrl+enter, and only the session row Enter")
    func ompApprovalPlansSendNoDigits() throws {
        let stems = [
            "omp-23-approval-a-ctrlq-early", "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc",
            "omp-36-approval-edit-18-12", "omp-37-approval-session-a-after-down", "omp-37-approval-session-b-draft",
        ]
        for stem in stems {
            let dialog = try dialog(stem)
            for ordinal in 0...10 {
                guard let plan = try? DialogActionPlanner.plan(.choose(ordinal: ordinal), for: dialog) else { continue }
                #expect(!plan.keys.contains { $0.contains(where: \.isNumber) || $0 == "ctrl+enter" }, "\(stem)")
                let isSession = dialog.option(ordinal)?.role == .approvePersistent
                #expect(plan.keys.contains("enter") == isSession, "\(stem) \(ordinal)")
            }
        }
    }

    @Test("No OMP plan before 18.12 sends a digit, Enter or ctrl+enter")
    func ompPlansNeverContainDigits() throws {
        for stem in ["omp-23-approval-a-ctrlq-early", "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc"] {
            let dialog = try dialog(stem)
            var actions: [DialogAction] = [
                .dismiss, .expandQuestions, .skipQuestion, .approvePlan(note: "note"), .submitSelection([1, 2]),
            ]
            for ordinal in 0...10 {
                actions += [
                    .choose(ordinal: ordinal), .amend(ordinal: ordinal, note: "note"),
                    .respond(ordinal: ordinal, text: "note"),
                ]
            }
            var keys: [String] = []
            for action in actions {
                guard let plan = try? DialogActionPlanner.plan(action, for: dialog) else { continue }
                #expect(plan.steps.allSatisfy { if case .keys = $0 { true } else { false } }, "\(stem) \(action)")
                keys += plan.keys
            }
            #expect(Set(keys) == ["ctrl+q", "esc"], "\(stem)")
            #expect(!keys.contains { $0.contains(where: \.isNumber) || $0.contains("enter") }, "\(stem)")
        }
    }

    @Test("An OMP question is answered by one arrow per row, each checked, then Enter")
    func ompQuestionChoosesByArrowsWithAFocusCheckPerRow() throws {
        #expect(
            try plan(.choose(ordinal: 3), "omp-27-ask-a-dialog")
                == DialogActionPlan(
                    steps: [
                        .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                        .keys(["enter"]),
                    ], confirmation: .fingerprintChangeOrUnblocked))
        #expect(
            try plan(.choose(ordinal: 1), "omp-27-ask-a-dialog", toolUseID: "call_1|fc_1")
                == DialogActionPlan(steps: [.keys(["enter"])], confirmation: .toolResult(id: "call_1|fc_1")))
        #expect(
            try plan(.choose(ordinal: 1), "omp-27-ask-c-after-down").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 1)), .keys(["enter"])])
        // Each tab turns to the next, the last to the review, which Enter
        // submits.
        #expect(
            try plan(.choose(ordinal: 2), "omp-28-ask2-a-dialog").steps
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"]), .expect(.page("size"))])
        #expect(
            try plan(.choose(ordinal: 1), "omp-28-ask2-b-after-enter-q1").steps
                == [.keys(["enter"]), .expect(.page("Review answers"))])
        #expect(
            try plan(.choose(ordinal: 1), "omp-28-ask2-c-submit-page", toolUseID: "call_2")
                == DialogActionPlan(steps: [.keys(["enter"])], confirmation: .toolResult(id: "call_2")))
        // Esc cancels the question and the turn.
        #expect(
            try plan(.dismiss, "omp-27-ask-a-dialog")
                == DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked))

        for stem in ["omp-27-ask-a-dialog", "omp-27-ask-c-after-down", "omp-28-ask2-a-dialog", "omp-28-ask2-c-submit-page"] {
            let dialog = try dialog(stem)
            for ordinal in 0...6 {
                guard let plan = try? DialogActionPlanner.plan(.choose(ordinal: ordinal), for: dialog) else { continue }
                #expect(!plan.keys.contains { $0.contains(where: \.isNumber) }, "\(stem) \(ordinal)")
                #expect(Set(plan.keys).isSubset(of: ["up", "down", "enter"]), "\(stem) \(ordinal)")
            }
        }
    }

    @Test("A draft in OMP's prompt refuses every answer but Stop")
    func guardedOMPQuestionRefusesEveryAnswerButStop() throws {
        let stem = "omp-29-guard-b-ask-with-draft"
        for action in [DialogAction.choose(ordinal: 1), .choose(ordinal: 2), .choose(ordinal: 3), .respond(ordinal: 3, text: "x")] {
            #expect(throws: DialogPlanError.composerDraft, "\(action)") { try plan(action, stem) }
        }
        #expect(try plan(.dismiss, stem).keys == ["esc"])
        // Once the draft is queued, the same question answers.
        #expect(try plan(.choose(ordinal: 2), "omp-29-guard-c-after-enter").keys == ["down", "enter"])
    }

    @Test("OMP's Other row and notes stay in the terminal")
    func ompOtherRowNeedsTheTerminal() throws {
        let message = DialogPlanError.unsupported(
            "Heeler doesn't type into Oh My Pi's questions. Write your own answer or a note in the terminal.")
        #expect(throws: message) { try plan(.choose(ordinal: 4), "omp-27-ask-a-dialog") }
        #expect(throws: message) { try plan(.respond(ordinal: 4, text: "kiwi"), "omp-27-ask-a-dialog") }
        #expect(throws: message) { try plan(.amend(ordinal: 1, note: "ripe"), "omp-27-ask-a-dialog") }
        #expect(throws: DialogPlanError.noSuchOption(5)) { try plan(.choose(ordinal: 5), "omp-27-ask-a-dialog") }
        #expect(throws: DialogPlanError.self) { try plan(.submitSelection([1, 2]), "omp-27-ask-a-dialog") }
    }

    // MARK: OpenCode

    @Test("OpenCode's Allow once has focus when the request shows, so Enter alone allows it")
    func openCodeAllowOncePressesEnter() throws {
        let confirmation = ConfirmationRule.fingerprintChangeOrUnblocked
        #expect(
            try plan(.choose(ordinal: 1), "opencode-10-permission-180")
                == DialogActionPlan(steps: [.keys(["enter"])], confirmation: confirmation))
        #expect(try plan(.choose(ordinal: 1), "opencode-37-permission-long-62").keys == ["enter"])
        // Moved off it in the terminal: back one checked arrow at a time.
        #expect(
            try plan(.choose(ordinal: 1), "opencode-12-permission-right2-180")
                == DialogActionPlan(
                    steps: [
                        .keys(["left"]), .expect(.focus(ordinal: 2)), .keys(["left"]), .expect(.focus(ordinal: 1)),
                        .keys(["enter"]),
                    ], confirmation: confirmation))
    }

    @Test("OpenCode's Always allow is one checked Right, then Enter")
    func openCodeAlwaysAllowMovesRightThenEnter() throws {
        #expect(
            try plan(.choose(ordinal: 2), "opencode-10-permission-180")
                == DialogActionPlan(
                    steps: [.keys(["right"]), .expect(.focus(ordinal: 2)), .keys(["enter"])],
                    confirmation: .fingerprintChangeOrUnblocked))
        #expect(try plan(.choose(ordinal: 2), "opencode-11-permission-right1-180").keys == ["enter"])
        #expect(try plan(.choose(ordinal: 2), "opencode-12-permission-right2-180").keys == ["left", "enter"])
    }

    /// Esc rejects the session's own call; a subagent's asks why first.
    @Test("OpenCode's Reject and Stop are Esc for a matched call, wherever the focus is")
    func openCodeRejectPressesEscOnlyForAMatchedRootCall() throws {
        let esc = DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)
        for stem in [
            "opencode-10-permission-180", "opencode-11-permission-right1-180", "opencode-12-permission-right2-180",
        ] {
            #expect(try plan(.choose(ordinal: 3), stem, toolUseID: "call_r") == esc, "\(stem)")
            #expect(try plan(.dismiss, stem, toolUseID: "call_r") == esc, "\(stem)")
        }
    }

    @Test("Without a matched call OpenCode's Reject stays in the terminal; allowing goes on")
    func openCodeRejectWithoutAMatchIsRefused() throws {
        let stem = "opencode-10-permission-180"
        let refusal = DialogPlanError.unsupported(
            "Reject this in the terminal: OpenCode asks why when a subagent's request is rejected.")
        #expect(throws: refusal) { try plan(.choose(ordinal: 3), stem) }
        #expect(throws: refusal) { try plan(.dismiss, stem) }
        #expect(try plan(.choose(ordinal: 1), stem).keys == ["enter"])
        #expect(try plan(.choose(ordinal: 2), stem).keys == ["right", "enter"])
        #expect(
            throws: DialogPlanError.unsupported(
                "OpenCode takes no note with a permission; reject, then tell OpenCode in the composer.")
        ) {
            try plan(.amend(ordinal: 3, note: "Use the other file"), stem, toolUseID: "call_r")
        }
        #expect(throws: DialogPlanError.noSuchOption(4)) { try plan(.choose(ordinal: 4), stem, toolUseID: "call_r") }
    }

    @Test("An OpenCode answer is its digit, which picks it and submits")
    func openCodeAnswersAQuestionByItsDigit() throws {
        #expect(
            try plan(.choose(ordinal: 2), "opencode-13-question-180")
                == DialogActionPlan(steps: [.keys(["2"])], confirmation: .fingerprintChangeOrUnblocked))
        #expect(try plan(.choose(ordinal: 1), "opencode-13-question-180", toolUseID: "call_q").keys == ["1"])
        #expect(try plan(.choose(ordinal: 2), "opencode-38-question-long-62").keys == ["2"])
    }

    @Test("OpenCode's own answer row and notes stay in the terminal")
    func openCodeTypeYourOwnAnswerIsRefused() throws {
        let stem = "opencode-13-question-180"
        let refusal = DialogPlanError.unsupported("Type your own answer in the terminal.")
        #expect(throws: refusal) { try plan(.choose(ordinal: 3), stem) }
        #expect(throws: refusal) { try plan(.respond(ordinal: 3, text: "green"), stem) }
        #expect(throws: refusal) { try plan(.amend(ordinal: 1, note: "dark red"), stem) }
        #expect(throws: DialogPlanError.noSuchOption(4)) { try plan(.choose(ordinal: 4), stem) }
        #expect(throws: DialogPlanError.self) { try plan(.submitSelection([1]), stem) }
    }

    @Test("Stop dismisses an OpenCode question with Esc only for a matched call")
    func openCodeDismissPressesEscOnlyForAMatchedCall() throws {
        let stem = "opencode-13-question-180"
        #expect(
            try plan(.dismiss, stem, toolUseID: "call_q")
                == DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked))
        #expect(
            throws: DialogPlanError.unsupported(
                "Dismiss this question in the terminal: Heeler can't match it to OpenCode's call.")
        ) {
            try plan(.dismiss, stem)
        }
    }

    @Test("Moves along a row send one checked left or right arrow per option")
    func horizontalMovesCheckFocusAfterEachKey() throws {
        var right = StepBuilder(dialog: try dialog("opencode-10-permission-180"))
        try right.move(to: 3, axis: .horizontal)
        #expect(
            right.steps == [
                .keys(["right"]), .expect(.focus(ordinal: 2)), .keys(["right"]), .expect(.focus(ordinal: 3)),
            ])
        #expect(right.focus == 3)
        var left = StepBuilder(dialog: try dialog("opencode-11-permission-right1-180"))
        try left.move(to: 1, axis: .horizontal)
        #expect(left.steps == [.keys(["left"]), .expect(.focus(ordinal: 1))])

        // Every OpenCode plan checks the focus after each arrow.
        for stem in ScreenFixture.opencode {
            guard let dialog = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .opencode).dialog
            else { continue }
            let actions = dialog.options.map { DialogAction.choose(ordinal: $0.ordinal) } + [.dismiss]
            for action in actions {
                guard let plan = try? DialogActionPlanner.plan(action, for: dialog, toolUseID: "call_1") else {
                    continue
                }
                #expect(plan.keys.allSatisfy(HerdrKeyGrammar.accepts), "\(stem) \(action)")
                for (index, step) in plan.steps.enumerated() {
                    guard case .keys(let keys) = step, keys.contains(where: ["left", "right", "up", "down"].contains)
                    else { continue }
                    let next = plan.steps.indices.contains(index + 1) ? plan.steps[index + 1] : nil
                    let checksFocus = if case .expect(.focus)? = next { true } else { false }
                    #expect(checksFocus, "\(stem) \(action): an arrow without a focus check")
                }
            }
        }
    }

    // MARK: Generic card, text and keys

    @Test("The generic card's buttons press the digits it lists")
    func genericCard() throws {
        let unknown = try #require(
            ClaudeDialogParser.parse(ClaudeDialogRows.screen(title: "Tool use", options: ["Yes", "No"])).excerpt)
        #expect(
            try DialogActionPlanner.plan(number: 2, for: unknown, program: .claude)
                == DialogActionPlan(steps: [.keys(["2"])], confirmation: .fingerprintChange))
        #expect(throws: DialogPlanError.noSuchOption(3)) {
            try DialogActionPlanner.plan(number: 3, for: unknown, program: .claude)
        }

        // A reverse-video cursor means a field has focus.
        let withCursor = try #require(
            ClaudeDialogParser.parse(
                ClaudeDialogRows.screen(
                    title: "Tool use", options: ["Yes", "No, " + SGR.reverse + "a" + SGR.reset + "nd tell Claude"],
                    focused: 2)
            ).excerpt)
        #expect(
            throws: DialogPlanError.unsupported(
                "A text field in the dialog has the cursor, so a digit would be typed into it.")
        ) {
            try DialogActionPlanner.plan(number: 1, for: withCursor, program: .claude)
        }

        let codex = try #require(
            CodexDialogParser.parse(
                ScreenFixture.synthetic(
                    ["  " + SGR.bold + "Allow the tool to read the file?" + SGR.reset, ""] + CodexRows.approvalOptions
                        + ["", CodexRows.approvalFooter])
            ).excerpt)
        #expect(
            try DialogActionPlanner.plan(number: 1, for: codex, program: .codex)
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .fingerprintChangeOrUnblocked))
    }

    @Test("Field text is one trimmed line without control characters")
    func fieldText() throws {
        #expect(try DialogActionPlanner.fieldText("  Use q.txt  ") == "Use q.txt")
        #expect(throws: DialogPlanError.emptyText) { try DialogActionPlanner.fieldText("   ") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\ntwo") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\r\ntwo") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\u{2028}two") }
        #expect(throws: DialogPlanError.unsafeText) { try DialogActionPlanner.fieldText("one\ttwo") }
        #expect(throws: DialogPlanError.unsafeText) { try DialogActionPlanner.fieldText("one\u{1B}[Atwo") }
    }

    @Test("herdr's key grammar")
    func keyGrammar() {
        for key in [
            "enter", "esc", "tab", "shift+tab", "up", "down", "shift+left", "ctrl+]", "1", "9", "f12", "plus", "+",
            "C-c", "Enter", "ctrl+shift+a", "space", "backspace",
        ] {
            #expect(HerdrKeyGrammar.accepts(key), "\(key)")
        }
        for key in ["home", "end", "pageup", "pagedown", "delete", "", " ", "ctrl+", "ctrl+a+b", "shift", "f256"] {
            #expect(!HerdrKeyGrammar.accepts(key), "\(key)")
        }
    }

    @Test("Moves send one checked down or up arrow per row and need a focused row")
    func verticalMovesAreUnchanged() throws {
        let dialog = try dialog("omp-27-ask-a-dialog")
        var down = StepBuilder(dialog: dialog)
        try down.move(to: 3)
        #expect(
            down.steps == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3))])
        #expect(down.focus == 3)
        try down.move(to: 3)
        #expect(down.steps.count == 4)

        var up = StepBuilder(dialog: try self.dialog("omp-27-ask-c-after-down"))
        try up.move(to: 1)
        #expect(up.steps == [.keys(["up"]), .expect(.focus(ordinal: 1))])

        let unfocused = BlockedDialog(
            kind: dialog.kind, title: dialog.title, sourceSuffix: dialog.sourceSuffix,
            positionLabel: dialog.positionLabel, body: dialog.body, progress: dialog.progress, options: dialog.options,
            rows: dialog.rows, fingerprint: dialog.fingerprint, focus: DialogFocusState(), subject: dialog.subject)
        #expect(throws: DialogPlanError.noFocus) {
            var builder = StepBuilder(dialog: unfocused)
            try builder.move(to: 2)
        }
    }

    @Test(
        "Plans for every captured dialog use herdr's keys and check after each arrow and paste",
        arguments: ScreenFixture.all + ScreenFixture.agy)
    func planShapes(stem: String) throws {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        guard let dialog = result.dialog else { return }
        let answers = Set(dialog.options.filter { $0.role == .answer }.map(\.ordinal))
        var actions: [DialogAction] = [
            .dismiss, .expandQuestions, .skipQuestion, .approvePlan(note: "note"), .submitSelection(answers),
            .submitSelection(answers, text: "note"), .submitSelection(dialog.focus.checked, text: "note"),
        ]
        for option in dialog.options {
            actions += [
                .choose(ordinal: option.ordinal), .amend(ordinal: option.ordinal, note: "note"),
                .respond(ordinal: option.ordinal, text: "note"),
            ]
        }
        var planned = 0
        for action in actions {
            guard let plan = try? DialogActionPlanner.plan(action, for: dialog) else { continue }
            planned += 1
            for key in plan.keys {
                #expect(HerdrKeyGrammar.accepts(key), "\(stem) \(action): \(key)")
            }
            for (index, step) in plan.steps.enumerated() {
                let next = plan.steps.indices.contains(index + 1) ? plan.steps[index + 1] : nil
                switch step {
                case .keys(["up"]), .keys(["down"]):
                    let checksFocus = if case .expect(.focus)? = next { true } else { false }
                    #expect(checksFocus, "\(stem) \(action): an arrow without a focus check")
                case .paste:
                    let checksText =
                        switch next {
                        case .expect(.inputText)?, .expect(.notes)?: true
                        default: false
                        }
                    #expect(checksText, "\(stem) \(action): a paste without a check")
                default:
                    break
                }
            }
        }
        #expect(planned > 0 || dialog.hasTypedText, "\(stem): no action planned")
    }
}

@Suite("Dialog expectations and confirmations")
struct DialogExpectationTests {
    private func observe(
        _ stem: String, activity: ChatAgentActivity = .blocked, resolved: Set<String> = []
    ) throws -> DialogObservation {
        DialogObservation(
            screen: try ScreenFixture.screen(stem), program: ScreenFixture.program(stem), activity: activity,
            resolvedToolUseIDs: resolved)
    }

    private func fingerprint(_ stem: String) throws -> DialogFingerprint {
        try #require(try observe(stem).result.dialog?.fingerprint)
    }

    /// Whether capture `stem` shows `expectation` for the dialog last read
    /// with `fingerprint`.
    private func meets(
        _ expectation: DialogExpectation, _ stem: String, _ fingerprint: DialogFingerprint
    ) throws -> Bool {
        expectation.isMet(by: try observe(stem), fingerprint: fingerprint)
    }

    private func confirms(
        _ rule: ConfirmationRule, _ stem: String, _ fingerprint: DialogFingerprint,
        activity: ChatAgentActivity = .blocked, resolved: Set<String> = []
    ) throws -> Bool {
        rule.isMet(by: try observe(stem, activity: activity, resolved: resolved), fingerprint: fingerprint)
    }

    @Test("Each step of the probe's note on No meets its check")
    func noteOnNo() throws {
        let bash = try fingerprint("claude-02-c1-bash-blocked")
        let note = "Do not create it; reply with the single word skipped"
        #expect(try meets(.focus(ordinal: 4), "claude-03-c1-focus-no", bash))
        #expect(try !meets(.focus(ordinal: 4), "claude-02-c1-bash-blocked", bash))
        #expect(try meets(.feedbackMode(ordinal: 4), "claude-04-c1-tab-on-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-03-c1-focus-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-05-c1-pasted-feedback", bash))
        #expect(try meets(.inputText(note), "claude-05-c1-pasted-feedback", bash))
        #expect(try !meets(.inputText(note), "claude-04-c1-tab-on-no", bash))
        #expect(try !meets(.inputText("Do not create it"), "claude-05-c1-pasted-feedback", bash))
    }

    /// The checks Antigravity CLI's plans make, against the screens agy
    /// drew after each of the keys sent live.
    @Test("Each step of Antigravity CLI's note, answer and selection meets its check")
    func agySteps() throws {
        let command = try fingerprint("agy-108-perm-run-command-62x41")
        let note = "then also reply with the word kiwi"
        #expect(try meets(.feedbackMode(ordinal: 1), "agy-109-perm-run-command-amend-62x41", command))
        #expect(try !meets(.feedbackMode(ordinal: 1), "agy-108-perm-run-command-62x41", command))
        #expect(try !meets(.feedbackMode(ordinal: 1), "agy-110-perm-run-command-amend-typed-62x41", command))
        #expect(try meets(.inputText(note), "agy-110-perm-run-command-amend-typed-62x41", command))
        #expect(try !meets(.inputText(note), "agy-109-perm-run-command-amend-62x41", command))

        let pet = try fingerprint("agy-104-ask-question-writein-after-digit-62x41")
        #expect(try meets(.feedbackMode(ordinal: 3), "agy-104-ask-question-writein-after-digit-62x41", pet))
        #expect(try meets(.inputText("a small hamster"), "agy-105-ask-question-writein-typed-62x41", pet))

        let colors = try fingerprint("agy-100-ask-question-multiselect-62x41")
        #expect(try meets(.checked([2]), "agy-101-ask-question-multiselect-after-digit2-62x41", colors))
        #expect(try meets(.checked([3]), "agy-102-ask-question-multiselect-after-3-2-62x41", colors))
        #expect(try !meets(.checked([2]), "agy-100-ask-question-multiselect-62x41", colors))

        let first = try fingerprint("agy-44-ask-question-multi-120x40")
        #expect(try meets(.page("Question 2/2"), "agy-45-ask-question-multi-q2-120x40", first))
        #expect(try meets(.page("Question 2/2"), "agy-114-ask-question-multiselect-q1-after-enter-62x41", first))
        #expect(try !meets(.page("Question 2/2"), "agy-44-ask-question-multi-120x40", first))

        // A written answer with a selection (2026-11-09, read through tmux).
        let fresh = "agy-154-ask-question-multiselect-120x40"
        let checked = "agy-155-ask-question-multiselect-checked-120x40"
        let open = "agy-156-ask-question-multiselect-writein-open-checked-120x40"
        let typed = "agy-157-ask-question-multiselect-writein-typed-checked-120x40"
        let onRow = "agy-160-ask-question-multiselect-writein-selected-120x40"
        let openedByEnter = "agy-161-ask-question-multiselect-writein-open-by-enter-120x40"
        let typedAlone = "agy-162-ask-question-multiselect-writein-alone-typed-120x40"
        let fruits = try fingerprint(fresh)
        #expect(try meets(.checked([1]), checked, fruits))
        #expect(try meets(.checked([1]), open, fruits))
        #expect(try meets(.feedbackMode(ordinal: 4), open, fruits))
        #expect(try meets(.feedbackMode(ordinal: 4), openedByEnter, fruits))
        #expect(try !meets(.feedbackMode(ordinal: 4), fresh, fruits))
        #expect(try !meets(.feedbackMode(ordinal: 4), onRow, fruits))
        #expect(try !meets(.feedbackMode(ordinal: 4), typed, fruits))
        #expect(try meets(.inputText("mango"), typed, fruits))
        #expect(try meets(.inputText("mango"), typedAlone, fruits))
        #expect(try !meets(.inputText("mango"), open, fruits))

        let firstPage = "agy-163-ask-question-multiselect-q1-of-2-checked-120x40"
        let pageOpen = "agy-164-ask-question-multiselect-q1-of-2-writein-open-120x40"
        let pageTyped = "agy-166-ask-question-multiselect-q1-of-2-writein-typed-120x40"
        let page = try fingerprint(firstPage)
        #expect(try meets(.feedbackMode(ordinal: 4), pageOpen, page))
        #expect(try !meets(.feedbackMode(ordinal: 4), firstPage, page))
        #expect(try meets(.inputText("mango"), pageTyped, page))
        #expect(try !meets(.page("Question 2/2"), pageTyped, page))
        #expect(try meets(.page("Question 2/2"), "agy-167-ask-question-q2-after-multiselect-writein-120x40", page))
        #expect(try meets(.page("Question 2/2"), "agy-165-ask-question-q2-after-empty-writein-enter-120x40", page))
    }

    /// herdr reports agy idle while a field is open, so only the dialog
    /// leaving confirms an answer.
    @Test("Antigravity CLI confirms only by the dialog leaving")
    func agyConfirmation() throws {
        let command = try fingerprint("agy-108-perm-run-command-62x41")
        for stem in ["agy-109-perm-run-command-amend-62x41", "agy-110-perm-run-command-amend-typed-62x41"] {
            #expect(try !confirms(.fingerprintChange, stem, command, activity: .idle), "\(stem)")
        }
        #expect(try confirms(.fingerprintChange, "agy-115-ask-question-single-after-esc-62x41", command, activity: .idle))
        #expect(try confirms(.fingerprintChange, "agy-111-perm-run-command-tab-on-no-62x41", command))

        // A multi-select question's field holding text is the same dialog.
        let fruits = try fingerprint("agy-154-ask-question-multiselect-120x40")
        let typed = "agy-157-ask-question-multiselect-writein-typed-checked-120x40"
        #expect(try !confirms(.fingerprintChange, typed, fruits, activity: .idle))
        #expect(try confirms(.fingerprintChange, "agy-159-working-after-multiselect-writein-120x40", fruits))
    }

    @Test("A note cut off at the phone's width still meets its check")
    func truncatedNoteOnNo() throws {
        let bash = try fingerprint("claude-32-c7-phone-bash-blocked")
        let note = "Do not create it; reply with the single word skipped"
        #expect(try meets(.focus(ordinal: 4), "claude-33-c7-phone-focus-no", bash))
        #expect(try meets(.feedbackMode(ordinal: 4), "claude-34-c7-phone-tab-on-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-35-c7-phone-pasted-truncated", bash))
        #expect(try meets(.inputText(note), "claude-35-c7-phone-pasted-truncated", bash))
        let other = "Do not create it; reply with one word"
        #expect(try !meets(.inputText(other), "claude-35-c7-phone-pasted-truncated", bash))
        #expect(try !meets(.inputText("Do not"), "claude-35-c7-phone-pasted-truncated", bash))
        let dialog = try #require(try observe("claude-35-c7-phone-pasted-truncated").result.dialog)
        #expect(dialog.option(4)?.label == "No")
        #expect(dialog.focus.feedbackOrdinal == 4)
    }

    @Test("An empty note drawn without its cursor cell still reads as the placeholder")
    func emptyNoteWithoutTheCursor() throws {
        let bash = try fingerprint("claude-32-c7-phone-bash-blocked")
        // claude-34 with the cursor cell drawn dim like the rest.
        let text = try ScreenFixture.text("claude-34-c7-phone-tab-on-no")
        let cursorless = text.replacingOccurrences(of: "\u{1B}[7ma", with: "\u{1B}[2ma")
        try #require(cursorless != text)
        let observation = DialogObservation(
            screen: ANSIScreenDecoder.decode(cursorless), program: .claude, activity: .blocked)
        #expect(DialogExpectation.feedbackMode(ordinal: 4).isMet(by: observation, fingerprint: bash))
    }

    @Test("A note wrapped at the phone's width, with the cursor on its last row, meets its check")
    func wrappedNoteOnYes() throws {
        let bash = try fingerprint("claude-36-c7-phone-yes-blocked")
        let note = "after it succeeds, reply with the single word created"
        #expect(try meets(.focus(ordinal: 1), "claude-36-c7-phone-yes-blocked", bash))
        #expect(try meets(.inputText(note), "claude-37-c7-phone-yes-pasted-wrapped", bash))
        #expect(try !meets(.inputText("after it succeeds"), "claude-37-c7-phone-yes-pasted-wrapped", bash))
        let dialog = try #require(try observe("claude-37-c7-phone-yes-pasted-wrapped").result.dialog)
        #expect(dialog.option(1)?.label == "Yes")
        #expect(dialog.focus.feedbackOrdinal == 1)
        #expect(dialog.options.count == 4)
    }

    @Test("A check about the same dialog fails once the dialog changed")
    func changedDialog() throws {
        let first = try fingerprint("claude-30-par-first")
        #expect(try meets(.focus(ordinal: 1), "claude-30-par-first", first))
        // The next request also has focus on 1, but asks about another command.
        #expect(try !meets(.focus(ordinal: 1), "claude-31-par-second", first))
    }

    @Test("Checks, pages, notes and the queued notice")
    func otherChecks() throws {
        let colors = try fingerprint("claude-08-c4-auq-q1")
        #expect(try meets(.checked([1, 3]), "claude-09-c4-toggled", colors))
        #expect(try !meets(.checked([1]), "claude-09-c4-toggled", colors))
        #expect(try meets(.focus(ordinal: 5), "claude-10-c4-focus-next", colors))
        #expect(try meets(.page("Size"), "claude-11-c4-q2", colors))
        #expect(try !meets(.page("Size"), "claude-10-c4-focus-next", colors))
        #expect(try meets(.page("Review your answers"), "claude-14-c4-review", colors))

        let size = try fingerprint("codex-05-x3-q2")
        #expect(try meets(.page("Question 2/2"), "codex-05-x3-q2", fingerprint("codex-04-x3-q1")))
        #expect(try meets(.notes("Medium please"), "codex-07-x3-q2-pasted", size))
        #expect(try !meets(.notes("Medium please"), "codex-06-x3-q2-up", size))
        let fruit = try fingerprint("codex-09-x4-expanded")
        #expect(try meets(.queuedNotice("Pick a fruit"), "codex-10-x4-after-digit", fruit))
        #expect(try !meets(.queuedNotice("Pick a fruit"), "codex-09-x4-expanded", fruit))
    }

    @Test("Claude confirms by the tool result or by the dialog leaving")
    func claudeConfirmation() throws {
        let bash = try fingerprint("claude-02-c1-bash-blocked")
        let rule = ConfirmationRule.toolResult(id: "toolu_01")
        #expect(try !confirms(rule, "claude-03-c1-focus-no", bash))
        #expect(try confirms(rule, "claude-03-c1-focus-no", bash, resolved: ["toolu_01"]))
        #expect(try confirms(rule, "claude-29-c3-after-immediate", bash, activity: .working))
        // Leaving Blocked alone does not confirm a Claude dialog.
        #expect(try !confirms(.fingerprintChange, "claude-03-c1-focus-no", bash, activity: .idle))
        #expect(try confirms(.fingerprintChange, "claude-31-par-second", fingerprint("claude-30-par-first")))
    }

    @Test("Codex confirms by the dialog leaving, the Agent leaving Blocked, or the queued notice")
    func codexConfirmation() throws {
        let first = try fingerprint("codex-13-par-first")
        let rule = ConfirmationRule.fingerprintChangeOrUnblocked
        #expect(try !confirms(rule, "codex-13-par-first", first))
        #expect(try !confirms(rule, "codex-13-par-first", first, activity: .unknown))
        #expect(try confirms(rule, "codex-13-par-first", first, activity: .working))
        #expect(try confirms(rule, "codex-13-par-first", first, activity: .idle))
        #expect(try confirms(rule, "codex-14-par-second", first))

        let fruit = try fingerprint("codex-09-x4-expanded")
        #expect(try confirms(.queuedNotice("Pick a fruit"), "codex-10-x4-after-digit", fruit))
        #expect(try !confirms(.queuedNotice("Pick a fruit"), "codex-09-x4-expanded", fruit))
    }
}
