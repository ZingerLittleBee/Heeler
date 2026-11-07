import SwiftUI

/// A Blocked Agent's dialog in the Composer's place (ADR 0024): the
/// program's own choices as native buttons, answered with keys. Labels are
/// the program's text. The first option leads, a decline reads as
/// destructive, and an option that saves a rule or switches the permission
/// mode says so. Nothing asks for confirmation and nothing can be undone,
/// as in the terminal.
struct BlockedCardView: View {
    let store: BlockedCardStore
    /// The tallest the card's content grows before it scrolls.
    let maxHeight: CGFloat
    let openTerminal: () -> Void

    var body: some View {
        Group {
            if store.isCollapsed {
                BlockedCollapsedBar(store: store)
            } else {
                switch store.content {
                case .card(let card):
                    Group {
                        if let form = QuestionForm(card: card) {
                            QuestionFormCard(card: card, form: form, store: store, maxHeight: maxHeight)
                        } else {
                            BlockedDialogCard(card: card, store: store, maxHeight: maxHeight)
                        }
                    }
                    .id(store.dialogGeneration)
                case .generic(let excerpt):
                    GenericDialogCard(excerpt: excerpt, store: store, maxHeight: maxHeight, openTerminal: openTerminal)
                case .unreadable:
                    UnreadableDialogCard(store: store, openTerminal: openTerminal)
                case .none:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.blocked-card")
    }
}

// MARK: - Known dialogs

private struct BlockedDialogCard: View {
    let card: BlockedCard
    let store: BlockedCardStore
    let maxHeight: CGFloat
    @State private var text = ""
    @State private var isAddingNote = false
    @State private var selection: Set<Int>
    @State private var pinnedChoicesHeight: CGFloat = 0
    @FocusState private var isTextFocused: Bool

    init(card: BlockedCard, store: BlockedCardStore, maxHeight: CGFloat) {
        self.card = card
        self.store = store
        self.maxHeight = maxHeight
        _selection = State(initialValue: card.dialog.focus.checked)
    }

    private var dialog: BlockedDialog { card.dialog }
    private var isReady: Bool { store.progress == .ready }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockedCardHeader(
                title: dialog.cardTitle, detail: dialog.positionLabel, isActing: store.progress == .acting,
                lineLimit: dialog.asksInTitle ? nil : 2, collapse: { store.isCollapsed = true })
            BlockedScrollingContent(maxHeight: scrollingMaxHeight, fadesEdges: pinsChoices) {
                VStack(alignment: .leading, spacing: 10) {
                    if let source {
                        Label {
                            Text(verbatim: source)
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    content
                    choices
                }
                .disabled(!isReady)
            }
            .scrollIndicatorsFlash(onAppear: pinsChoices)
            if pinsChoices {
                trustChoices
                    .disabled(!isReady)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pinnedChoicesHeight = $0 }
            }
            // Below the scrolling part, so a field stays in view over the
            // keyboard it raises.
            textEntry
                .disabled(!isReady)
            BlockedCardFooter(
                notice: store.notice, stopTitle: stopTitle, isReady: isReady, canStop: store.canStop,
                stop: { perform(.dismiss) })
        }
    }

    /// A trust screen's answers stay below its scrolling text, in view on
    /// a phone, where the folder and the program's warning fill the card's
    /// share. The text gives up their room, so the card stays as tall.
    private var pinsChoices: Bool {
        dialog.kind == .claudeWorkspaceTrust || dialog.kind == .codexWorkspaceTrust
    }

    private var scrollingMaxHeight: CGFloat {
        pinsChoices ? max(maxHeight - pinnedChoicesHeight - 10, 96) : maxHeight
    }

    /// Esc, named for what it does when no option sends it. While an answer
    /// is unconfirmed the options wait, decline too, so Esc shows as the
    /// way out; it says Stop then, rather than repeat the declining option.
    private var stopTitle: String? {
        if dialog.stopsFromCard { return dialog.stopTitle }
        return dialog.canStop && store.progress == .unconfirmed ? String(localized: "Stop") : nil
    }

    /// Who asked, when a subagent did.
    private var source: String? {
        guard let suffix = dialog.sourceSuffix, !suffix.isEmpty else { return nil }
        return suffix.prefix(1).uppercased() + suffix.dropFirst()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let subject = dialog.subject
        switch dialog.kind {
        case .claudeBash:
            if let description = card.request?.detail ?? subject.commandDescription {
                BlockedCardText(description)
            }
            BlockedCodeBox(text: card.request?.summary ?? subject.command ?? "")
        case .codexExec:
            if let reason = subject.reason {
                BlockedCardText(reason)
            }
            BlockedCodeBox(text: subject.command ?? card.request?.summary ?? "")
        case .claudeFileEdit, .claudeFileCreate:
            BlockedCodeBox(text: card.request?.summary ?? subject.filePath ?? "")
            // Between the file's name and the closing question: the change.
            if dialog.body.count > 2 {
                BlockedChangeBox(
                    lines: Array(dialog.body.dropFirst().dropLast()), marksChanges: dialog.kind == .claudeFileEdit)
            }
        case .claudeFileRead:
            BlockedCodeBox(text: card.request?.summary ?? subject.filePath ?? "")
        case .codexPatch:
            if let description = dialog.body.first(where: { $0.hasPrefix("Description:") }) {
                BlockedCardText(
                    description.dropFirst("Description:".count).trimmingCharacters(in: .whitespaces))
            }
            BlockedCodeBox(text: subject.destinations.joined(separator: "\n"))
        case .claudeFetch:
            BlockedCodeBox(text: card.request?.summary ?? subject.url ?? "")
            if let prompt = card.request?.detail ?? subject.prompt {
                BlockedCardText(prompt)
            }
        case .claudePlan:
            // The call's Markdown unless the screen shows another plan; the
            // screen's rows leave out the question the options answer.
            let shown = dialog.body.filter { !$0.hasPrefix("Claude has written up a plan") }
            BlockedPlanBox(text: BlockedRequestMatch.claudePlanText(call: card.request?.summary, shownRows: shown))
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion, .ompQuestion, .grokQuestion, .openCodeQuestion:
            VStack(alignment: .leading, spacing: 4) {
                // Codex's asynchronous questions name their page by the
                // question itself.
                if let progress = dialog.progress, dialog.kind != .codexAsyncQuestion {
                    Text(verbatim: progress)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: subject.question ?? dialog.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .claudeQuestionReview, .ompQuestionReview:
            ForEach(Array(subject.reviewAnswers.enumerated()), id: \.offset) { @Sendable _, pair in
                MainActorContent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: pair.question)
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: pair.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .claudeWorkspaceTrust, .codexWorkspaceTrust:
            BlockedCodeBox(text: subject.workspacePath ?? "")
            // Codex's note on a folder below a repository's root, then the
            // root.
            ForEach(Array(dialog.body.filter { $0 != subject.workspacePath }.enumerated()), id: \.offset) { @Sendable item in
                MainActorContent {
                    if item.element == subject.workspaceRoot {
                        BlockedCodeBox(text: item.element)
                    } else {
                        BlockedCardText(item.element)
                    }
                }
            }
        case .codexAsyncCollapsed:
            BlockedCardText(dialog.collapsedQuestionsNote)
        case .ompApproval:
            if let reason = subject.reason {
                BlockedCardText(reason)
            }
            if let command = subject.command {
                BlockedCodeBox(text: card.request?.summary ?? command)
            }
            // The other rows OMP gives the tool, such as `Origin:`.
            let details = dialog.body.filter { !$0.hasPrefix("Command:") && !$0.hasPrefix("Reason:") }
            ForEach(Array(details.enumerated()), id: \.offset) { @Sendable item in
                MainActorContent {
                    BlockedCardText(item.element)
                }
            }
        case .grokPermission:
            grokPermission
        case .grokCancelTurn:
            BlockedCardText(String(localized: "Subagents are still running."))
            if let count = dialog.body.first {
                BlockedCardText(count)
            }
        case .grokFork:
            BlockedCardText(
                String(localized: "Either answer forks this conversation and moves Grok Build to the fork. Chat stays here and holds messages until you switch back with /resume in the terminal."))
        case .openCodePermission:
            // The action and its target, then OpenCode's lines about it; a
            // command has only its `$` line, shown as the target instead.
            if let target = dialog.body.first ?? card.request?.summary ?? subject.command {
                BlockedCodeBox(text: target)
            }
            let notes = subject.notes.filter { !dialog.body.isEmpty || !$0.hasPrefix("$ ") }
            ForEach(Array(notes.enumerated()), id: \.offset) { @Sendable item in
                MainActorContent {
                    BlockedCardText(item.element)
                }
            }
            if let focused = dialog.focus.focusedOrdinal, focused != 1, let option = dialog.option(focused) {
                BlockedCardText(String(localized: "Selected in the terminal: \(option.label)"))
            }
        case .codexNetwork:
            EmptyView()
        }
    }

    /// A command under its description; a file by itself, since the title
    /// names the tool; else the card's own words, unless the title already
    /// asks them, as before a subagent starts.
    @ViewBuilder
    private var grokPermission: some View {
        let subject = dialog.subject
        if let command = subject.command {
            if let description = subject.commandDescription {
                BlockedCardText(description)
            }
            BlockedCodeBox(text: card.request?.summary ?? command)
        } else if let path = subject.filePath {
            BlockedCodeBox(text: card.request?.summary ?? path)
        } else if let description = dialog.body.first, !dialog.asksInTitle {
            BlockedCardText(description)
        }
    }

    // MARK: Choices

    /// Matches the planner: only Claude asks multi-select questions here;
    /// Oh My Pi's stay in the terminal.
    private var isMultiSelect: Bool {
        dialog.kind == .claudeQuestion && dialog.options.contains { $0.role == .next }
    }

    @ViewBuilder
    private var choices: some View {
        if isMultiSelect {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(dialog.options.filter { $0.role == .answer }, id: \.ordinal) { @Sendable option in
                    MainActorContent {
                        BlockedToggleRow(
                            label: option.label, detail: option.detail, isOn: selection.contains(option.ordinal)
                        ) {
                            selection.formSymmetricDifference([option.ordinal])
                        }
                    }
                }
            }
            Button {
                perform(.submitSelection(selection))
            } label: {
                Text(verbatim: dialog.options.first { $0.role == .next }?.label ?? String(localized: "Next"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(selection.isEmpty || dialog.answersHeldByDraft)
            ForEach(dialog.options.filter { $0.role == .chat }, id: \.ordinal) { @Sendable option in
                MainActorContent {
                    BlockedOptionButton(option: option, emphasis: .plain) { perform(.choose(ordinal: option.ordinal)) }
                }
            }
        } else if !pinsChoices {
            let buttons = dialog.options.filter { $0.role != .otherText && $0.role != .next }
            // The first plain way to allow or go on leads. A question's
            // answers stand level, and a choice that saves a rule or
            // switches the mode never leads.
            let lead = buttons.first { [.approve, .trust, .submit].contains($0.role) }?.ordinal
            VStack(spacing: 8) {
                ForEach(buttons, id: \.ordinal) { @Sendable option in
                    MainActorContent {
                        BlockedOptionButton(option: option, emphasis: emphasis(of: option, leads: option.ordinal == lead)) {
                            perform(.choose(ordinal: option.ordinal))
                        }
                    }
                }
            }
            .disabled(dialog.answersHeldByDraft)
        }
        if let note = dialog.note {
            Text(verbatim: note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        switch dialog.kind {
        case .codexAsyncCollapsed:
            Button {
                perform(.expandQuestions)
            } label: {
                Text("Answer Questions")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
        case .codexAsyncQuestion:
            Button("Skip Question") { perform(.skipQuestion) }
                .font(.subheadline)
                .buttonStyle(.borderless)
        case .grokQuestion where dialog.options.contains(where: { $0.role == .otherText }):
            Text("Type your own answer in the terminal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .ompQuestion, .ompQuestionReview:
            VStack(alignment: .leading, spacing: 4) {
                if dialog.focus.composerDraftGuard {
                    Text(verbatim: DialogPlanError.composerDraft.message)
                }
                if dialog.options.contains(where: { $0.role == .otherText }) {
                    Text("Type your own answer in the terminal.")
                }
                Text("Stop cancels the question and ends Oh My Pi's turn.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .openCodeQuestion:
            Text("Type your own answer in the terminal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// A trust screen's two short answers make one decision, so they share
    /// a row of capsules whatever order the program lists them in: leaving
    /// on the left at its label's width, trusting on the right filling the
    /// rest. Labels too long for one row stack, trusting first. Keys follow
    /// ordinals, not this order. Pinned below the text by `pinsChoices`.
    private var trustChoices: some View {
        let trusting = dialog.options.filter { $0.role == .trust }
        let leaving = dialog.options.filter { $0.role != .trust }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                trustChoiceButtons(leaving + trusting, stacked: false)
            }
            VStack(spacing: 8) {
                trustChoiceButtons(trusting + leaving, stacked: true)
            }
        }
        .disabled(dialog.answersHeldByDraft)
    }

    private func trustChoiceButtons(_ options: [DialogOption], stacked: Bool) -> some View {
        ForEach(options, id: \.ordinal) { @Sendable option in
            MainActorContent {
                BlockedTrustChoice(
                    label: option.label, leads: option.role == .trust, fills: stacked || option.role == .trust
                ) {
                    perform(.choose(ordinal: option.ordinal))
                }
            }
        }
    }

    private func emphasis(of option: DialogOption, leads: Bool) -> BlockedOptionEmphasis {
        switch option.role {
        case .decline, .exitProgram: .destructive
        case .approvePersistent: .caution(option.persistenceNote(program: dialog.program))
        case .approveModeSwitch: .caution(String(localized: "Switches the permission mode."))
        default: leads ? .primary : .plain
        }
    }

    // MARK: Typed answers

    @ViewBuilder
    private var textEntry: some View {
        switch dialog.kind {
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead:
            noteEntry
        case .claudePlan:
            if let field = dialog.options.last(where: { $0.role == .otherText && $0.input != nil }) {
                planFeedback(field)
            }
        case .claudeQuestion:
            if !isMultiSelect, let field = dialog.options.first(where: { $0.role == .otherText && $0.input != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    BlockedTextField(placeholder: field.label, text: $text, isFocused: $isTextFocused)
                    Button("Send") { perform(.respond(ordinal: field.ordinal, text: text)) }
                        .buttonStyle(.bordered)
                        .disabled(!hasText)
                }
            }
        case .codexQuestion:
            // `None of the above` answers as it is, or with notes.
            if let field = dialog.options.first(where: { $0.role == .otherText }) {
                VStack(alignment: .leading, spacing: 8) {
                    BlockedTextField(placeholder: String(localized: "Add details"), text: $text, isFocused: $isTextFocused)
                    Button {
                        perform(hasText ? .respond(ordinal: field.ordinal, text: text) : .choose(ordinal: field.ordinal))
                    } label: {
                        Text(verbatim: field.label)
                    }
                    .buttonStyle(.bordered)
                }
            }
        default:
            EmptyView()
        }
    }

    /// Claude's Tab on `Yes` or `No`: the answer with a note.
    @ViewBuilder
    private var noteEntry: some View {
        if isAddingNote {
            VStack(alignment: .leading, spacing: 8) {
                BlockedTextField(placeholder: String(localized: "Tell Claude what to do"), text: $text, isFocused: $isTextFocused)
                HStack(spacing: 8) {
                    if let allow = dialog.options.first(where: { $0.role == .approve }) {
                        Button("Allow with Note") { perform(.amend(ordinal: allow.ordinal, note: text)) }
                            .buttonStyle(.bordered)
                            .disabled(!hasText)
                    }
                    if let decline = dialog.options.first(where: { $0.role == .decline }) {
                        Button("Decline with Note", role: .destructive) {
                            perform(.amend(ordinal: decline.ordinal, note: text))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasText)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        isAddingNote = false
                        text = ""
                    }
                    .buttonStyle(.borderless)
                }
                .font(.subheadline)
            }
        } else {
            Button {
                isAddingNote = true
                isTextFocused = true
            } label: {
                Label("Add a Note", systemImage: "text.bubble")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    /// The plan's feedback row: sent back, or approved with the note, which
    /// takes the first approval option and its mode.
    private func planFeedback(_ field: DialogOption) -> some View {
        let approvesWithNote = field.detail?.hasPrefix("shift+tab to approve") == true
        let approval = dialog.options.first { $0.role != .otherText }
        return VStack(alignment: .leading, spacing: 8) {
            BlockedTextField(placeholder: field.label, text: $text, isFocused: $isTextFocused)
            HStack(spacing: 8) {
                Button("Send Back") { perform(.respond(ordinal: field.ordinal, text: text)) }
                    .buttonStyle(.bordered)
                if approvesWithNote {
                    Button("Approve with Note") { perform(.approvePlan(note: text)) }
                        .buttonStyle(.bordered)
                }
            }
            .font(.subheadline)
            .disabled(!hasText)
            if approvesWithNote, let approval {
                Text("Approve with Note picks “\(approval.label)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func perform(_ action: DialogAction) {
        isTextFocused = false
        Task { await store.perform(action) }
    }
}

/// The card folded away, with Stop still at hand.
private struct BlockedCollapsedBar: View {
    let store: BlockedCardStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dialog: BlockedDialog? {
        if case .card(let card) = store.content { return card.dialog }
        return nil
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // One line can't hold the buttons at these sizes: the title
                // goes above them, and a long button wraps.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        icon
                        title
                    }
                    HStack(spacing: 10) {
                        buttons
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    icon
                    title
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Only the title gives way on a narrow screen.
                    buttons
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var icon: some View {
        Image(systemName: "hand.raised.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(verbatim: dialog?.cardTitle ?? String(localized: "Waiting for Input"))
            .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private var buttons: some View {
        if let dialog, dialog.canStop {
            Button(dialog.stopTitle, role: .destructive) {
                Task { await store.perform(.dismiss) }
            }
            .disabled(!store.canStop)
        }
        Button("Show") { store.isCollapsed = false }
    }
}

extension DialogOption {
    /// What a persistent approval keeps, for its caution line. Claude Code
    /// 2.1.301's `always allow access to <dir> from this project` adds the
    /// folder for the session and saves no rule; its `don't ask again`
    /// options and Codex 0.162.1's `(a)`/`(p)` ones save one. Oh My Pi
    /// 18.12's `Approve <tool> for this session` saves none and stops asking
    /// until the session ends. Grok Build's `Always allow: <prefix>` saves
    /// the rule for the project's folder, where it outlives the session,
    /// and `allow all edits during this session` saves none (the 1.0.45
    /// source, `permission/hub_gate.rs`; not captured live). OpenCode
    /// 2.0.32's `Always allow` saves a rule for the project whose patterns
    /// reach past the request: `*` for most tools, a command's first words
    /// (`rm *` for `rm -rf build`), or a subagent's type. OpenCode lists
    /// them only while that option has focus, which the card's keys pass
    /// straight through. Recheck when a program's version changes.
    func persistenceNote(program: ChatProgram) -> String {
        let folded = DialogRowScanner.comparable(label.lowercased())
        switch program {
        case .omp:
            // The prefix and suffix are Oh My Pi's own label, matched.
            let prefix = "Approve ", suffix = " for this session"
            guard label.hasPrefix(prefix) && label.hasSuffix(suffix) && label.count > prefix.count + suffix.count
            else { return String(localized: "Oh My Pi won't ask again for this tool in this session.") }
            let subject = String(label.dropFirst(prefix.count).dropLast(suffix.count))
            return String(localized: "Oh My Pi won't ask again for \(subject) in this session.")
        case .claude where folded.contains(DialogRowScanner.comparable("always allow access to")):
            return String(localized: "Lets Claude work in this folder for the session.")
        case .grok where folded.contains(DialogRowScanner.comparable("all edits during this session")):
            return String(localized: "Grok Build won't ask about edits again in this session.")
        case .grok:
            return String(localized: "Grok Build saves this rule for the project and won't ask again.")
        case .claude, .codex, .pi:
            return String(localized: "Saves a rule, so this isn't asked again.")
        case .opencode:
            return String(localized: "Saves an OpenCode rule for this project that can allow more than this request.")
        }
    }
}

private extension BlockedDialog {
    var cardTitle: String {
        switch kind {
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion, .ompQuestion, .grokQuestion, .openCodeQuestion:
            String(localized: "Question")
        case .codexAsyncCollapsed: String(localized: "Questions")
        case .ompApproval: subject.toolName.map { String(localized: "Allow \($0)") } ?? String(localized: "Allow Tool")
        case .grokCancelTurn: String(localized: "Subagents Still Running")
        // The program's own title stays the page's progress, which the
        // planner matches; the card says it in the user's language.
        case .claudeQuestionReview: String(localized: "Review your answers")
        case .ompQuestionReview: String(localized: "Review answers")
        default: title.hasSuffix(":") ? String(title.dropLast()) : title
        }
    }

    /// The note on Codex's folded questions, whose title is its own
    /// `2 questions`: the count, in the user's words.
    var collapsedQuestionsNote: String {
        guard let count = Int(title.prefix { $0.isNumber }) else {
            return String(localized: "Codex asked questions. Its turn goes on, and the answers go with its next step.")
        }
        return count == 1
            ? String(localized: "Codex asked \(count) question. Its turn goes on, and the answers go with its next step.")
            : String(localized: "Codex asked \(count) questions. Its turn goes on, and the answers go with its next step.")
    }

    /// Whether Stop does something a card can name: the planner refuses it
    /// on Codex's asynchronous question, and on Grok Build's questions and
    /// subagent panel, where Esc only parks the keyboard or keeps the turn
    /// running.
    var canStop: Bool { ![.codexAsyncQuestion, .grokQuestion, .grokCancelTurn, .grokFork].contains(kind) }

    /// What Stop does, for the folded card and an open card whose options
    /// don't send it: it quits Claude Code or Codex on the trust dialog
    /// (Codex without `--no-daemon` goes back to its Agent Command Center
    /// instead), only denies an Oh My Pi approval, presses a Grok Build
    /// permission's reject row, rejects an OpenCode permission and
    /// dismisses an OpenCode question, as OpenCode's `esc dismiss` says.
    var stopTitle: String {
        switch kind {
        case .claudeWorkspaceTrust: String(localized: "Exit Claude Code")
        case .codexWorkspaceTrust: options.first { $0.role == .decline }?.label ?? String(localized: "Quit Codex")
        case .ompApproval, .grokPermission: String(localized: "Deny")
        case .openCodePermission: String(localized: "Reject")
        case .openCodeQuestion: String(localized: "Dismiss")
        default: String(localized: "Stop")
        }
    }

    /// Whether the open card offers Esc itself: only when no option
    /// already sends it.
    var stopsFromCard: Bool {
        canStop && !options.contains { [.decline, .exitProgram, .cancel].contains($0.role) }
    }
}

/// A trust answer as a capsule, in Liquid Glass where the system has it:
/// trusting prominent, the way out red on clear glass.
private struct BlockedTrustChoice: View {
    let label: String
    let leads: Bool
    /// Whether the capsule takes the row's spare width.
    let fills: Bool
    let action: () -> Void

    var body: some View {
        Button(role: leads ? nil : .destructive, action: action) {
            Text(verbatim: label)
                .font(leads ? .body.weight(.semibold) : .body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: fills ? .infinity : nil)
                .padding(.horizontal, fills ? 0 : 6)
        }
        .modifier(BlockedTrustChoiceStyle(leads: leads))
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

private struct BlockedTrustChoiceStyle: ViewModifier {
    let leads: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if leads {
                content.buttonStyle(.glassProminent)
            } else {
                // Glass ignores the destructive role's color.
                content.buttonStyle(.glass).tint(.red)
            }
        } else if leads {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Parts

struct BlockedCardHeader: View {
    let title: String
    let detail: String?
    let isActing: Bool
    /// Nil for a title the Agent wrote, which shows every line.
    var lineLimit: Int? = 2
    let collapse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(lineLimit)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isActing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Answering")
            }
            Button(action: collapse) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Minimize")
        }
    }
}

struct BlockedCardFooter: View {
    let notice: String?
    var stopTitle: String? = nil
    let isReady: Bool
    /// Whether Stop acts, when it may while the rest waits.
    var canStop: Bool? = nil
    var stop: () -> Void = {}
    /// A quieter way out than Stop, at the trailing edge: Claude's `Chat
    /// about this` on a question form.
    var asideTitle: String? = nil
    var aside: () -> Void = {}
    /// Shows or hides the key pad, where options cover most answers.
    var keys: Binding<Bool>? = nil
    var openTerminal: (() -> Void)? = nil

    private var hasControls: Bool {
        stopTitle != nil || asideTitle != nil || keys != nil || openTerminal != nil
    }

    var body: some View {
        if notice != nil || hasControls {
            VStack(alignment: .leading, spacing: 8) {
                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.blocked-card.notice")
                }
                if hasControls {
                    HStack(spacing: 16) {
                        if let stopTitle {
                            Button(stopTitle, role: .destructive, action: stop)
                                .disabled(!(canStop ?? isReady))
                        }
                        if let keys {
                            Button {
                                keys.wrappedValue.toggle()
                            } label: {
                                Label(keys.wrappedValue ? "Hide Keys" : "Keys", systemImage: "keyboard")
                            }
                        }
                        Spacer(minLength: 0)
                        if let asideTitle {
                            Button(asideTitle, action: aside)
                                .disabled(!isReady)
                        }
                        if let openTerminal {
                            Button(action: openTerminal) {
                                Label("Open in Terminal", systemImage: "terminal")
                            }
                        }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

enum BlockedOptionEmphasis: Equatable {
    case primary
    case plain
    case destructive
    /// Secondary, with a line saying what else choosing it does.
    case caution(String)
}

struct BlockedOptionButton: View {
    let label: String
    let detail: String?
    let emphasis: BlockedOptionEmphasis
    let action: () -> Void

    init(option: DialogOption, emphasis: BlockedOptionEmphasis, action: @escaping () -> Void) {
        self.init(label: option.label, detail: option.detail, emphasis: emphasis, action: action)
    }

    init(label: String, detail: String? = nil, emphasis: BlockedOptionEmphasis, action: @escaping () -> Void) {
        self.label = label
        self.detail = detail
        self.emphasis = emphasis
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label)
                        .font(.body.weight(emphasis == .primary ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty, detail != label {
                        Text(verbatim: detail)
                            .font(.caption)
                            .opacity(0.75)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(BlockedOptionStyle(emphasis: emphasis))
            if case .caution(let warning) = emphasis {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 4)
            }
        }
    }
}

/// Options stand apart from the gray boxes that quote the request: the
/// lead option filled, a decline in red, the rest raised and outlined.
private struct BlockedOptionStyle: ButtonStyle {
    let emphasis: BlockedOptionEmphasis
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(fill, in: shape)
            .overlay {
                if isRaised { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.45)
    }

    private var isRaised: Bool {
        switch emphasis {
        case .plain, .caution: true
        case .primary, .destructive: false
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: .white
        case .destructive: .red
        case .plain, .caution: .primary
        }
    }

    private var fill: Color {
        switch emphasis {
        case .primary: .accentColor
        case .destructive: .red.opacity(0.12)
        case .plain, .caution: Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
}

struct BlockedToggleRow: View {
    let label: String
    var detail: String? = nil
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label)
                        .foregroundStyle(.primary)
                    if let detail, !detail.isEmpty, detail != label {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct BlockedTextField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text)
            .focused(isFocused)
            .submitLabel(.done)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

struct BlockedCardText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BlockedCodeBox: View {
    let text: String
    var lineLimit: Int? = 6
    var isSmall = false

    var body: some View {
        Text(verbatim: text)
            .font(.system(isSmall ? .caption : .footnote, design: .monospaced))
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// A file dialog's content: an edit's lines tinted by their `+` or `-`
/// mark, which follows the line number.
private struct BlockedChangeBox: View {
    let lines: [String]
    let marksChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(Self.lineLimit).enumerated()), id: \.offset) { @Sendable _, line in
                MainActorContent {
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(tint(of: line))
                }
            }
            if lines.count > Self.lineLimit {
                let more = lines.count - Self.lineLimit
                Text(more == 1 ? String(localized: "\(more) more line") : String(localized: "\(more) more lines"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
    }

    private static let lineLimit = 40

    private func tint(of line: String) -> Color {
        guard marksChanges else { return .clear }
        let mark = line.drop { $0 == " " || $0.isNumber }.first
        switch mark {
        case "+": return .green.opacity(0.18)
        case "-": return .red.opacity(0.18)
        default: return .clear
        }
    }
}

private struct BlockedPlanBox: View {
    let text: String

    var body: some View {
        ChatMarkdownView(blocks: ChatMarkdown.blocks(from: text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Grows with its content up to `maxHeight`, then scrolls. A smaller parent
/// proposal, such as the room above a keyboard, also limits the viewport.
struct BlockedScrollingContent<Content: View>: View {
    let maxHeight: CGFloat
    /// Fades an edge's cut line while more waits past it, where answers
    /// sit right under the content rather than the card's edge.
    var fadesEdges = false
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var hidden = BlockedEdgeFade.Hidden()

    var body: some View {
        let height = min(max(contentHeight, 1), maxHeight)
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(minHeight: 0, idealHeight: height, maxHeight: height)
        .scrollBounceBehavior(.basedOnSize)
        .modifier(BlockedEdgeFade(isActive: fadesEdges, hidden: $hidden))
    }
}

private struct BlockedEdgeFade: ViewModifier {
    struct Hidden: Equatable {
        var above = false
        var below = false
    }

    let isActive: Bool
    @Binding var hidden: Hidden

    func body(content: Content) -> some View {
        if isActive {
            content
                .onScrollGeometryChange(for: Hidden.self) { geometry in
                    let offset = geometry.contentOffset.y + geometry.contentInsets.top
                    return Hidden(
                        above: offset > 1,
                        below: offset + geometry.containerSize.height < geometry.contentSize.height - 1)
                } action: { _, next in
                    hidden = next
                }
                .mask {
                    VStack(spacing: 0) {
                        edge(hides: hidden.above, from: .bottom, to: .top)
                        Rectangle()
                        edge(hides: hidden.below, from: .top, to: .bottom)
                    }
                }
        } else {
            content
        }
    }

    private func edge(hides: Bool, from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(colors: [.black, .black.opacity(hides ? 0 : 1)], startPoint: start, endPoint: end)
            .frame(height: 24)
    }
}
