import SwiftUI

/// A Blocked Agent's dialog in the Composer's place (ADR 0024): the
/// program's own choices as native buttons, answered with keys. Labels are
/// the program's text. The first plain way to go on is the card's one
/// filled button, with the decline beside it in the destructive color. The
/// options that also save a rule or switch the permission mode fold under
/// one row below, and say what they keep when shown. Nothing asks for
/// confirmation and nothing can be undone, as in the terminal.
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
                    BlockedReadingCard()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.blocked-card")
    }
}

/// herdr reports the Agent Blocked and no read has shown its dialog yet
/// (`BlockedCardStore.replacesComposer`). The status chip already says
/// Blocked, so the place only shows that Chat is reading.
private struct BlockedReadingCard: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading the Agent's screen")
            .accessibilityIdentifier("chat.blocked-reading")
    }
}

// MARK: - Known dialogs

private struct BlockedDialogCard: View {
    let card: BlockedCard
    let store: BlockedCardStore
    let maxHeight: CGFloat
    @State private var text = ""
    @State private var isAddingNote = false
    /// Whether the answers past the decision show (`moreAnswers`).
    @State private var showsMoreAnswers = false
    @State private var selection: Set<Int>
    /// The answer tapped beside the previews, by ordinal, until the
    /// terminal's focus has followed it (`showPreview`).
    @State private var previewChoice: Int?
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
                symbol: dialog.symbol, title: dialog.cardTitle, detail: dialog.positionLabel ?? dialog.pageLabel,
                isActing: store.progress == .acting,
                lineLimit: dialog.asksInTitle ? nil : 2, collapse: { store.isCollapsed = true })
            BlockedScrollingContent(maxHeight: scrollingMaxHeight) {
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
                    // A note takes the answers' place: its buttons send
                    // the same answers with it.
                    if !isAddingNote {
                        choices
                    }
                }
                .disabled(!isReady)
            }
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
                stop: { perform(.dismiss) },
                asideTitle: chat?.label,
                aside: {
                    if let chat { perform(.choose(ordinal: chat.ordinal)) }
                })
        }
    }

    /// Claude's `Chat about this`: no answer, a conversation instead. It
    /// stands apart from the answers, as on a question form.
    private var chat: DialogOption? {
        dialog.options.first { $0.role == .chat }
    }

    /// A trust screen's answers stay below its scrolling text, in view on
    /// a phone, where the folder and the program's warning fill the card's
    /// share. The text gives up their room, so the card stays as tall.
    private var pinsChoices: Bool {
        [.claudeWorkspaceTrust, .codexWorkspaceTrust, .agyWorkspaceTrust].contains(dialog.kind)
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
            BlockedCodeBox(text: card.request?.summary ?? subject.command ?? "", isCommand: true)
        case .codexExec:
            if let reason = subject.reason {
                BlockedCardText(reason)
            }
            BlockedCodeBox(text: subject.command ?? card.request?.summary ?? "", isCommand: true)
        case .claudeFileEdit, .claudeFileCreate:
            BlockedCodeBox(text: card.request?.summary ?? subject.filePath ?? "")
            if !subject.changeLines.isEmpty {
                BlockedChangeBox(lines: subject.changeLines, marksChanges: dialog.kind == .claudeFileEdit)
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
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion, .ompQuestion, .grokQuestion, .openCodeQuestion,
            .agyQuestion:
            VStack(alignment: .leading, spacing: 4) {
                // Codex's asynchronous questions name their page by the
                // question itself, and `Question i/n` shows in the header
                // as `i of n`, so neither repeats here.
                if let progress = dialog.progress, dialog.kind != .codexAsyncQuestion, dialog.questionPage == nil {
                    Text(verbatim: progress)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: subject.question ?? dialog.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .claudeQuestionReview, .ompQuestionReview:
            // Not on the answers' fill: these rows answer nothing.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(subject.reviewAnswers.enumerated()), id: \.offset) { @Sendable index, pair in
                    MainActorContent {
                        if index > 0 {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: pair.question)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(verbatim: pair.answer)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        case .claudeWorkspaceTrust, .codexWorkspaceTrust, .agyWorkspaceTrust:
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
                BlockedCodeBox(text: card.request?.summary ?? command, isCommand: true)
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
                BlockedCodeBox(text: target, isCommand: dialog.body.isEmpty && subject.command != nil)
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
        case .agyCommand:
            if let summary = card.request?.detail {
                BlockedCardText(summary)
            }
            // What the screen shows; the call fills in only what it cut.
            BlockedCodeBox(text: BlockedRequestMatch.agyRequest(on: dialog, call: card.request), isCommand: true)
        case .agyFileEdit, .agyFileCreate:
            BlockedCodeBox(text: BlockedRequestMatch.agyRequest(on: dialog, call: card.request))
            let lines = BlockedRequestMatch.agyChanges(on: dialog, call: card.request)
            if !lines.isEmpty {
                BlockedChangeBox(lines: lines, marksChanges: true)
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
            BlockedCodeBox(text: card.request?.summary ?? command, isCommand: true)
        } else if let path = subject.filePath {
            BlockedCodeBox(text: card.request?.summary ?? path)
        } else if let description = dialog.body.first, !dialog.asksInTitle {
            BlockedCardText(description)
        }
    }

    // MARK: Choices

    /// Matches the planners: Claude's page with a `Next` button, and
    /// Antigravity CLI's answers with check boxes. Oh My Pi's stay in the
    /// terminal.
    private var isMultiSelect: Bool { dialog.isMultiSelect }

    /// What sends a multi-select page's answers: Claude's button, or
    /// Antigravity CLI's Enter, which turns to the next question until the
    /// last. Also what sends the answer chosen beside its preview: Claude's
    /// Enter.
    private var selectionTitle: String {
        if let button = dialog.options.first(where: { $0.role == .next }) { return button.label }
        // A page of Claude's form turns to the next question, or to the
        // review page, which submits.
        if dialog.kind == .claudeQuestion, dialog.subject.questionHeaders.count > 1 {
            return String(localized: "Next")
        }
        return dialog.questionPage.map { $0.index < $0.count } == true
            ? String(localized: "Next")
            : String(localized: "Submit", comment: "Sends the chosen answers on a question's last page")
    }

    /// Antigravity CLI's `Write-in...` on a multi-select question. Enter in
    /// its field submits the checked answers with the text, so the field
    /// goes with Submit rather than a Send of its own.
    private var writeInWithSelection: DialogOption? {
        guard dialog.kind == .agyQuestion, isMultiSelect else { return nil }
        return dialog.options.first { $0.role == .otherText && $0.input != nil }
    }

    /// Sends the checked answers, with `text` written in where given.
    private func selectionButton(writing text: String?) -> some View {
        BlockedPrimaryButton(title: selectionTitle) {
            perform(.submitSelection(selection, text: text))
        }
        .disabled((selection.isEmpty && text == nil) || dialog.answersHeldByDraft)
    }

    /// The question this page asks as the call spells it out, where the
    /// transcript has the call while its dialog is open (Claude Code
    /// 2.1.330 writes it only once answered): beside a preview the screen
    /// leaves out each option's description, and cuts a long preview short.
    private var askedQuestion: ChatQuestion? {
        let shown = DialogRowScanner.comparable(dialog.subject.question ?? dialog.title)
        return card.request?.questions.first { DialogRowScanner.comparable($0.text) == shown }
    }

    private func asked(_ option: DialogOption) -> ChatQuestion.Option? {
        let label = DialogRowScanner.comparable(option.label)
        return askedQuestion?.options.first { DialogRowScanner.comparable($0.label) == label }
    }

    /// The answer the terminal has the focus on, which Enter gives. None
    /// while `Chat about this` has it.
    private var focusedAnswer: Int? {
        dialog.options.first { $0.isFocused && $0.role == .answer }?.ordinal
    }

    /// The answer the card marks: the one just tapped, else the terminal's.
    private var chosenAnswer: Int? { previewChoice ?? focusedAnswer }

    /// The preview under the answers: the call's for the chosen answer, or
    /// without a matching call the lines the box shows, which are those of
    /// the answer the terminal is on.
    private var shownPreview: String? {
        if askedQuestion != nil { return chosenAnswer.flatMap(dialog.option).flatMap(asked)?.preview }
        let lines = dialog.subject.previewLines
        guard focusedAnswer != nil, !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// What the box says it left out of the preview shown from the screen.
    private var previewCutNote: String? {
        askedQuestion == nil ? dialog.subject.previewCutNote : nil
    }

    /// A question with previews: its answers as one list where one is
    /// chosen, with that one's preview under them. Choosing gives no
    /// answer, as in the terminal, where Enter does (`previewAnswer`): it
    /// moves the terminal's focus, and the box draws that answer's preview.
    @ViewBuilder
    private var previewChoices: some View {
        optionRows(dialog.options.filter { $0.role == .answer }) { option in
            let asked = asked(option)
            return BlockedOptionRow(
                label: asked?.label ?? option.label, detail: asked?.detail,
                mark: .choice(option.ordinal == chosenAnswer)
            ) {
                showPreview(of: option.ordinal)
            }
        }
        if let shownPreview {
            BlockedOptionPreview(text: shownPreview)
                // The box still shows the last answer's until the focus moves.
                .opacity(previewChoice == nil || askedQuestion != nil ? 1 : 0.4)
            if let previewCutNote {
                Text("Claude Code's terminal cuts this preview: \(previewCutNote)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func showPreview(of ordinal: Int) {
        guard ordinal != focusedAnswer, previewChoice == nil else { return }
        previewChoice = ordinal
        Task {
            await store.perform(.focus(ordinal: ordinal))
            previewChoice = nil
        }
    }

    @ViewBuilder
    private var choices: some View {
        if dialog.subject.showsPreviews {
            previewChoices
        } else if isMultiSelect {
            optionRows(dialog.options.filter { $0.role == .answer }) { option in
                BlockedOptionRow(
                    label: option.label, detail: option.detail, mark: .check(selection.contains(option.ordinal))
                ) {
                    selection.formSymmetricDifference([option.ordinal])
                }
            }
            // With a field, Submit goes under it (`textEntry`).
            if writeInWithSelection == nil {
                selectionButton(writing: nil)
            }
        } else if !pinsChoices {
            let buttons = dialog.options.filter { ![.otherText, .next, .chat].contains($0.role) }
            // The first plain way to allow or go on leads, wherever the
            // program lists it, and the first decline stands beside it:
            // the two make the card's decision. A question's answers stand
            // level, and a choice that saves a rule or switches the mode
            // never leads.
            let lead = buttons.first { [.approve, .trust, .submit].contains($0.role) }
            let decline = lead == nil ? nil : buttons.first { $0.role == .decline }
            let rest = buttons.filter { $0.ordinal != lead?.ordinal && $0.ordinal != decline?.ordinal }
            VStack(spacing: 10) {
                if let lead {
                    decision(going: [lead], leaving: decline.map { [$0] } ?? [])
                    moreAnswers(rest)
                } else {
                    optionRows(rest, row: answerRow)
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
            BlockedPrimaryButton(title: String(localized: "Answer Questions")) {
                perform(.expandQuestions)
            }
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

    /// A trust screen's answers, pinned below its text by `pinsChoices`.
    private var trustChoices: some View {
        decision(
            going: dialog.options.filter { $0.role == .trust }, leaving: dialog.options.filter { $0.role != .trust }
        )
        .disabled(dialog.answersHeldByDraft)
    }

    /// The answers that make a card's one decision share a row whatever
    /// order the program lists them in: leaving on the left at its label's
    /// width, going on filled on the right and taking the rest. Labels too
    /// long for one row stack, going on first. Keys follow ordinals, not
    /// this order.
    private func decision(going: [DialogOption], leaving: [DialogOption]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                decisionButtons(leaving + going, going: going, stacked: false)
            }
            // As tall as each other where one has a second line.
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                decisionButtons(going + leaving, going: going, stacked: true)
            }
        }
    }

    private func decisionButtons(_ options: [DialogOption], going: [DialogOption], stacked: Bool) -> some View {
        ForEach(options, id: \.ordinal) { @Sendable option in
            MainActorContent {
                let goes = going.contains { $0.ordinal == option.ordinal }
                Button {
                    perform(.choose(ordinal: option.ordinal))
                } label: {
                    VStack(spacing: 1) {
                        Text(verbatim: option.label)
                        if let detail = option.detail, !detail.isEmpty, detail != option.label {
                            Text(verbatim: detail)
                                .font(.caption)
                                .opacity(0.8)
                        }
                    }
                    .frame(maxWidth: stacked || goes ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
                    .padding(.horizontal, stacked || goes ? 0 : 4)
                }
                .buttonStyle(BlockedButtonStyle(tone: goes ? .filled : .destructive))
            }
        }
    }

    /// The answers past the decision, which allow and also save a rule or
    /// switch the mode. They fold under one row until asked for: a card
    /// opens on its decision, and each of these takes lines to say what it
    /// keeps. Open, every one shows whole.
    @ViewBuilder
    private func moreAnswers(_ options: [DialogOption]) -> some View {
        if !options.isEmpty {
            BlockedOptionGroup {
                Button {
                    showsMoreAnswers.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(
                            String(
                                localized: "Dialog More Options", defaultValue: "More Options",
                                comment: "Row on a Blocked card that shows the dialog's other answers, not more settings")
                        )
                        .font(.callout)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(showsMoreAnswers ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, BlockedCardStyle.rowInset)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(BlockedRowStyle())
                .accessibilityValue(showsMoreAnswers ? String(localized: "Expanded") : String(localized: "Collapsed"))
                if showsMoreAnswers {
                    ForEach(options, id: \.ordinal) { @Sendable option in
                        MainActorContent {
                            answerRow(option)
                                .divided(true)
                        }
                    }
                }
            }
        }
    }

    private func answerRow(_ option: DialogOption) -> BlockedOptionRow {
        BlockedOptionRow(label: option.label, detail: option.detail, emphasis: emphasis(of: option)) {
            perform(.choose(ordinal: option.ordinal))
        }
    }

    /// `options` as one list, or nothing for none.
    @ViewBuilder
    private func optionRows(
        _ options: [DialogOption], row: @escaping @MainActor (DialogOption) -> BlockedOptionRow
    ) -> some View {
        if !options.isEmpty {
            BlockedOptionGroup {
                ForEach(Array(options.enumerated()), id: \.element.ordinal) { @Sendable index, option in
                    MainActorContent {
                        row(option)
                            .divided(index > 0)
                    }
                }
            }
        }
    }

    private func emphasis(of option: DialogOption) -> BlockedOptionEmphasis {
        switch option.role {
        case .decline, .exitProgram: .destructive
        case .approvePersistent: .caution(option.persistenceNote(program: dialog.program))
        case .approveModeSwitch: .caution(String(localized: "Switches the permission mode."))
        default: .plain
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
        case .agyCommand:
            noteEntry
        case .claudeQuestion where dialog.subject.showsPreviews:
            previewAnswer
        case .claudeQuestion, .agyQuestion:
            // agy's `Write-in...` names a row, not what to type: its fields
            // say what the form's pages say. Claude's card keeps the row
            // label Claude draws.
            if writeInWithSelection != nil {
                VStack(alignment: .leading, spacing: 10) {
                    BlockedTextField(
                        placeholder: String(localized: "Type your own answer"), text: $text, isFocused: $isTextFocused)
                    selectionButton(writing: hasText ? text : nil)
                }
            } else if !isMultiSelect,
                let field = dialog.options.first(where: { $0.role == .otherText && $0.input != nil })
            {
                HStack(spacing: 8) {
                    BlockedTextField(
                        placeholder: dialog.kind == .agyQuestion
                            ? String(localized: "Type your own answer") : field.label,
                        text: $text, isFocused: $isTextFocused)
                    Button("Send") { perform(.respond(ordinal: field.ordinal, text: text)) }
                        .buttonStyle(BlockedButtonStyle())
                        .disabled(!hasText)
                }
            }
        case .codexQuestion:
            // `None of the above` answers as it is, or with notes.
            if let field = dialog.options.first(where: { $0.role == .otherText }) {
                VStack(alignment: .leading, spacing: 10) {
                    BlockedTextField(placeholder: String(localized: "Add details"), text: $text, isFocused: $isTextFocused)
                    Button {
                        perform(hasText ? .respond(ordinal: field.ordinal, text: text) : .choose(ordinal: field.ordinal))
                    } label: {
                        Text(verbatim: field.label)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BlockedButtonStyle())
                }
            }
        default:
            EmptyView()
        }
    }

    /// Notes the terminal already holds for a question with previews, in
    /// its open field or kept by the closed one. They go with the answer,
    /// and Heeler adds none to them.
    private var terminalNotes: String? {
        if let saved = dialog.focus.savedNotes { return saved }
        guard let open = dialog.focus.notesText, !open.isEmpty else { return nil }
        return open
    }

    /// Sends the answer chosen beside its preview, with the question's
    /// notes when the field has any: Claude's `n`.
    private var previewAnswer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let terminalNotes {
                BlockedCardText(String(localized: "Notes from the terminal: \(terminalNotes)"))
            } else {
                BlockedTextField(placeholder: String(localized: "Add notes"), text: $text, isFocused: $isTextFocused)
            }
            BlockedPrimaryButton(title: selectionTitle) {
                guard let chosenAnswer else { return }
                perform(
                    hasText && terminalNotes == nil
                        ? .amend(ordinal: chosenAnswer, note: text) : .choose(ordinal: chosenAnswer))
            }
            .disabled(chosenAnswer == nil)
        }
    }

    /// Claude's Tab on `Yes` or `No`: the answer with a note. While the
    /// field is open its two buttons stand in for the answers, declining on
    /// the left as on a trust screen.
    @ViewBuilder
    private var noteEntry: some View {
        if isAddingNote {
            VStack(spacing: 10) {
                BlockedTextField(
                    placeholder: String(
                        localized: "Tell \(dialog.program.chatName) what to do",
                        comment: "Placeholder of the note field on a permission card: the program's name"),
                    text: $text, isFocused: $isTextFocused)
                HStack(spacing: 8) {
                    if let decline = dialog.options.first(where: { $0.role == .decline }) {
                        Button {
                            perform(.amend(ordinal: decline.ordinal, note: text))
                        } label: {
                            Text("Decline with Note")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BlockedButtonStyle(tone: .destructive))
                    }
                    if let allow = dialog.options.first(where: { $0.role == .approve }) {
                        Button {
                            perform(.amend(ordinal: allow.ordinal, note: text))
                        } label: {
                            Text("Allow with Note")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BlockedButtonStyle(tone: .filled))
                    }
                }
                .disabled(!hasText)
                Button("Cancel") {
                    isAddingNote = false
                    text = ""
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
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
        return VStack(alignment: .leading, spacing: 10) {
            BlockedTextField(placeholder: field.label, text: $text, isFocused: $isTextFocused)
            HStack(spacing: 8) {
                Button("Send Back") { perform(.respond(ordinal: field.ordinal, text: text)) }
                if approvesWithNote {
                    Button("Approve with Note") { perform(.approvePlan(note: text)) }
                }
            }
            .buttonStyle(BlockedButtonStyle(isCompact: true))
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
        .font(.subheadline)
    }

    private var icon: some View {
        BlockedCardSymbol(name: dialog?.symbol ?? BlockedCardStyle.unknownSymbol)
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
            .buttonStyle(.borderless)
            .disabled(!store.canStop)
        }
        Button {
            store.isCollapsed = false
        } label: {
            Label("Show", systemImage: "chevron.up")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(ThemeVeil.control, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        case .agy where folded.contains(DialogRowScanner.comparable("persist to settings.json")):
            return String(
                localized: "Saves a rule in Antigravity CLI's settings, so commands that start this way aren't asked about again.")
        case .agy where folded.contains(DialogRowScanner.comparable("in this conversation")):
            return String(
                localized: "Antigravity CLI won't ask again in this conversation for commands that start this way.")
        case .claude, .codex, .pi, .agy, .amp:
            return String(localized: "Saves a rule, so this isn't asked again.")
        case .opencode:
            return String(localized: "Saves an OpenCode rule for this project that can allow more than this request.")
        }
    }
}

private extension BlockedDialog {
    /// Codex's and Antigravity CLI's `Question i/n` as the header's page
    /// indicator, `i of n` as a question form shows it; a single question
    /// has no pages.
    var pageLabel: String? {
        guard let page = questionPage, page.count > 1 else { return nil }
        return String(localized: "\(page.index) of \(page.count)")
    }

    var cardTitle: String {
        switch kind {
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion, .ompQuestion, .grokQuestion, .openCodeQuestion,
            .agyQuestion:
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
    /// on Codex's asynchronous question, on Grok Build's questions and
    /// subagent panel, where Esc only parks the keyboard or keeps the turn
    /// running, and on Antigravity CLI's trust prompt, where what Esc does
    /// isn't known.
    var canStop: Bool {
        ![.codexAsyncQuestion, .grokQuestion, .grokCancelTurn, .grokFork, .agyWorkspaceTrust].contains(kind)
    }

    /// Whether the open card offers Esc itself: only when no option
    /// already sends it.
    var stopsFromCard: Bool {
        canStop && !options.contains { [.decline, .exitProgram, .cancel].contains($0.role) }
    }
}

extension BlockedDialog {
    /// What the dialog asks about, as the symbol beside its title. A
    /// program's one dialog for every tool goes by what it shows.
    var symbol: String {
        switch kind {
        case .claudeBash, .codexExec, .agyCommand: "terminal"
        case .claudeFileEdit, .claudeFileCreate, .codexPatch, .agyFileEdit, .agyFileCreate: "pencil"
        case .claudeFileRead: "doc.text"
        case .claudeFetch, .codexNetwork: "globe"
        case .claudePlan: "list.bullet"
        case .claudeQuestion, .claudeQuestionReview, .codexQuestion, .codexAsyncCollapsed, .codexAsyncQuestion,
            .ompQuestion, .ompQuestionReview, .grokQuestion, .openCodeQuestion, .agyQuestion:
            "questionmark.circle"
        case .claudeWorkspaceTrust, .codexWorkspaceTrust, .agyWorkspaceTrust: "folder"
        case .grokCancelTurn, .grokFork: "arrow.triangle.branch"
        case .ompApproval, .grokPermission, .openCodePermission:
            subject.command != nil ? "terminal" : subject.filePath != nil ? "doc.text" : "hand.raised"
        }
    }

    /// What Stop does, for the folded card, a question form and an open
    /// card whose options don't send it: it quits Claude Code or Codex on
    /// the trust dialog (Codex without `--no-daemon` goes back to its Agent
    /// Command Center instead), only denies an Oh My Pi approval, presses a
    /// Grok Build permission's reject row, rejects an OpenCode permission,
    /// dismisses an OpenCode question, as OpenCode's `esc dismiss` says,
    /// and skips an Antigravity CLI question, as its `esc Skip` says: on a
    /// card the question on screen, on a form the page it shows, sent with
    /// the answers (`QuestionFormDraft.skip`); the turn goes on.
    var stopTitle: String {
        switch kind {
        case .claudeWorkspaceTrust: String(localized: "Exit Claude Code")
        case .codexWorkspaceTrust: options.first { $0.role == .decline }?.label ?? String(localized: "Quit Codex")
        case .ompApproval, .grokPermission: String(localized: "Deny")
        case .openCodePermission: String(localized: "Reject")
        case .openCodeQuestion: String(localized: "Dismiss")
        case .agyQuestion:
            String(localized: "Skip", comment: "On an Antigravity CLI question card: skips the question shown")
        default: String(localized: "Stop")
        }
    }
}

// MARK: - Parts

enum BlockedCardStyle {
    /// Buttons, fields and the answers' list.
    static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    /// A list row's inset, and a field's.
    static let rowInset: CGFloat = 14
    /// For a dialog Heeler can't name.
    static let unknownSymbol = "ellipsis.rectangle"
    /// A row's line about what else choosing it does.
    static let caution = Color(uiColor: AgentStatusPalette.yellowInk)
}

/// What a dialog asks about, in a column as wide for every glyph so titles
/// line up. The column grows with the text, or a large glyph would reach
/// the title beside it.
private struct BlockedCardSymbol: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 22

    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

struct BlockedCardHeader: View {
    /// What the dialog asks about (`BlockedDialog.symbol`).
    var symbol = BlockedCardStyle.unknownSymbol
    let title: String
    let detail: String?
    let isActing: Bool
    /// Nil for a title the Agent wrote, which shows every line.
    var lineLimit: Int? = 2
    let collapse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            BlockedCardSymbol(name: symbol)
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(lineLimit)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isActing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Answering")
            }
            Spacer(minLength: 8)
            Button(action: collapse) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            // Plain, so the chevron stays gray rather than take the tint.
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")
            // A full touch target in a header one line tall, its chevron
            // near the card's edge.
            .padding(.vertical, -8)
            .padding(.trailing, -12)
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
                    Label {
                        Text(verbatim: notice)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(BlockedCardStyle.caution)
                    }
                    .font(.footnote)
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

/// The filled button that sends what a card holds. A card's lead answer is
/// filled the same way, beside its decline, so a card fills one or the
/// other.
struct BlockedPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BlockedButtonStyle(tone: .filled))
    }
}

/// A card's buttons that stand by themselves: the filled one, and quiet
/// ones on the fill the answers' list has.
struct BlockedButtonStyle: ButtonStyle {
    enum Tone {
        case filled
        case quiet
        case destructive
    }

    var tone: Tone = .quiet
    /// A smaller button, for a step beside a field rather than an answer.
    var isCompact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .subheadline : tone == .filled ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, BlockedCardStyle.rowInset)
            .padding(.vertical, isCompact ? 6 : 10)
            .frame(minHeight: isCompact ? 40 : 46)
            .background(fill, in: BlockedCardStyle.shape)
            .contentShape(BlockedCardStyle.shape)
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch tone {
        case .filled: .white
        case .quiet: .primary
        case .destructive: .red
        }
    }

    private var fill: Color {
        tone == .filled ? .accentColor : ThemeVeil.control
    }
}

enum BlockedOptionEmphasis: Equatable {
    case plain
    case destructive
    /// Plain, with a line saying what else choosing it does.
    case caution(String)
}

/// A card's answers as the rows of one list: a question's, or the ones past
/// a card's decision.
struct BlockedOptionGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(ThemeVeil.control, in: BlockedCardStyle.shape)
        .clipShape(BlockedCardStyle.shape)
    }
}

/// One answer in a `BlockedOptionGroup`.
struct BlockedOptionRow: View {
    /// What a row that holds a choice shows before its label.
    enum Mark: Equatable {
        case none
        /// One of several, where one answers.
        case choice(Bool)
        /// One of several, where any number answer.
        case check(Bool)
    }

    let label: String
    var detail: String? = nil
    var emphasis: BlockedOptionEmphasis = .plain
    var mark: Mark = .none
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Self.markSpacing) {
                markSymbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label)
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(emphasis == .destructive ? Color.red : .primary)
                    if let detail, !detail.isEmpty, detail != label {
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if case .caution(let warning) = emphasis {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(BlockedCardStyle.caution)
                            .padding(.top, 1)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BlockedCardStyle.rowInset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(BlockedRowStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The row under a line that starts where its label does; a list's
    /// first row has none.
    func divided(_ shows: Bool) -> some View {
        overlay(alignment: .top) {
            if shows {
                Divider()
                    .padding(.leading, BlockedCardStyle.rowInset + (mark == .none ? 0 : Self.markWidth + Self.markSpacing))
            }
        }
    }

    private static let markWidth: CGFloat = 22
    private static let markSpacing: CGFloat = 12

    private var isOn: Bool {
        mark == .choice(true) || mark == .check(true)
    }

    @ViewBuilder
    private var markSymbol: some View {
        let name: String? = switch mark {
        case .none: nil
        case .choice(let isOn): isOn ? "checkmark.circle.fill" : "circle"
        case .check(let isOn): isOn ? "checkmark.square.fill" : "square"
        }
        if let name {
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(isOn ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                .frame(width: Self.markWidth)
                .accessibilityHidden(true)
        }
    }
}

private struct BlockedRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A shape, as a diff's tints are (`BlockedChangeBox`).
            .background { Rectangle().fill(configuration.isPressed ? ThemeVeil.control : .clear) }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct BlockedTextField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .focused(isFocused)
                .submitLabel(.done)
        }
        .padding(.horizontal, BlockedCardStyle.rowInset)
        .frame(minHeight: 46)
        .background(ThemeVeil.control, in: BlockedCardStyle.shape)
        .overlay {
            if isFocused.wrappedValue {
                BlockedCardStyle.shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        // The whole row takes the tap, not only the text's line.
        .contentShape(BlockedCardStyle.shape)
        .onTapGesture { isFocused.wrappedValue = true }
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

/// What a card quotes from the terminal: a command behind the shell's `$`,
/// or a path, an address or a folder as it is.
struct BlockedCodeBox: View {
    let text: String
    var isCommand = false

    var body: some View {
        ChatTerminalText(text: text, isCommand: isCommand, lineLimit: 6)
    }
}

/// What choosing a question's option gives, as the Agent wrote it for the
/// box Claude Code draws beside the options: a mockup, a snippet, a
/// diagram. Monospaced on the terminal's black, as that box is, and without
/// the fences of a code block, which the box leaves out too. A line wider
/// than the card scrolls sideways rather than wraps, so columns stay
/// aligned.
struct BlockedOptionPreview: View {
    let text: String

    var body: some View {
        ChatTerminalBlock {
            ScrollView(.horizontal) {
                Text(verbatim: Self.shown(text))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .accessibilityIdentifier("chat.blocked-card.preview")
    }

    nonisolated static func shown(_ preview: String) -> String {
        preview.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }
}

/// A file dialog's content: an edit's lines tinted by their `+` or `-`
/// mark, which follows the line number.
private struct BlockedChangeBox: View {
    let lines: [String]
    let marksChanges: Bool

    var body: some View {
        ChatTerminalChangeLines(lines: lines, marks: marksChanges ? .numbered : .none)
    }
}

/// A plan is prose, so it stays on the card's quiet fill rather than the
/// terminal's black.
private struct BlockedPlanBox: View {
    let text: String

    var body: some View {
        ChatMarkdownView(blocks: ChatMarkdown.blocks(from: text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BlockedCardStyle.rowInset)
            .padding(.vertical, 12)
            .background(ThemeVeil.control, in: BlockedCardStyle.shape)
    }
}

/// Grows with its content up to `maxHeight`, then scrolls. A smaller parent
/// proposal, such as the room above a keyboard, also limits the viewport.
/// A flat cut reads as the card's end, so an option cut there would hide
/// the answers past it, a decline too. An edge fades instead while more
/// waits past it, and the scroll indicator flashes once the content
/// overflows, as the card shows or later. Content that fits draws as it is.
struct BlockedScrollingContent<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var hidden = BlockedEdgeFade.Hidden()
    @State private var flashes = 0

    var body: some View {
        let height = min(max(contentHeight, 1), maxHeight)
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(minHeight: 0, idealHeight: height, maxHeight: height)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicatorsFlash(trigger: flashes)
        .modifier(BlockedEdgeFade(hidden: $hidden))
        // On appearing as well as on a change, and a beat later: an overflow
        // read in the commit that inserts the card bumps the trigger before
        // its scroll view can show the bar (live 2026-11-09). A passing
        // overflow, such as the 1 pt first layout's, cancels before it.
        .task(id: hidden.overflows) {
            guard hidden.overflows, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            flashes += 1
        }
    }
}

private struct BlockedEdgeFade: ViewModifier {
    struct Hidden: Equatable {
        var above = false
        var below = false

        var overflows: Bool { above || below }
    }

    @Binding var hidden: Hidden

    func body(content: Content) -> some View {
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
    }

    private func edge(hides: Bool, from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(colors: [.black, .black.opacity(hides ? 0 : 1)], startPoint: start, endPoint: end)
            .frame(height: 24)
    }
}
