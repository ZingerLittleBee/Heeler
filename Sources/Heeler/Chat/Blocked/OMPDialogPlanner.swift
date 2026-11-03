import Foundation

/// Oh My Pi's keys for a card action. OMP binds no digits to its panels, so
/// no plan sends one; a list row is reached by arrow keys, each checked.
struct OMPDialogPlanner {
    let dialog: BlockedDialog
    /// The matched `ask` call, whose result confirms an answer.
    var toolUseID: String? = nil

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.kind {
        case .ompApproval:
            try approval(action)
        case .ompQuestion, .ompQuestionReview:
            try question(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust, .codexExec, .codexPatch, .codexNetwork,
            .codexQuestion, .codexAsyncCollapsed, .codexAsyncQuestion, .codexWorkspaceTrust, .grokPermission,
            .grokQuestion, .grokCancelTurn, .grokFork, .openCodePermission, .openCodeQuestion:
            throw .unsupported("Not an Oh My Pi dialog.")
        }
    }

    /// ctrl+q approves once, whichever row has focus; ctrl+enter reads as
    /// Enter without kitty keys. Esc denies, and OMP goes on with the turn,
    /// so the Composer keeps its focus. Oh My Pi 18.12's session approval
    /// has no key of its own: one arrow key per row to it, each checked,
    /// then Enter. While the prompt holds a draft, arrow keys and Enter go
    /// to the draft, so only Approve and Deny go. Leaving Blocked confirms
    /// any of them.
    private func approval(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            switch option.role {
            case .approve:
                return DialogActionPlan(steps: [.keys(["ctrl+q"])], confirmation: .fingerprintChangeOrUnblocked)
            case .approvePersistent:
                guard !dialog.focus.composerDraftGuard else { throw Self.sessionUnderDraft }
                var builder = StepBuilder(dialog: dialog)
                try builder.press(option)
                return DialogActionPlan(steps: builder.steps, confirmation: .fingerprintChangeOrUnblocked)
            case .decline:
                return Self.deny
            default:
                throw .noSuchOption(ordinal)
            }
        case .dismiss:
            return Self.deny
        case .amend, .respond, .approvePlan:
            throw .unsupported("Oh My Pi takes no note with an approval.")
        case .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The approval has no such action.")
        }
    }

    private static let deny = DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)

    private static let sessionUnderDraft = DialogPlanError.unsupported(
        "Oh My Pi's input box holds a draft, which would take the arrow keys. Clear it in the terminal "
            + "to approve for the session.")

    private var confirmation: ConfirmationRule {
        toolUseID.map { .toolResult(id: $0) } ?? .fingerprintChangeOrUnblocked
    }

    /// Digits do nothing on a question: one arrow key per row, each checked,
    /// then Enter, which answers and turns to the next tab, or submits on
    /// the review page. Esc cancels the question and ends the turn. While
    /// the prompt below holds a draft, every key but Esc goes to the draft.
    private func question(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        if action == .dismiss {
            return DialogActionPlan(steps: [.keys(["esc"])], confirmation: confirmation)
        }
        guard !dialog.focus.composerDraftGuard else { throw .composerDraft }
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            switch option.role {
            case .answer, .submit:
                var builder = StepBuilder(dialog: dialog)
                try builder.press(option)
                if option.role == .answer { builder.append(pageTurn()) }
                return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
            case .otherText:
                throw Self.typedAnswer
            default:
                throw .noSuchOption(ordinal)
            }
        case .respond, .amend:
            throw Self.typedAnswer
        case .dismiss, .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The question has no such action.")
        }
    }

    private static let typedAnswer = DialogPlanError.unsupported(
        "Heeler doesn't type into Oh My Pi's questions. Write your own answer or a note in the terminal.")

    /// Answering a tab shows the next one, and after the last the review.
    private func pageTurn() -> [DialogStep] {
        let headers = dialog.subject.questionHeaders
        guard dialog.kind == .ompQuestion, headers.count > 1, let current = dialog.progress,
            let index = headers.firstIndex(of: current)
        else { return [] }
        let next = headers.indices.contains(index + 1) ? headers[index + 1] : "Review answers"
        return [.expect(.page(next))]
    }
}
