import Foundation
import Testing

@testable import Heeler

/// Grok Build's keys for a card action, on Grok Build 1.0.62 captures and
/// synthetic cards. A row's key selects and submits it at once.
@Suite("Grok Build dialog planner")
struct GrokDialogPlannerTests {
    private static let unfocused = DialogPlanError.unsupported(
        "Grok Build's card doesn't have focus. Answer it in the terminal.")
    private static let typedAnswer = DialogPlanError.unsupported(
        "Heeler doesn't type into Grok Build's questions. Write your own answer in the terminal.")

    private static let cards = [
        "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-25-fork-question", "grok-35-permission-subagent-62",
        "grok-36-permission-command-40", "grok-37-permission-command-62", "grok-38-fork-question-62",
        "synthetic-edit-permission-session-cut", "synthetic-fork-cursor-on-always-worktree",
        "synthetic-fork-cursor-on-field", "synthetic-permission-40",
        "synthetic-permission-40-terminal-theme", "synthetic-question-40", "synthetic-question-62",
        "synthetic-question-ten-answers", "synthetic-question-cursor-on-field", "synthetic-subagents-40",
    ]

    private func plan(_ action: DialogAction, on dialog: BlockedDialog) throws(DialogPlanError) -> DialogActionPlan {
        try DialogActionPlanner.plan(action, for: dialog, toolUseID: "call-1")
    }

    private func ordinal(of role: DialogOptionRole, in dialog: BlockedDialog) throws -> Int {
        try #require(dialog.options.first { $0.role == role }?.ordinal)
    }

    /// The digit of `Yes, proceed`, `Yes` or a subagent's `Yes, send once`,
    /// whatever the card's shape. herdr stays Blocked a moment after the
    /// approval, and Grok records none, so the card leaving the screen
    /// confirms it.
    @Test(arguments: [
        ("grok-12-permission-command", "3"), ("grok-13-permission-compound", "2"), ("grok-14-permission-edit", "3"),
        ("grok-35-permission-subagent-62", "2"), ("grok-36-permission-command-40", "3"),
        ("grok-37-permission-command-62", "3"), ("synthetic-permission-40", "3"),
    ])
    func approvesWithTheProceedRowsKey(stem: String, key: String) throws {
        let dialog = try GrokCards.dialog(stem)

        let plan = try self.plan(.choose(ordinal: try ordinal(of: .approve, in: dialog)), on: dialog)

        #expect(plan.steps == [.keys([key])])
        #expect(plan.confirmation == .fingerprintChangeOrUnblocked)
        #expect(!plan.focusesComposer)
        // The rule's row by its own digit.
        if let persistent = dialog.options.first(where: { $0.role == .approvePersistent }) {
            let digit = "\(persistent.number ?? 0)"
            #expect(try self.plan(.choose(ordinal: persistent.ordinal), on: dialog).keys == [digit])
        }
    }

    /// A plain reject ends the whole turn.
    @Test func deniesWithTheRejectRowsKey() throws {
        for (stem, key) in [
            ("grok-12-permission-command", "4"), ("grok-13-permission-compound", "3"), ("grok-14-permission-edit", "4"),
            ("grok-35-permission-subagent-62", "3"), ("grok-36-permission-command-40", "4"),
            ("grok-37-permission-command-62", "4"),
        ] {
            let dialog = try GrokCards.dialog(stem)

            let plan = try self.plan(.choose(ordinal: try ordinal(of: .decline, in: dialog)), on: dialog)

            #expect(plan.steps == [.keys([key])], "\(stem)")
            #expect(plan.confirmation == .fingerprintChangeOrUnblocked, "\(stem)")
        }
    }

    /// Stop and the folded card's Deny press the reject row too: Esc would
    /// only park the keyboard in the scrollback.
    @Test func dismissPressesTheRejectRow() throws {
        #expect(try plan(.dismiss, on: try GrokCards.dialog("grok-12-permission-command")).keys == ["4"])
        #expect(try plan(.dismiss, on: try GrokCards.dialog("grok-13-permission-compound")).keys == ["3"])
        #expect(try plan(.dismiss, on: try GrokCards.dialog("grok-35-permission-subagent-62")).keys == ["3"])
    }

    /// The rows Chat leaves to the terminal, such as always-approve mode,
    /// one Up press from a subagent's `Yes, send once`, `Never allow:`, and
    /// a lasting rule Grok cut to fit: no action presses their keys.
    @Test(arguments: [
        ("grok-12-permission-command", ["1", "5"]), ("grok-13-permission-compound", ["1"]),
        ("grok-14-permission-edit", ["1"]), ("grok-35-permission-subagent-62", ["1"]),
        ("grok-36-permission-command-40", ["1", "2", "5"]), ("grok-37-permission-command-62", ["1", "5"]),
        ("synthetic-edit-permission-session-cut", ["1", "2"]), ("grok-38-fork-question-62", ["3", "4", "z"]),
        ("synthetic-fork-cursor-on-always-worktree", ["3", "4", "z"]),
    ])
    func neverPressesARowLeftToTheTerminal(stem: String, withheld: [String]) throws {
        let dialog = try GrokCards.dialog(stem)
        var actions: [DialogAction] = [.dismiss, .skipQuestion, .expandQuestions, .approvePlan(note: "go")]
        for option in dialog.options {
            actions += [
                .choose(ordinal: option.ordinal), .amend(ordinal: option.ordinal, note: "note"),
                .respond(ordinal: option.ordinal, text: "text"),
            ]
        }

        let pressed = actions.compactMap { try? plan($0, on: dialog) }.flatMap(\.keys)

        #expect(Set(pressed) == Set(dialog.options.compactMap { $0.number.map(String.init) }))
        #expect(Set(pressed).isDisjoint(with: withheld))
    }

    /// Esc parks focus or keeps a cancelled turn running, Ctrl+C cancels
    /// or skips, Ctrl+Y hides a question unanswered, and `e`, ←, → and
    /// Ctrl+O change the rule or the mode. A letter on a permission opens
    /// the reject row's feedback field. No action plans any of them.
    @Test func neverSendsEscOrCtrlC() throws {
        let forbidden: Set = ["esc", "ctrl+c", "ctrl+y", "ctrl+o", "e", "left", "right", "shift+x", "enter"]
        for stem in Self.cards {
            let dialog = try GrokCards.dialog(stem)
            var actions: [DialogAction] = [
                .dismiss, .skipQuestion, .expandQuestions, .approvePlan(note: "go"), .submitSelection([1]),
            ]
            for option in dialog.options {
                actions += [
                    .choose(ordinal: option.ordinal), .amend(ordinal: option.ordinal, note: "note"),
                    .respond(ordinal: option.ordinal, text: "text"),
                ]
            }
            for action in actions {
                guard let plan = try? self.plan(action, on: dialog) else { continue }
                #expect(plan.keys.count == 1, "\(stem) \(action)")
                #expect(plan.keys.allSatisfy { !forbidden.contains($0) }, "\(stem) \(action): \(plan.keys)")
                if dialog.kind == .grokPermission {
                    #expect(plan.keys.allSatisfy { $0.count == 1 && $0.first?.isNumber == true }, "\(stem) \(action)")
                }
            }
        }
    }

    /// A digit, or a letter from `a`, selects the answer and submits the
    /// single question.
    @Test(arguments: [
        ("grok-15-question", 1, "1"), ("grok-15-question", 2, "2"), ("synthetic-question-40", 2, "2"),
        ("synthetic-question-ten-answers", 10, "a"),
    ])
    func answersByTheRowKey(stem: String, ordinal: Int, key: String) throws {
        let dialog = try GrokCards.dialog(stem)

        let plan = try self.plan(.choose(ordinal: ordinal), on: dialog)

        #expect(plan.steps == [.keys([key])])
        #expect(plan.confirmation == .fingerprintChangeOrUnblocked)
    }

    /// Heeler types nothing into a question. With the cursor on the answer
    /// field, any key but a space would land in the field, so every answer
    /// waits until the cursor leaves it.
    @Test func refusesTheFreeTextRow() throws {
        let dialog = try GrokCards.dialog("grok-15-question")
        let field = try ordinal(of: .otherText, in: dialog)

        for action in [
            DialogAction.choose(ordinal: field), .respond(ordinal: field, text: "Later"),
            .amend(ordinal: 1, note: "Later"),
        ] {
            #expect(throws: Self.typedAnswer, "\(action)") { try plan(action, on: dialog) }
        }
        #expect(throws: DialogPlanError.unsupported("Skip Grok Build's question in the terminal.")) {
            try plan(.skipQuestion, on: dialog)
        }
        let onField = try GrokCards.dialog("synthetic-question-cursor-on-field")
        #expect(onField.focus.focusedOrdinal == field)
        #expect(
            throws: DialogPlanError.unsupported(
                "Grok Build's cursor is on its answer field, where a key would be typed. Answer in the terminal.")
        ) { try plan(.choose(ordinal: 1), on: onField) }
    }

    /// `/fork`'s question: `1` forks into a new worktree and `2` in the
    /// current directory, each selecting and submitting its row, also with
    /// the cursor on a row Chat leaves to the terminal. Nothing types into
    /// the answer field, and the card has nothing to stop.
    @Test(arguments: [
        "grok-25-fork-question", "grok-38-fork-question-62", "synthetic-fork-cursor-on-always-worktree",
    ])
    func answersTheForkQuestionByItsRowKeys(stem: String) throws {
        let dialog = try GrokCards.dialog(stem)
        let field = try ordinal(of: .otherText, in: dialog)

        #expect(try plan(.choose(ordinal: 1), on: dialog).steps == [.keys(["1"])])
        #expect(try plan(.choose(ordinal: 2), on: dialog).steps == [.keys(["2"])])
        #expect(try plan(.choose(ordinal: 2), on: dialog).confirmation == .fingerprintChangeOrUnblocked)
        for action in [
            DialogAction.choose(ordinal: field), .respond(ordinal: field, text: "a"), .amend(ordinal: 1, note: "a"),
        ] {
            #expect(throws: Self.typedAnswer, "\(stem) \(action)") { try plan(action, on: dialog) }
        }
        for action in [DialogAction.dismiss, .skipQuestion] {
            #expect(throws: DialogPlanError.self, "\(stem) \(action)") { try plan(action, on: dialog) }
        }
    }

    /// With the cursor on the fork question's answer field, a key would be
    /// typed there, so Yes and No wait for the terminal.
    @Test func refusesTheForkQuestionWithTheCursorOnItsField() throws {
        let dialog = try GrokCards.dialog("synthetic-fork-cursor-on-field")
        #expect(dialog.focus.focusedOrdinal == 3)

        for ordinal in [1, 2] {
            #expect(
                throws: DialogPlanError.unsupported(
                    "Grok Build's cursor is on its answer field, where a key would be typed. Answer in the terminal.")
            ) { try plan(.choose(ordinal: ordinal), on: dialog) }
        }
    }

    /// `1` stops the turn and its subagents; `2` ends the turn and keeps
    /// them. Esc would keep the turn running, so nothing sends it.
    @Test func stopsOrKeepsSubagentsByTheirKeys() throws {
        let dialog = try GrokCards.dialog("grok-16-subagent-panel")

        #expect(try plan(.choose(ordinal: 1), on: dialog).steps == [.keys(["1"])])
        #expect(try plan(.choose(ordinal: 2), on: dialog).steps == [.keys(["2"])])
        #expect(try plan(.choose(ordinal: 2), on: dialog).confirmation == .fingerprintChangeOrUnblocked)
        #expect(throws: DialogPlanError.self) { try plan(.dismiss, on: dialog) }
    }

    /// A key selects its row wherever the cursor is: with the cursor on
    /// the always-approve row, a `Never allow:` row or an `Always` row,
    /// which Chat leaves to the terminal, each row Chat offers still goes
    /// by its own key.
    @Test(arguments: [
        ("synthetic-permission-cursor-on-always-approve", ["2", "3", "4"]),
        ("synthetic-permission-cursor-on-never-allow", ["2", "3", "4"]),
        ("synthetic-subagents-cursor-on-always-stop", ["1", "2"]),
    ])
    func answersWhereverTheCursorIs(stem: String, keys: [String]) throws {
        let dialog = try GrokCards.dialog(stem)
        #expect(dialog.focus.focusedOrdinal == nil)

        let plans = try dialog.options.map { option in try plan(.choose(ordinal: option.ordinal), on: dialog) }

        #expect(plans.map(\.steps) == keys.map { [DialogStep.keys([$0])] })
        if dialog.kind == .grokPermission {
            #expect(try plan(.dismiss, on: dialog).keys == ["4"])
        }
    }

    /// With no row showing the cursor, it may be on the answer field, so
    /// the answers wait for the terminal.
    @Test func refusesAnAnswerWhileTheCursorIsUnseen() throws {
        let dialog = try GrokCards.dialog("synthetic-question-cursor-unseen")
        #expect(dialog.focus == DialogFocusState())

        #expect(
            throws: DialogPlanError.unsupported(
                "Heeler can't see Grok Build's cursor, which may be on the answer field, where a key would be "
                    + "typed. Answer in the terminal.")
        ) { try plan(.choose(ordinal: 1), on: dialog) }
    }

    /// Esc left the keyboard in the scrollback: keys would miss the card.
    @Test func refusesAnUnfocusedCard() throws {
        for stem in ["synthetic-unfocused-permission", "synthetic-unfocused-question", "synthetic-unfocused-fork"] {
            let dialog = try GrokCards.dialog(stem)
            for action in [DialogAction.choose(ordinal: 1), .choose(ordinal: 2), .dismiss] {
                #expect(throws: Self.unfocused, "\(stem) \(action)") { try plan(action, on: dialog) }
            }
        }
    }

    /// The other programs' planners turn Grok Build's cards away.
    @Test func otherPlannersRefuseGrokCards() throws {
        let dialog = try GrokCards.dialog("grok-12-permission-command")

        #expect(throws: DialogPlanError.unsupported("Not an Oh My Pi dialog.")) {
            try OMPDialogPlanner(dialog: dialog).plan(.choose(ordinal: 1))
        }
        #expect(throws: DialogPlanError.unsupported("Answer this dialog in the Agent terminal.")) {
            try DialogActionPlanner.plan(
                number: 3,
                for: GenericDialogExcerpt(
                    rows: [], numbered: [3: "Yes, proceed"], reason: "",
                    fingerprint: DialogFingerprint(program: .grok, excerptRows: [])),
                program: .grok)
        }
    }
}
