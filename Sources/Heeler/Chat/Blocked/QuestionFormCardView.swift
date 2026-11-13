import SwiftUI

/// Several questions at once (ADR 0024), answered on the card one at a time
/// and sent together: the store then answers the dialog page by page,
/// checking each page before its keys. Back changes an answer, since
/// nothing has gone to the program yet. On Antigravity CLI, Skip skips the
/// page the card shows and goes out with the answers, since Esc in the
/// terminal would skip the question on screen, the first.
struct QuestionFormCard: View {
    let card: BlockedCard
    let form: QuestionForm
    let store: BlockedCardStore
    let maxHeight: CGFloat
    @State private var draft: QuestionFormDraft
    @FocusState private var isTextFocused: Bool

    init(card: BlockedCard, form: QuestionForm, store: BlockedCardStore, maxHeight: CGFloat) {
        self.card = card
        self.form = form
        self.store = store
        self.maxHeight = maxHeight
        // Options already checked in the terminal stay checked.
        let shown = card.dialog.options.filter { $0.role == .answer }
        let checked = Set(shown.indices.filter { card.dialog.focus.checked.contains(shown[$0].ordinal) })
        _draft = State(initialValue: QuestionFormDraft(form: form, checked: checked))
    }

    private var question: ChatQuestion { draft.question }
    private var page: Int { draft.page }
    private var isReady: Bool { store.progress == .ready }

    private var detail: String {
        draft.isSkipped
            ? String(
                localized: "\(page + 1) of \(form.questions.count), skipped",
                comment: "Question card header: the current question of the total, which is skipped")
            : String(localized: "\(page + 1) of \(form.questions.count)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockedCardHeader(
                title: String(localized: "Question"), detail: detail,
                isActing: store.progress == .acting, collapse: { store.isCollapsed = true })
            BlockedScrollingContent(maxHeight: maxHeight) {
                VStack(alignment: .leading, spacing: 10) {
                    prompt
                    options
                }
                .disabled(!isReady)
            }
            // A page starts at its top.
            .id(page)
            // Below the scrolling part, so the field stays in view over the
            // keyboard it raises.
            controls
                .disabled(!isReady)
            if form.skipsPageByPage {
                BlockedCardFooter(
                    notice: store.notice, stopTitle: card.dialog.stopTitle, isReady: isReady,
                    canStop: isReady && !draft.isSkipped, stop: skip)
            } else {
                BlockedCardFooter(
                    notice: store.notice, stopTitle: card.dialog.stopTitle, isReady: isReady, canStop: store.canStop,
                    stop: stop,
                    asideTitle: chat?.label, aside: chatInstead)
            }
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header = question.header, !header.isEmpty {
                Text(verbatim: header)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: question.text)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var options: some View {
        if question.isMultiSelect {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { @Sendable index, option in
                    MainActorContent {
                        BlockedToggleRow(
                            label: option.label, detail: option.detail, isOn: draft.isChecked(index)
                        ) {
                            draft.toggle(index)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { @Sendable index, option in
                    MainActorContent {
                        BlockedOptionButton(
                            label: option.label, detail: option.detail,
                            emphasis: draft.isChosen(index) ? .primary : .plain
                        ) {
                            choose(index)
                        }
                    }
                }
            }
        }
    }

    /// Claude's `Chat about this`: no answers, a conversation instead. It
    /// stands apart from the options, which it isn't one of.
    private var chat: DialogOption? {
        card.dialog.options.first { $0.role == .chat }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Antigravity CLI's multi-select page takes one too: its
            // `Write-in...` goes with the checks.
            if !question.isMultiSelect || form.writesInWithSelection {
                BlockedTextField(
                    placeholder: String(localized: "Type your own answer"),
                    text: Binding(get: { draft.text }, set: { draft.type($0) }), isFocused: $isTextFocused)
            }
            HStack(spacing: 8) {
                if page > 0 {
                    Button {
                        go(to: page - 1)
                    } label: {
                        Text("Back")
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }
                Button(action: advance) {
                    Text(draft.isLastPage ? "Submit Answers" : "Next")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(draft.isLastPage ? draft.answers == nil : draft.answer(at: page) == nil)
            }
        }
    }

    // MARK: Answers

    /// An option answers a single-select question and moves on, as a digit
    /// does in the terminal; the last page waits for Submit.
    private func choose(_ index: Int) {
        isTextFocused = false
        draft.choose(index)
    }

    private func advance() {
        if draft.isLastPage {
            guard let answers = draft.answers else { return }
            isTextFocused = false
            Task { await store.submit(answers) }
        } else {
            go(to: page + 1)
        }
    }

    private func go(to target: Int) {
        isTextFocused = false
        draft.go(to: target)
    }

    /// Antigravity CLI's Skip: the page the card shows goes out skipped
    /// with the answers (`QuestionFormDraft.skip`).
    private func skip() {
        isTextFocused = false
        draft.skip()
    }

    private func stop() {
        isTextFocused = false
        Task { await store.perform(.dismiss) }
    }

    private func chatInstead() {
        guard let chat else { return }
        isTextFocused = false
        Task { await store.perform(.choose(ordinal: chat.ordinal)) }
    }
}
