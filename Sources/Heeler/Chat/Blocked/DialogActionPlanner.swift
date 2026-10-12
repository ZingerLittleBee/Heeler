import Foundation

/// Turns a card action into the keys, pastes and checks that perform it on
/// the dialog as last read.
///
/// Plans stay as short as the dialog allows: a digit where the program binds
/// one, otherwise one arrow key per row with a re-read after each, so a key
/// that lands somewhere unexpected stops the plan before Enter. Text typed
/// in the terminal stops every plan that would send keys past it, since
/// Heeler never clears it.
enum DialogActionPlanner {
    /// - Parameter toolUseID: The matched request's `tool_use` id, which
    ///   lets a Claude card confirm by the request's result.
    static func plan(
        _ action: DialogAction, for dialog: BlockedDialog, toolUseID: String? = nil
    ) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.program {
        case .claude: try ClaudeDialogPlanner(dialog: dialog, toolUseID: toolUseID).plan(action)
        case .codex: try CodexDialogPlanner(dialog: dialog).plan(action)
        }
    }

    /// The generic card's option button: the digit of an option the excerpt
    /// lists.
    static func plan(
        number: Int, for excerpt: GenericDialogExcerpt, program: ChatProgram
    ) throws(DialogPlanError) -> DialogActionPlan {
        guard excerpt.numbered[number] != nil else { throw .noSuchOption(number) }
        guard let digit = digitKey(number) else { throw .unsupported("Option \(number) has no digit key.") }
        // Claude draws its text cursor in reverse video. With a field
        // focused, the digit would be typed rather than pressed.
        if program == .claude, excerpt.rows.contains(where: { $0.runs.contains(where: \.style.isReverse) }) {
            throw .unsupported("A text field in the dialog has the cursor, so a digit would be typed into it.")
        }
        let confirmation: ConfirmationRule = program == .claude ? .fingerprintChange : .fingerprintChangeOrUnblocked
        return DialogActionPlan(steps: [.keys([digit])], confirmation: confirmation)
    }

    /// The key for an option number; programs bind digits 1 to 9 only.
    static func digitKey(_ number: Int?) -> String? {
        guard let number, (1...9).contains(number) else { return nil }
        return String(number)
    }

    /// `text` as a dialog field takes it: one line, trimmed, with no
    /// character the program would read as a key. Without bracketed paste a
    /// Tab or line break would act on the dialog.
    static func fieldText(_ text: String) throws(DialogPlanError) -> String {
        let normalized = TerminalTextSafety.normalizingNewlines(text)
        let hasLineSeparator = normalized.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" }
        if TerminalTextSafety.isMultiline(normalized) || hasLineSeparator { throw .multilineText }
        guard TerminalTextSafety.containsOnlySafeScalars(normalized), !normalized.unicodeScalars.contains("\t")
        else { throw .unsafeText }
        let trimmed = normalized.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyText }
        return trimmed
    }
}

extension BlockedDialog {
    /// Whether one of the dialog's fields holds typed text.
    var hasTypedText: Bool {
        if let notes = focus.notesText, !notes.isEmpty { return true }
        return focus.inputText != nil
            || options.contains { option in
                if case .text = option.input { return true }
                return false
            }
    }
}

/// Collects steps while tracking where focus will be once they have run.
private struct StepBuilder {
    let dialog: BlockedDialog
    private(set) var steps: [DialogStep] = []
    private(set) var focus: Int?

    init(dialog: BlockedDialog) {
        self.dialog = dialog
        focus = dialog.focus.focusedOrdinal
    }

    mutating func keys(_ key: String) {
        steps.append(.keys([key]))
    }

    mutating func paste(_ text: String) {
        steps.append(.paste(text))
    }

    mutating func expect(_ expectation: DialogExpectation) {
        steps.append(.expect(expectation))
    }

    mutating func append(_ more: [DialogStep]) {
        steps.append(contentsOf: more)
    }

    /// One arrow key per row from the focus to `target`, each checked.
    mutating func move(to target: Int) throws(DialogPlanError) {
        guard var current = focus else { throw .noFocus }
        while current != target {
            let isDown = target > current
            current += isDown ? 1 : -1
            keys(isDown ? "down" : "up")
            expect(.focus(ordinal: current))
        }
        focus = target
    }

    /// Steps off a focused text field, where digits would be typed rather
    /// than pressed. Arrow keys still move focus from a field.
    mutating func leaveField() throws(DialogPlanError) {
        guard let current = focus, dialog.option(current)?.input != nil else { return }
        let neighbor = current > 1 ? current - 1 : current + 1
        guard dialog.option(neighbor) != nil else {
            throw .unsupported("The focused text field has no option next to it to step to.")
        }
        try move(to: neighbor)
    }

    /// Presses an option: its digit, or arrow keys and Enter.
    mutating func press(_ option: DialogOption) throws(DialogPlanError) {
        if let digit = DialogActionPlanner.digitKey(option.number) {
            try leaveField()
            keys(digit)
        } else {
            try move(to: option.ordinal)
            keys("enter")
        }
    }

    /// Focuses an empty text field. Its digit only focuses it, since the
    /// program submits a field by digit only once it holds text.
    mutating func focusField(_ option: DialogOption) throws(DialogPlanError) {
        guard focus != option.ordinal else { return }
        if let digit = DialogActionPlanner.digitKey(option.number) {
            keys(digit)
            expect(.focus(ordinal: option.ordinal))
            focus = option.ordinal
        } else {
            try move(to: option.ordinal)
        }
    }
}

private struct ClaudeDialogPlanner {
    let dialog: BlockedDialog
    let toolUseID: String?

    private var confirmation: ConfirmationRule {
        toolUseID.map { .toolResult(id: $0) } ?? .fingerprintChange
    }

    private var isMultiSelect: Bool {
        dialog.kind == .claudeQuestion && dialog.options.contains { $0.role == .next }
    }

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .dismiss:
            // Esc cancels rather than submits, so it goes through even when
            // a field holds text.
            DialogActionPlan(steps: [.keys(["esc"])], confirmation: confirmation)
        case .choose(let ordinal):
            try choose(ordinal)
        case .amend(let ordinal, let note):
            try amend(ordinal, note: note)
        case .respond(let ordinal, let text):
            try respond(ordinal, text: text, submitKey: "enter")
        case .approvePlan(let note):
            try approvePlan(note: note)
        case .submitSelection(let ordinals):
            try submitSelection(ordinals)
        case .expandQuestions, .skipQuestion:
            throw .unsupported("Only Codex queues questions.")
        }
    }

    private func choose(_ ordinal: Int) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        switch option.role {
        case .otherText:
            throw .needsText
        case .answer where isMultiSelect:
            throw .unsupported("A multi-select question takes its answers as a set.")
        case .next:
            try builder.move(to: ordinal)
            builder.keys("enter")
            builder.append(pageTurn())
        case .answer:
            try builder.press(option)
            builder.append(pageTurn())
        default:
            try builder.press(option)
        }
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// Tab on a `Yes` or `No` row opens its note field: `Yes, and tell
    /// Claude what to do next`, `No, and tell Claude what to do
    /// differently`.
    private func amend(_ ordinal: Int, note: String) throws(DialogPlanError) -> DialogActionPlan {
        guard [.claudeBash, .claudeFileEdit, .claudeFileCreate].contains(dialog.kind) else {
            throw .unsupported("Only Claude's Bash and file dialogs take a note with the answer.")
        }
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .approve || option.role == .decline else {
            throw .unsupported("Only the Yes and No rows take a note.")
        }
        let text = try DialogActionPlanner.fieldText(note)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        // A row already turned into an empty note field skips the Tab.
        if dialog.focus.feedbackOrdinal != ordinal {
            try builder.move(to: ordinal)
            builder.keys("tab")
            builder.expect(.feedbackMode(ordinal: ordinal))
        }
        builder.paste(text)
        builder.expect(.inputText(text))
        builder.keys("enter")
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    private func respond(_ ordinal: Int, text: String, submitKey: String) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .otherText, option.input != nil else {
            throw .unsupported("Option \(ordinal) is not a text field.")
        }
        guard !isMultiSelect else {
            throw .unsupported("Heeler does not type into a multi-select question's Other row.")
        }
        let text = try DialogActionPlanner.fieldText(text)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        try builder.focusField(option)
        builder.paste(text)
        builder.expect(.inputText(text))
        builder.keys(submitKey)
        if submitKey == "enter" { builder.append(pageTurn()) }
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// shift+tab in the plan's feedback row approves with the note, taking
    /// the first approval option; the card names that option's mode.
    private func approvePlan(note: String) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.kind == .claudePlan, let field = dialog.options.last(where: { $0.role == .otherText }),
            field.detail?.hasPrefix("shift+tab to approve") == true
        else { throw .unsupported("This dialog does not offer approving with feedback.") }
        return try respond(field.ordinal, text: note, submitKey: "shift+tab")
    }

    /// Toggles answers by digit (focus stays put), then moves to the page's
    /// button and presses Enter.
    private func submitSelection(_ ordinals: Set<Int>) throws(DialogPlanError) -> DialogActionPlan {
        guard isMultiSelect, let button = dialog.options.first(where: { $0.role == .next }) else {
            throw .unsupported("Only a multi-select question takes a set of answers.")
        }
        guard !ordinals.isEmpty else { throw .emptySelection }
        for ordinal in ordinals.sorted() {
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else {
                throw .unsupported("Option \(ordinal) is not an answer Heeler can check.")
            }
        }
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        if dialog.options.contains(where: { $0.role == .otherText && $0.isChecked == true }) {
            throw .unsupported("The typed answer is checked; finish it in the terminal.")
        }
        var builder = StepBuilder(dialog: dialog)
        try builder.leaveField()
        var checked = dialog.focus.checked
        for option in dialog.options
        where option.role == .answer && ordinals.contains(option.ordinal) != checked.contains(option.ordinal) {
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(option.ordinal) has no digit key.")
            }
            checked.formSymmetricDifference([option.ordinal])
            builder.keys(digit)
            builder.expect(.checked(checked))
        }
        try builder.move(to: button.ordinal)
        builder.keys("enter")
        builder.append(pageTurn())
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// Answering a page of several questions shows the next question, and
    /// after the last one the review page.
    private func pageTurn() -> [DialogStep] {
        let headers = dialog.subject.questionHeaders
        guard dialog.kind == .claudeQuestion, headers.count > 1, let current = dialog.progress,
            let index = headers.firstIndex(of: current)
        else { return [] }
        let next = headers.indices.contains(index + 1) ? headers[index + 1] : "Review your answers"
        return [.expect(.page(next))]
    }
}

private struct CodexDialogPlanner {
    let dialog: BlockedDialog

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.kind {
        case .codexExec, .codexPatch, .codexNetwork:
            try approval(action)
        case .codexQuestion:
            try question(action)
        case .codexAsyncCollapsed:
            try collapsedQuestions(action)
        case .codexAsyncQuestion:
            try asyncQuestion(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFetch, .claudePlan, .claudeQuestion,
            .claudeQuestionReview, .claudeWorkspaceTrust:
            throw .unsupported("Not a Codex dialog.")
        }
    }

    /// A digit acts at once. Declining ends the turn, and Codex then waits
    /// for the user to say what to do differently in the composer.
    private func approval(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            var builder = StepBuilder(dialog: dialog)
            try builder.press(option)
            return DialogActionPlan(
                steps: builder.steps, confirmation: .fingerprintChangeOrUnblocked,
                focusesComposer: option.role == .decline)
        case .dismiss:
            return DialogActionPlan(
                steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked, focusesComposer: true)
        case .amend, .respond, .approvePlan:
            throw .unsupported("Codex ignores text on approvals; decline, then tell Codex in the composer.")
        case .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The approval has no such action.")
        }
    }

    /// A digit answers and moves to the next question. With notes open,
    /// keys go to the notes instead, and Esc clears them.
    private func question(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        let notes = dialog.focus.notesText
        if let notes, !notes.isEmpty { throw .textFieldNotEmpty }
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard notes == nil else {
                throw .unsupported("Codex's notes field is open, so keys would be typed into it.")
            }
            var builder = StepBuilder(dialog: dialog)
            try builder.press(option)
            builder.append(nextQuestion())
            return DialogActionPlan(steps: builder.steps, confirmation: .fingerprintChangeOrUnblocked)
        case .respond(let ordinal, let text):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .otherText else {
                throw .unsupported("Heeler adds notes only to None of the above.")
            }
            let text = try DialogActionPlanner.fieldText(text)
            var builder = StepBuilder(dialog: dialog)
            if notes != nil {
                // The open notes belong to the highlighted option.
                guard dialog.focus.focusedOrdinal == ordinal else {
                    throw .unsupported("Codex's notes field is open on another option.")
                }
            } else {
                try builder.move(to: ordinal)
            }
            // A paste on the highlighted option opens its notes.
            builder.paste(text)
            builder.expect(.notes(text))
            builder.keys("enter")
            builder.append(nextQuestion())
            return DialogActionPlan(steps: builder.steps, confirmation: .fingerprintChangeOrUnblocked)
        case .dismiss:
            guard notes == nil else { throw .unsupported("Esc would clear Codex's notes rather than interrupt.") }
            return DialogActionPlan(
                steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked, focusesComposer: true)
        case .amend, .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The question has no such action.")
        }
    }

    /// `? N questions` above the composer: shift+left opens them; Esc
    /// interrupts the running turn, as from the composer.
    private func collapsedQuestions(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .expandQuestions:
            DialogActionPlan(steps: [.keys(["shift+left"])], confirmation: .fingerprintChange)
        case .dismiss:
            DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked, focusesComposer: true)
        case .choose, .amend, .respond, .approvePlan, .submitSelection, .skipQuestion:
            throw .unsupported("Open the questions first.")
        }
    }

    /// A digit queues the answer, which Codex sends after the next tool
    /// call; ctrl+] skips the question without a record.
    private func asyncQuestion(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else {
                throw .unsupported("Heeler does not answer with Codex's Other yet.")
            }
            var builder = StepBuilder(dialog: dialog)
            try builder.press(option)
            return DialogActionPlan(steps: builder.steps, confirmation: .queuedNotice(dialog.title))
        case .skipQuestion:
            return DialogActionPlan(steps: [.keys(["ctrl+]"])], confirmation: .fingerprintChangeOrUnblocked)
        case .dismiss, .amend, .respond, .approvePlan, .submitSelection, .expandQuestions:
            throw .unsupported("Codex offers only an answer or a skip here.")
        }
    }

    /// `Question i/n` turns to `Question i+1/n` while questions remain.
    private func nextQuestion() -> [DialogStep] {
        guard let progress = dialog.progress, progress.hasPrefix("Question ") else { return [] }
        let numbers = progress.dropFirst("Question ".count).split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] < numbers[1] else { return [] }
        return [.expect(.page("Question \(numbers[0] + 1)/\(numbers[1])"))]
    }
}
