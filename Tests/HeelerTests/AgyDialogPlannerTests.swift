import Foundation
import Testing

@testable import Heeler

/// Antigravity CLI's keys for a card action, on agy 1.5.3 captures. The
/// keys each plan sends were sent live to the same dialogs (2026-11-08).
@Suite("Antigravity CLI dialog planner")
struct AgyDialogPlannerTests {
    private static func dialog(_ stem: String) throws -> BlockedDialog {
        let result = AgyDialogParser.parse(try ScreenFixture.screen(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private func plan(_ action: DialogAction, _ stem: String) throws -> DialogActionPlan {
        try AgyDialogPlanner(dialog: Self.dialog(stem)).plan(action)
    }

    private static func plan(_ steps: [DialogStep], focusesComposer: Bool = false) -> DialogActionPlan {
        DialogActionPlan(steps: steps, confirmation: .fingerprintChange, focusesComposer: focusesComposer)
    }

    private static let noteFieldOpen = DialogPlanError.unsupported(
        "Antigravity CLI's note field is open, so a digit would be typed into it. Answer in the terminal.")
    private static let answerFieldOpen = DialogPlanError.unsupported(
        "Antigravity CLI's answer field is open, so keys would be typed into it.")

    // MARK: Permissions

    /// A permission's digit answers it at once. `No` ends the turn, so the
    /// card hands over to the composer; herdr reports the file dialogs
    /// idle, so only the dialog leaving confirms.
    @Test(arguments: [
        ("agy-30-perm-run-command-default-120x40", ["1", "2", "3", "4"]),
        ("agy-31-perm-run-command-default-40x30", ["1", "2", "3", "4"]),
        ("agy-47-perm-file-edit-default-120x40", ["1", "2"]),
        ("agy-99-perm-file-create-default-62x41", ["1", "2"]),
    ])
    func aPermissionsDigitAnswersIt(_ stem: String, keys: [String]) throws {
        let dialog = try Self.dialog(stem)

        for option in dialog.options {
            let plan = try self.plan(.choose(ordinal: option.ordinal), stem)
            #expect(plan == Self.plan([.keys([keys[option.ordinal - 1]])], focusesComposer: option.role == .decline))
        }
        #expect(dialog.options.last?.role == .decline)
    }

    /// Esc stops the whole turn and records nothing: the card's Stop, from
    /// the options or from a note field, even one holding text.
    @Test(arguments: [
        "agy-30-perm-run-command-default-120x40", "agy-47-perm-file-edit-default-120x40",
        "agy-99-perm-file-create-default-40x30", "agy-109-perm-run-command-amend-62x41",
        "agy-110-perm-run-command-amend-typed-62x41",
    ])
    func escStopsTheTurn(_ stem: String) throws {
        #expect(try plan(.dismiss, stem) == Self.plan([.keys(["esc"])], focusesComposer: true))
    }

    /// Tab on `Yes, run command` opens its note field, checked empty before
    /// the paste and holding the note before Enter.
    @Test func aNoteOnYesTabsIntoTheField() throws {
        let note = "then also reply with the word kiwi"

        #expect(
            try plan(.amend(ordinal: 1, note: note), "agy-108-perm-run-command-62x41")
                == Self.plan([
                    .keys(["tab"]), .expect(.feedbackMode(ordinal: 1)), .paste(note), .expect(.inputText(note)),
                    .keys(["enter"]),
                ]))
        // The field already open on the row takes the note at once.
        #expect(
            try plan(.amend(ordinal: 1, note: note), "agy-109-perm-run-command-amend-62x41")
                == Self.plan([.paste(note), .expect(.inputText(note)), .keys(["enter"])]))
    }

    /// `No, cancel` is three rows down, each step checked, as sent live.
    @Test func aNoteOnNoArrowsToItsRow() throws {
        let note = "use ls instead"

        #expect(
            try plan(.amend(ordinal: 4, note: "  \(note) "), "agy-108-perm-run-command-62x41")
                == Self.plan([
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["down"]), .expect(.focus(ordinal: 4)), .keys(["tab"]), .expect(.feedbackMode(ordinal: 4)),
                    .paste(note), .expect(.inputText(note)), .keys(["enter"]),
                ]))
        #expect(
            try plan(.amend(ordinal: 4, note: note), "agy-111-perm-run-command-tab-on-no-62x41")
                == Self.plan([.paste(note), .expect(.inputText(note)), .keys(["enter"])]))
    }

    @Test func notesGoOnlyOnTheCommandsYesAndNo() throws {
        #expect(throws: DialogPlanError.unsupported("Only the Yes and No rows take a note.")) {
            try plan(.amend(ordinal: 2, note: "x"), "agy-108-perm-run-command-62x41")
        }
        #expect(
            throws: DialogPlanError.unsupported("Antigravity CLI takes a note only with a command's Yes or No.")
        ) {
            try plan(.amend(ordinal: 1, note: "x"), "agy-47-perm-file-edit-default-120x40")
        }
        #expect(
            throws: DialogPlanError.unsupported(
                "Antigravity CLI's note field is open on another row. Finish it in the terminal.")
        ) {
            try plan(.amend(ordinal: 4, note: "x"), "agy-109-perm-run-command-amend-62x41")
        }
        #expect(throws: DialogPlanError.textFieldNotEmpty) {
            try plan(.amend(ordinal: 1, note: "x"), "agy-110-perm-run-command-amend-typed-62x41")
        }
        #expect(throws: DialogPlanError.multilineText) {
            try plan(.amend(ordinal: 1, note: "a\nb"), "agy-108-perm-run-command-62x41")
        }
    }

    /// In an open note field a digit would be typed.
    @Test func anOpenNoteFieldRefusesDigits() throws {
        #expect(throws: Self.noteFieldOpen) { try plan(.choose(ordinal: 1), "agy-109-perm-run-command-amend-62x41") }
        #expect(throws: Self.noteFieldOpen) {
            try plan(.choose(ordinal: 4), "agy-111-perm-run-command-tab-on-no-62x41")
        }
        #expect(throws: DialogPlanError.textFieldNotEmpty) {
            try plan(.choose(ordinal: 1), "agy-110-perm-run-command-amend-typed-62x41")
        }
    }

    // MARK: Questions

    /// A single-select answer's digit answers; on a page of several it
    /// turns to the next question, and the last page answers them all.
    @Test func aSingleSelectDigitAnswersAndTurnsThePage() throws {
        #expect(try plan(.choose(ordinal: 2), "agy-41-ask-question-single-120x40") == Self.plan([.keys(["2"])]))
        #expect(
            try plan(.choose(ordinal: 1), "agy-44-ask-question-multi-120x40")
                == Self.plan([.keys(["1"]), .expect(.page("Question 2/2"))]))
        #expect(try plan(.choose(ordinal: 2), "agy-45-ask-question-multi-q2-120x40") == Self.plan([.keys(["2"])]))
        #expect(throws: DialogPlanError.needsText) {
            try plan(.choose(ordinal: 3), "agy-41-ask-question-single-120x40")
        }
    }

    /// `Write-in...`'s digit opens `Your answer:`, checked empty; the text
    /// goes in as a paste, checked, and Enter submits it.
    @Test func aWrittenAnswerOpensTheFieldByItsDigit() throws {
        let text = "a small hamster"

        #expect(
            try plan(.respond(ordinal: 3, text: text), "agy-41-ask-question-single-120x40")
                == Self.plan([
                    .keys(["3"]), .expect(.feedbackMode(ordinal: 3)), .paste(text), .expect(.inputText(text)),
                    .keys(["enter"]),
                ]))
        #expect(
            try plan(.respond(ordinal: 3, text: text), "agy-104-ask-question-writein-after-digit-62x41")
                == Self.plan([.paste(text), .expect(.inputText(text)), .keys(["enter"])]))
        #expect(
            try plan(.respond(ordinal: 3, text: text), "agy-44-ask-question-multi-120x40")
                == Self.plan([
                    .keys(["3"]), .expect(.feedbackMode(ordinal: 3)), .paste(text), .expect(.inputText(text)),
                    .keys(["enter"]), .expect(.page("Question 2/2")),
                ]))
        #expect(throws: DialogPlanError.textFieldNotEmpty) {
            try plan(.respond(ordinal: 3, text: text), "agy-105-ask-question-writein-typed-62x41")
        }
        #expect(throws: DialogPlanError.unsupported("Option 1 is not a text field.")) {
            try plan(.respond(ordinal: 1, text: text), "agy-41-ask-question-single-120x40")
        }
    }

    /// Esc skips the question: the next page, or on the last the set as
    /// answered so far. agy goes on with the turn, so the composer keeps
    /// its focus.
    @Test func escSkipsTheQuestion() throws {
        let skip = Self.plan([.keys(["esc"]), .expect(.page("Question 2/2"))])

        #expect(try plan(.dismiss, "agy-44-ask-question-multi-120x40") == skip)
        #expect(try plan(.skipQuestion, "agy-44-ask-question-multi-120x40") == skip)
        #expect(try plan(.dismiss, "agy-41-ask-question-single-120x40") == Self.plan([.keys(["esc"])]))
    }

    /// With `Your answer:` open a digit would be typed, and Esc only
    /// steps back to the answers.
    @Test func anOpenAnswerFieldRefusesKeys() throws {
        let field = "agy-104-ask-question-writein-after-digit-62x41"

        #expect(throws: Self.answerFieldOpen) { try plan(.choose(ordinal: 1), field) }
        #expect(throws: Self.answerFieldOpen) { try plan(.dismiss, field) }
        #expect(throws: DialogPlanError.textFieldNotEmpty) {
            try plan(.dismiss, "agy-105-ask-question-writein-typed-62x41")
        }
    }

    /// A multi-select answer's digit selects and toggles it, checked after
    /// each; Enter then submits the checked answers, or turns to the next
    /// question.
    @Test func aSelectionTogglesByDigitThenEnter() throws {
        #expect(
            try plan(.submitSelection([2]), "agy-100-ask-question-multiselect-62x41")
                == Self.plan([.keys(["2"]), .expect(.checked([2])), .keys(["enter"])]))
        // agy-102 has `blue` checked and `green` selected.
        #expect(
            try plan(.submitSelection([3]), "agy-102-ask-question-multiselect-after-3-2-62x41")
                == Self.plan([.keys(["enter"])]))
        #expect(
            try plan(.submitSelection([1, 2]), "agy-102-ask-question-multiselect-after-3-2-62x41")
                == Self.plan([
                    .keys(["1"]), .expect(.checked([1, 3])), .keys(["2"]), .expect(.checked([1, 2, 3])),
                    .keys(["3"]), .expect(.checked([1, 2])), .keys(["enter"]),
                ]))
        #expect(
            try plan(.submitSelection([1, 3]), "agy-113-ask-question-multiselect-q1-of-2-62x41")
                == Self.plan([
                    .keys(["1"]), .expect(.checked([1])), .keys(["3"]), .expect(.checked([1, 3])), .keys(["enter"]),
                    .expect(.page("Question 2/2")),
                ]))
    }

    @Test func aMultiSelectQuestionTakesASet() throws {
        let stem = "agy-100-ask-question-multiselect-62x41"

        #expect(throws: DialogPlanError.unsupported("A multi-select question takes its answers as a set.")) {
            try plan(.choose(ordinal: 1), stem)
        }
        #expect(throws: DialogPlanError.emptySelection) { try plan(.submitSelection([]), stem) }
        #expect(throws: DialogPlanError.unsupported("Option 4 is not an answer Heeler can check.")) {
            try plan(.submitSelection([1, 4]), stem)
        }
        #expect(
            throws: DialogPlanError.unsupported("Heeler doesn't type into a multi-select question's Write-in row.")
        ) {
            try plan(.respond(ordinal: 4, text: "kiwi"), stem)
        }
        #expect(throws: DialogPlanError.unsupported("Only a multi-select question takes a set of answers.")) {
            try plan(.submitSelection([1]), "agy-41-ask-question-single-120x40")
        }
    }

    // MARK: Trust

    /// The trust prompt's options have no digits: arrow keys to the
    /// option, each checked, then Enter.
    @Test func theTrustPromptTakesArrowsAndEnter() throws {
        #expect(try plan(.choose(ordinal: 1), "agy-00-trust-prompt-191x49") == Self.plan([.keys(["enter"])]))
        #expect(
            try plan(.choose(ordinal: 2), "agy-00-trust-prompt-191x49")
                == Self.plan([.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])]))
        #expect(
            try plan(.choose(ordinal: 1), "agy-11-trust-prompt-no-selected-62x41")
                == Self.plan([.keys(["up"]), .expect(.focus(ordinal: 1)), .keys(["enter"])]))
        #expect(throws: DialogPlanError.unsupported("The trust prompt has no such action.")) {
            try plan(.dismiss, "agy-00-trust-prompt-191x49")
        }
    }

    // MARK: Every plan

    /// Every key a plan sends is one herdr's `agent.send_keys` takes.
    @Test func everyKeyIsOneHerdrTakes() throws {
        let planned: [(DialogAction, String)] = [
            (.choose(ordinal: 4), "agy-30-perm-run-command-default-120x40"),
            (.amend(ordinal: 4, note: "x"), "agy-108-perm-run-command-62x41"),
            (.dismiss, "agy-47-perm-file-edit-default-120x40"),
            (.respond(ordinal: 3, text: "x"), "agy-44-ask-question-multi-120x40"),
            (.submitSelection([1, 2]), "agy-102-ask-question-multiselect-after-3-2-62x41"),
            (.choose(ordinal: 1), "agy-11-trust-prompt-no-selected-62x41"),
            (.choose(ordinal: 2), "agy-00-trust-prompt-191x49"),
        ]
        for (action, stem) in planned {
            for key in try plan(action, stem).keys {
                #expect(HerdrKeyGrammar.accepts(key), "\(key) for \(action) on \(stem)")
            }
        }
    }

    /// Chat routes Antigravity CLI's dialogs here, and a matched call's id
    /// changes nothing.
    @Test func chatsPlannerRoutesHere() throws {
        let dialog = try Self.dialog("agy-30-perm-run-command-default-120x40")

        #expect(
            try DialogActionPlanner.plan(.choose(ordinal: 1), for: dialog, toolUseID: "agy:3:tool:0")
                == AgyDialogPlanner(dialog: dialog).plan(.choose(ordinal: 1)))
        let claude = try #require(
            BlockedDialogParser.parse(try ScreenFixture.screen("claude-02-c1-bash-blocked"), program: .claude).dialog)
        #expect(throws: DialogPlanError.unsupported("Not an Antigravity CLI dialog.")) {
            try AgyDialogPlanner(dialog: claude).plan(.dismiss)
        }
    }
}
