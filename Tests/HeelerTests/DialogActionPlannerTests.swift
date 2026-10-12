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

    @Test("Codex question: a digit answers and moves on; notes go on None of the above")
    func codexQuestion() throws {
        let note = "Medium please"
        #expect(try plan(.choose(ordinal: 2), "codex-04-x3-q1").steps == [.keys(["2"]), .expect(.page("Question 2/2"))])
        #expect(try plan(.choose(ordinal: 1), "codex-05-x3-q2").steps == [.keys(["1"])])
        #expect(
            try plan(.respond(ordinal: 3, text: note), "codex-05-x3-q2").steps
                == [
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .paste(note), .expect(.notes(note)), .keys(["enter"]),
                ])
        // The probe's path: `up` had already reached None of the above.
        #expect(
            try plan(.respond(ordinal: 3, text: note), "codex-06-x3-q2-up").steps
                == [.paste(note), .expect(.notes(note)), .keys(["enter"])])
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

    @Test(
        "Plans for every captured dialog use herdr's keys and check after each arrow and paste",
        arguments: ScreenFixture.all)
    func planShapes(stem: String) throws {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        guard let dialog = result.dialog else { return }
        var actions: [DialogAction] = [
            .dismiss, .expandQuestions, .skipQuestion, .approvePlan(note: "note"),
            .submitSelection(Set(dialog.options.filter { $0.role == .answer }.map(\.ordinal))),
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
