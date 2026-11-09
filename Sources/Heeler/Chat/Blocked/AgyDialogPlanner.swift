import Foundation

/// Antigravity CLI's keys for a card action (agy 1.5.3).
///
/// On a permission or a question, an option's digit selects it and answers
/// at once, wherever the selection was. Esc on a permission stops the whole
/// turn and records nothing, so it is the card's Stop, never a `No`: `No`
/// is its own numbered option, which agy records as a declined call before
/// it stops. Esc on a question skips it, and on the last page answers the
/// question set with what was given. Tab on a command's `Yes` or `No` row
/// opens a note field; a question's `Write-in...` digit opens `Your
/// answer:`, on a multi-select question with its checks kept. In either
/// field digits are typed and Esc steps back (or, on a command, stops the
/// turn; on a question it drops the typed text), so only the field's own
/// plan sends keys while it is open. The trust prompt's options have no
/// digits: arrow keys and Enter. agy records no approval, and herdr reports
/// the file and field states idle, so only the dialog leaving the screen
/// confirms an answer.
struct AgyDialogPlanner {
    let dialog: BlockedDialog

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.kind {
        case .agyCommand, .agyFileEdit, .agyFileCreate:
            try permission(action)
        case .agyQuestion:
            try question(action)
        case .agyWorkspaceTrust:
            try trust(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust, .codexExec, .codexPatch, .codexNetwork,
            .codexQuestion, .codexAsyncCollapsed, .codexAsyncQuestion, .codexWorkspaceTrust, .ompApproval, .ompQuestion,
            .ompQuestionReview, .grokPermission, .grokQuestion, .grokCancelTurn, .grokFork, .openCodePermission,
            .openCodeQuestion:
            throw .unsupported("Not an Antigravity CLI dialog.")
        }
    }

    // MARK: Permissions

    /// A digit answers. `No` declines and ends the turn, so the card then
    /// focuses Chat's composer for what to do instead, as Esc's Stop does.
    private func permission(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
            guard dialog.focus.feedbackOrdinal == nil else { throw Self.noteFieldOpen }
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(ordinal) has no digit key. Answer it in the terminal.")
            }
            return Self.plan([.keys([digit])], focusesComposer: option.role == .decline)
        case .dismiss:
            // Esc stops the turn from the options and from a note field
            // alike, and goes through even when the field holds text.
            return Self.plan([.keys(["esc"])], focusesComposer: true)
        case .amend(let ordinal, let note):
            return try amend(ordinal, note: note)
        case .respond, .approvePlan:
            throw .unsupported("Antigravity CLI takes a note only with a command's Yes or No.")
        case .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The permission has no such action.")
        }
    }

    /// Tab on `Yes, run command` or `No, cancel` opens the row's note field:
    /// Enter then runs the command and sends the note after the turn, or
    /// declines and sends the note at once. A field already open on the row
    /// skips the Tab.
    private func amend(_ ordinal: Int, note: String) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.kind == .agyCommand else {
            throw .unsupported("Antigravity CLI takes a note only with a command's Yes or No.")
        }
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .approve || option.role == .decline else {
            throw .unsupported("Only the Yes and No rows take a note.")
        }
        let text = try DialogActionPlanner.fieldText(note)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        switch dialog.focus.feedbackOrdinal {
        case ordinal:
            break
        case nil:
            try builder.move(to: ordinal)
            builder.keys("tab")
            builder.expect(.feedbackMode(ordinal: ordinal))
        default:
            throw .unsupported("Antigravity CLI's note field is open on another row. Finish it in the terminal.")
        }
        builder.paste(text)
        builder.expect(.inputText(text))
        builder.keys("enter")
        return Self.plan(builder.steps)
    }

    // MARK: Questions

    /// A single-select answer's digit answers and turns the page; a
    /// multi-select answer's digit selects and toggles it, and Enter
    /// submits the checked ones. Esc skips the question.
    private func question(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else { throw .needsText }
            guard !dialog.isMultiSelect else {
                throw .unsupported("A multi-select question takes its answers as a set.")
            }
            try answerFieldClosed()
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(ordinal) has no digit key. Answer it in the terminal.")
            }
            return Self.plan([.keys([digit])] + nextPage())
        case .submitSelection(let ordinals, let text):
            return try submitSelection(ordinals, writeIn: text)
        case .respond(let ordinal, let text):
            return try writeIn(ordinal, text: text)
        case .dismiss, .skipQuestion:
            try answerFieldClosed()
            return Self.plan([.keys(["esc"])] + nextPage())
        case .amend, .approvePlan, .expandQuestions:
            throw .unsupported("The question has no such action.")
        }
    }

    /// Each answer whose check should change gets its digit, checked after
    /// every key. A written answer then goes into `Write-in...`: its digit
    /// opens `Your answer:` with the checks kept, the text goes in as a
    /// paste, and Enter in the field submits the checked answers with it.
    /// Enter in an empty field submits the checks alone, so the paste is
    /// checked first. Without one, Enter submits from an answer row, since
    /// on `Write-in...` it would open the field instead.
    private func submitSelection(
        _ ordinals: Set<Int>, writeIn text: String?
    ) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.isMultiSelect else {
            throw .unsupported("Only a multi-select question takes a set of answers.")
        }
        var written: String?
        if let text { written = try DialogActionPlanner.fieldText(text) }
        guard !ordinals.isEmpty || written != nil else { throw .emptySelection }
        for ordinal in ordinals.sorted() {
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else {
                throw .unsupported("Option \(ordinal) is not an answer Heeler can check.")
            }
        }
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        let toggles = dialog.options.filter {
            $0.role == .answer && ordinals.contains($0.ordinal) != dialog.focus.checked.contains($0.ordinal)
        }
        // An empty field already open takes the text, but a digit for a
        // check would be typed into it.
        if written == nil || !toggles.isEmpty { try answerFieldClosed() }
        var builder = StepBuilder(dialog: dialog)
        var checked = dialog.focus.checked
        for option in toggles {
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(option.ordinal) has no digit key.")
            }
            checked.formSymmetricDifference([option.ordinal])
            builder.keys(digit)
            builder.expect(.checked(checked))
        }
        if let written {
            guard let field = dialog.options.first(where: { $0.role == .otherText && $0.input != nil }) else {
                throw .unsupported("The question has no Write-in row.")
            }
            if dialog.focus.feedbackOrdinal != field.ordinal {
                guard let digit = DialogActionPlanner.digitKey(field.number) else {
                    throw .unsupported("Option \(field.ordinal) has no digit key. Answer it in the terminal.")
                }
                builder.keys(digit)
                builder.expect(.feedbackMode(ordinal: field.ordinal))
            }
            builder.paste(written)
            builder.expect(.inputText(written))
        } else if toggles.isEmpty {
            guard let focused = dialog.focus.focusedOrdinal else { throw .noFocus }
            if dialog.option(focused)?.role != .answer,
                let answer = dialog.options.last(where: { $0.role == .answer })
            {
                try builder.move(to: answer.ordinal)
            }
        }
        builder.keys("enter")
        builder.append(nextPage())
        return Self.plan(builder.steps)
    }

    /// The `Write-in...` digit opens `Your answer:` under the options; the
    /// text goes in as a paste and Enter submits it. On a multi-select
    /// question Enter there submits the checked answers too, so the text
    /// goes with them (`submitSelection`).
    private func writeIn(_ ordinal: Int, text: String) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .otherText, option.input != nil else {
            throw .unsupported("Option \(ordinal) is not a text field.")
        }
        guard !dialog.isMultiSelect else {
            throw .unsupported("A multi-select question takes its written answer with Submit.")
        }
        let text = try DialogActionPlanner.fieldText(text)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var steps: [DialogStep] = []
        if dialog.focus.feedbackOrdinal != ordinal {
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(ordinal) has no digit key. Answer it in the terminal.")
            }
            steps += [.keys([digit]), .expect(.feedbackMode(ordinal: ordinal))]
        }
        steps += [.paste(text), .expect(.inputText(text)), .keys(["enter"])]
        return Self.plan(steps + nextPage())
    }

    /// With `Your answer:` open, a digit would be typed into it and Esc
    /// would only close it.
    private func answerFieldClosed() throws(DialogPlanError) {
        if dialog.hasTypedText { throw .textFieldNotEmpty }
        if dialog.focus.feedbackOrdinal != nil {
            throw .unsupported("Antigravity CLI's answer field is open, so keys would be typed into it.")
        }
    }

    /// `Question i/n` turns to `Question i+1/n` while questions remain;
    /// the last page answers the set.
    private func nextPage() -> [DialogStep] {
        guard let page = dialog.questionPage, page.index < page.count else { return [] }
        return [.expect(.page("Question \(page.index + 1)/\(page.count)"))]
    }

    // MARK: Trust

    /// The two options have no digits, so arrow keys reach one and Enter
    /// picks it: trusting lets agy start, `No, exit` quits it.
    private func trust(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard dialog.option(ordinal) != nil else { throw .noSuchOption(ordinal) }
            var builder = StepBuilder(dialog: dialog)
            try builder.move(to: ordinal)
            builder.keys("enter")
            return Self.plan(builder.steps)
        case .dismiss, .amend, .respond, .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The trust prompt has no such action.")
        }
    }

    // MARK: Building

    private static func plan(_ steps: [DialogStep], focusesComposer: Bool = false) -> DialogActionPlan {
        DialogActionPlan(steps: steps, confirmation: .fingerprintChange, focusesComposer: focusesComposer)
    }

    private static let noteFieldOpen = DialogPlanError.unsupported(
        "Antigravity CLI's note field is open, so a digit would be typed into it. Answer in the terminal.")
}
