import SwiftUI

/// A Blocked Agent's dialog in the Composer's place (ADR 0020): the
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
                    .id(card.dialog.fingerprint)
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
                collapse: { store.isCollapsed = true })
            BlockedScrollingContent(maxHeight: maxHeight) {
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
            // Below the scrolling part, so a field stays in view over the
            // keyboard it raises.
            textEntry
                .disabled(!isReady)
            BlockedCardFooter(
                notice: store.notice, stopTitle: dialog.stopsFromCard ? "Stop" : nil, isReady: isReady,
                stop: { perform(.dismiss) })
        }
    }

    /// Who asked, when a subagent did.
    private var source: String? {
        guard let suffix = dialog.sourceSuffix ?? card.request?.origin, !suffix.isEmpty else { return nil }
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
            // Without the call, the screen's rows, less the question the
            // options answer.
            let plan = card.request?.summary ?? ""
            let shown = dialog.body.filter { !$0.hasPrefix("Claude has written up a plan") }
            BlockedPlanBox(text: plan.isEmpty ? shown.joined(separator: "\n") : plan)
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion:
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
        case .claudeQuestionReview:
            ForEach(Array(subject.reviewAnswers.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pair.question)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: pair.answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .claudeWorkspaceTrust:
            BlockedCodeBox(text: subject.workspacePath ?? "")
            ForEach(Array(dialog.body.filter { $0 != subject.workspacePath }.enumerated()), id: \.offset) {
                BlockedCardText($0.element)
            }
        case .codexAsyncCollapsed:
            BlockedCardText("Codex asked \(dialog.title). Its turn goes on, and the answers go with its next step.")
        case .codexNetwork:
            EmptyView()
        }
    }

    // MARK: Choices

    /// Matches the planner: only Claude asks multi-select questions.
    private var isMultiSelect: Bool {
        dialog.kind == .claudeQuestion && dialog.options.contains { $0.role == .next }
    }

    @ViewBuilder
    private var choices: some View {
        if isMultiSelect {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(dialog.options.filter { $0.role == .answer }, id: \.ordinal) { option in
                    BlockedToggleRow(
                        label: option.label, detail: option.detail, isOn: selection.contains(option.ordinal)
                    ) {
                        selection.formSymmetricDifference([option.ordinal])
                    }
                }
            }
            Button {
                perform(.submitSelection(selection))
            } label: {
                Text(verbatim: dialog.options.first { $0.role == .next }?.label ?? "Next")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(selection.isEmpty)
            ForEach(dialog.options.filter { $0.role == .chat }, id: \.ordinal) { option in
                BlockedOptionButton(option: option, emphasis: .plain) { perform(.choose(ordinal: option.ordinal)) }
            }
        } else {
            let buttons = dialog.options.filter { $0.role != .otherText && $0.role != .next }
            // The first plain way to allow or go on leads. A question's
            // answers stand level, and a choice that saves a rule or
            // switches the mode never leads.
            let lead = buttons.first { [.approve, .trust, .submit].contains($0.role) }?.ordinal
            VStack(spacing: 8) {
                ForEach(buttons, id: \.ordinal) { option in
                    BlockedOptionButton(option: option, emphasis: emphasis(of: option, leads: option.ordinal == lead)) {
                        perform(.choose(ordinal: option.ordinal))
                    }
                }
            }
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
        default:
            EmptyView()
        }
    }

    private func emphasis(of option: DialogOption, leads: Bool) -> BlockedOptionEmphasis {
        switch option.role {
        case .decline, .exitProgram: .destructive
        case .approvePersistent: .caution("Saves a rule, so this isn't asked again.")
        case .approveModeSwitch: .caution("Switches the permission mode.")
        default: leads ? .primary : .plain
        }
    }

    // MARK: Typed answers

    @ViewBuilder
    private var textEntry: some View {
        switch dialog.kind {
        case .claudeBash, .claudeFileEdit, .claudeFileCreate:
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
                    BlockedTextField(placeholder: "Add details", text: $text, isFocused: $isTextFocused)
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
                BlockedTextField(placeholder: "Tell Claude what to do", text: $text, isFocused: $isTextFocused)
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

    private var dialog: BlockedDialog? {
        if case .card(let card) = store.content { return card.dialog }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: dialog?.cardTitle ?? "Waiting for Input")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let dialog, dialog.canStop {
                // Esc quits Claude Code on the trust dialog.
                Button(dialog.kind == .claudeWorkspaceTrust ? "Exit Claude Code" : "Stop", role: .destructive) {
                    Task { await store.perform(.dismiss) }
                }
                .disabled(store.progress != .ready)
            }
            Button("Show") { store.isCollapsed = false }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private extension BlockedDialog {
    var cardTitle: String {
        switch kind {
        case .claudeQuestion, .codexQuestion, .codexAsyncQuestion: "Question"
        case .codexAsyncCollapsed: "Questions"
        default: title.hasSuffix(":") ? String(title.dropLast()) : title
        }
    }

    /// Whether Esc does something a card can name: the planner refuses it
    /// only on Codex's asynchronous question.
    var canStop: Bool { kind != .codexAsyncQuestion }

    /// Whether the open card offers Esc itself: only when no option
    /// already sends it.
    var stopsFromCard: Bool {
        canStop && !options.contains { [.decline, .exitProgram, .cancel].contains($0.role) }
    }
}

// MARK: - Parts

struct BlockedCardHeader: View {
    let title: String
    let detail: String?
    let isActing: Bool
    let collapse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(2)
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
                                .disabled(!isReady)
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
            ForEach(Array(lines.prefix(Self.lineLimit).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(tint(of: line))
            }
            if lines.count > Self.lineLimit {
                Text("\(lines.count - Self.lineLimit) more lines")
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

/// Grows with its content up to `maxHeight`, then scrolls.
struct BlockedScrollingContent<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .scrollBounceBehavior(.basedOnSize)
    }
}
