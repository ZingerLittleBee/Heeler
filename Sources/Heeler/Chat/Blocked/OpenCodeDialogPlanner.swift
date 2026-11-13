import Foundation

/// OpenCode's keys for a card action. A permission's options sit in a row:
/// Left and Right move focus, one checked step at a time, and Enter picks
/// the focused option. A question's digit picks its answer and submits.
struct OpenCodeDialogPlanner {
    let dialog: BlockedDialog
    /// The matched call of the session on screen. OpenCode draws its
    /// subagents' requests there too, and Esc on a subagent's permission
    /// asks what to do differently instead of rejecting, so Esc goes only
    /// for a matched call.
    var toolUseID: String? = nil

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.kind {
        case .openCodePermission:
            try permission(action)
        case .openCodeQuestion:
            try question(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust, .codexExec, .codexPatch, .codexNetwork,
            .codexQuestion, .codexAsyncCollapsed, .codexAsyncQuestion, .codexWorkspaceTrust, .ompApproval, .ompQuestion,
            .ompQuestionReview, .grokPermission, .grokQuestion, .grokCancelTurn, .grokFork, .agyCommand, .agyFileEdit,
            .agyFileCreate, .agyQuestion, .agyWorkspaceTrust:
            throw .unsupported(String(localized: "Not an OpenCode dialog."))
        }
    }

    /// `Allow once` has focus when the request shows, so it takes Enter
    /// alone; `Always allow` is one step to the right. Esc rejects.
    private func permission(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            switch option.role {
            case .approve, .approvePersistent:
                var builder = StepBuilder(dialog: dialog)
                try builder.move(to: ordinal, axis: .horizontal)
                builder.keys("enter")
                return DialogActionPlan(steps: builder.steps, confirmation: .fingerprintChangeOrUnblocked)
            case .decline:
                return try rejection()
            default:
                throw .noSuchOption(ordinal)
            }
        case .dismiss:
            return try rejection()
        case .amend, .respond, .approvePlan:
            throw .unsupported(
                String(localized: "OpenCode takes no note with a permission; reject, then tell OpenCode in the composer."))
        case .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported(String(localized: "The permission has no such action."))
        }
    }

    private func rejection() throws(DialogPlanError) -> DialogActionPlan {
        guard toolUseID != nil else {
            throw .unsupported(String(localized: "Reject this in the terminal: OpenCode asks why when a subagent's request is rejected."))
        }
        return DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)
    }

    /// A digit picks its answer and submits it. Heeler doesn't type into
    /// OpenCode's own answer row. Esc dismisses the question.
    private func question(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else { throw Self.ownAnswer }
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported(String(localized: "Option \(ordinal) has no digit key. Answer it in the terminal."))
            }
            return DialogActionPlan(steps: [.keys([digit])], confirmation: .fingerprintChangeOrUnblocked)
        case .dismiss:
            guard toolUseID != nil else {
                throw .unsupported(String(localized: "Dismiss this question in the terminal: Heeler can't match it to OpenCode's call."))
            }
            return DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)
        case .respond, .amend:
            throw Self.ownAnswer
        case .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported(String(localized: "The question has no such action."))
        }
    }

    private static let ownAnswer = DialogPlanError.unsupported(String(localized: "Type your own answer in the terminal."))
}
