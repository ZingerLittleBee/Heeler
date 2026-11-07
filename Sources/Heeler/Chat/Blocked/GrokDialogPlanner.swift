import Foundation

/// Grok Build's keys for a card action (1.0.62). Every card binds a key to
/// each row, which selects the row and submits it at once, so each plan is
/// that one key. Nothing plans Esc, which only parks the keyboard in the
/// scrollback or keeps a cancelled turn running; Ctrl+C, which cancels a
/// permission or skips a question; Ctrl+Y, which hides a question
/// unanswered; Ctrl+O, `e`, ← and →, which change the rule or the mode; or
/// a letter on a permission, which opens the reject row's feedback field.
/// Grok records no approval and herdr stays Blocked a moment after a key,
/// so the card leaving the screen confirms it. Where the next card looks
/// the same, as for parallel subagents with one description, a call that
/// waited starting brings the card's answers back (`BlockedCardStore`). A
/// key selects its row wherever the cursor is, so only a question and the
/// fork question, where the cursor may sit on the answer field, need to see
/// it.
struct GrokDialogPlanner {
    let dialog: BlockedDialog
    /// Ignored: no Grok Build record answers a card.
    var toolUseID: String? = nil

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.program == .grok else { throw Self.notGrok }
        // Esc left the keyboard in the scrollback, or a field of the card
        // has it, where keys miss the options.
        guard !dialog.focus.keysMissOptions else {
            throw .unsupported("Grok Build's card doesn't have focus. Answer it in the terminal.")
        }
        switch dialog.kind {
        case .grokPermission:
            return try permission(action)
        case .grokQuestion:
            return try question(action)
        case .grokCancelTurn:
            return try cancelPanel(action)
        case .grokFork:
            return try fork(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust, .codexExec, .codexPatch, .codexNetwork,
            .codexQuestion, .codexAsyncCollapsed, .codexAsyncQuestion, .codexWorkspaceTrust, .ompApproval, .ompQuestion,
            .ompQuestionReview, .openCodePermission, .openCodeQuestion, .agyCommand, .agyFileEdit, .agyFileCreate,
            .agyQuestion, .agyWorkspaceTrust:
            throw Self.notGrok
        }
    }

    private static let notGrok = DialogPlanError.unsupported("Not a Grok Build dialog.")

    /// A row's digit. Stop and the folded card's Deny press the reject row,
    /// which ends the turn.
    private func permission(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            return try press(option)
        case .dismiss:
            guard let reject = dialog.options.first(where: { $0.role == .decline }) else {
                throw .unsupported("The permission has no reject row.")
            }
            return try press(reject)
        case .amend, .respond:
            throw .unsupported("Heeler doesn't type feedback into Grok Build's permissions. Add it in the terminal.")
        case .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The permission has no such action.")
        }
    }

    /// An answer's key: `1` to `9`, then `a` to `f`. With the cursor on the
    /// answer field, a key would be typed into it, and Heeler types nothing
    /// into a question.
    private func question(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else { throw Self.typedAnswer }
            guard let focused = dialog.focus.focusedOrdinal else {
                throw .unsupported(
                    "Heeler can't see Grok Build's cursor, which may be on the answer field, where a key would be "
                        + "typed. Answer in the terminal.")
            }
            guard dialog.option(focused)?.role != .otherText else { throw Self.cursorOnField }
            guard let key = option.shortcut, Self.answerKeys.contains(key) else {
                throw .unsupported("Grok Build binds no key to this answer. Answer it in the terminal.")
            }
            return Self.plan(key)
        case .respond, .amend:
            throw Self.typedAnswer
        case .skipQuestion:
            // Shift+X skips, unconfirmed on 1.0.62.
            throw .unsupported("Skip Grok Build's question in the terminal.")
        case .dismiss, .approvePlan, .submitSelection, .expandQuestions:
            throw .unsupported("The question has no such action.")
        }
    }

    /// `1` forks into a new worktree, `2` in the current directory. With
    /// the cursor on the answer field a key would be typed into it; on a
    /// row Chat leaves to the terminal it still selects its own row. The
    /// parser reads the fork question only with its cursor in view, so no
    /// focused option means the cursor is on such a row.
    private func fork(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else { throw Self.typedAnswer }
            if let focused = dialog.focus.focusedOrdinal, dialog.option(focused)?.role == .otherText {
                throw Self.cursorOnField
            }
            return try press(option)
        case .respond, .amend:
            throw Self.typedAnswer
        case .dismiss, .skipQuestion, .approvePlan, .submitSelection, .expandQuestions:
            throw .unsupported("The fork question has no such action.")
        }
    }

    /// `1` stops the turn and its subagents; `2` ends the turn and keeps
    /// them running. Esc would keep the turn running.
    private func cancelPanel(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        guard case .choose(let ordinal) = action else { throw .unsupported("The panel has no such action.") }
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        return try press(option)
    }

    private func press(_ option: DialogOption) throws(DialogPlanError) -> DialogActionPlan {
        guard let key = DialogActionPlanner.digitKey(option.number) else {
            throw .unsupported("Option \(option.ordinal) has no digit key.")
        }
        return Self.plan(key)
    }

    private static func plan(_ key: String) -> DialogActionPlan {
        DialogActionPlan(steps: [.keys([key])], confirmation: .fingerprintChangeOrUnblocked)
    }

    /// The answer keys Grok binds (`question_view.rs`).
    private static let answerKeys: Set<String> = Set("123456789abcdef".map(String.init))

    private static let typedAnswer = DialogPlanError.unsupported(
        "Heeler doesn't type into Grok Build's questions. Write your own answer in the terminal.")
    private static let cursorOnField = DialogPlanError.unsupported(
        "Grok Build's cursor is on its answer field, where a key would be typed. Answer in the terminal.")
}
