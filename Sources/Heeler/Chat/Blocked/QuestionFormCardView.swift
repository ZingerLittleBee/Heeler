import SwiftUI

/// Several questions at once (ADR 0020), answered on the card one at a time
/// and sent together: the store then answers the dialog page by page,
/// checking each page before its keys. Back changes an answer, since
/// nothing has gone to the program yet.
struct QuestionFormCard: View {
    let card: BlockedCard
    let form: QuestionForm
    let store: BlockedCardStore
    let maxHeight: CGFloat
    @State private var page = 0
    /// A single-select question's option, by question.
    @State private var choices: [Int?]
    /// A multi-select question's checked options, by question.
    @State private var selections: [Set<Int>]
    /// A typed answer, by question. It wins over a chosen option.
    @State private var texts: [String]
    @FocusState private var isTextFocused: Bool

    init(card: BlockedCard, form: QuestionForm, store: BlockedCardStore, maxHeight: CGFloat) {
        self.card = card
        self.form = form
        self.store = store
        self.maxHeight = maxHeight
        let count = form.questions.count
        // Options already checked in the terminal stay checked.
        let shown = card.dialog.options.filter { $0.role == .answer }
        let checked = Set(shown.indices.filter { card.dialog.focus.checked.contains(shown[$0].ordinal) })
        _choices = State(initialValue: Array(repeating: nil, count: count))
        _selections = State(initialValue: [checked] + Array(repeating: [], count: count - 1))
        _texts = State(initialValue: Array(repeating: "", count: count))
    }

    private var question: ChatQuestion { form.questions[page] }
    private var isLastPage: Bool { page == form.questions.count - 1 }
    private var isReady: Bool { store.progress == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockedCardHeader(
                title: "Question", detail: "\(page + 1) of \(form.questions.count)",
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
            BlockedCardFooter(
                notice: store.notice, stopTitle: "Stop", isReady: isReady, stop: stop, asideTitle: chat?.label,
                aside: chatInstead)
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
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    BlockedToggleRow(
                        label: option.label, detail: option.detail, isOn: selections[page].contains(index)
                    ) {
                        selections[page].formSymmetricDifference([index])
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    BlockedOptionButton(
                        label: option.label, detail: option.detail, emphasis: isChosen(index) ? .primary : .plain
                    ) {
                        choose(index)
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
            if !question.isMultiSelect {
                BlockedTextField(placeholder: "Type your own answer", text: $texts[page], isFocused: $isTextFocused)
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
                    Text(isLastPage ? "Submit Answers" : "Next")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(isLastPage ? answers == nil : answer(at: page) == nil)
            }
        }
    }

    // MARK: Answers

    /// Every question's answer, nil while one has none.
    private var answers: [QuestionFormAnswer]? {
        let answers = form.questions.indices.compactMap(answer(at:))
        return answers.count == form.questions.count ? answers : nil
    }

    private func answer(at index: Int) -> QuestionFormAnswer? {
        if form.questions[index].isMultiSelect {
            return selections[index].isEmpty ? nil : .options(selections[index])
        }
        let text = texts[index].trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return .text(text) }
        return choices[index].map(QuestionFormAnswer.option)
    }

    private func isChosen(_ index: Int) -> Bool {
        choices[page] == index && texts[page].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// An option answers a single-select question and moves on, as a digit
    /// does in the terminal; the last page waits for Submit.
    private func choose(_ index: Int) {
        choices[page] = index
        texts[page] = ""
        if isLastPage {
            isTextFocused = false
        } else {
            go(to: page + 1)
        }
    }

    private func advance() {
        if isLastPage {
            guard let answers else { return }
            isTextFocused = false
            Task { await store.submit(answers) }
        } else {
            go(to: page + 1)
        }
    }

    private func go(to target: Int) {
        isTextFocused = false
        page = target
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
