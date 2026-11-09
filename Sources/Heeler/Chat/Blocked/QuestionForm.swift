import Foundation

/// One question's answer in a question form, held until every question has
/// one.
enum QuestionFormAnswer: Hashable, Sendable {
    /// One of the question's options, by its index in the call.
    case option(Int)
    /// A multi-select question's options, by index, and what was written
    /// with them where the form takes that (`QuestionForm.writesInWithSelection`).
    case options(Set<Int>, text: String? = nil)
    /// An answer the user typed: Claude's `Type something.` row, Codex's
    /// `None of the above` with notes, Antigravity CLI's `Write-in...`.
    case text(String)
    /// No answer: Antigravity CLI's Esc skips the question on screen and
    /// turns the page, so a skip goes out in its page's turn, as an answer
    /// does (`QuestionForm.skipsPageByPage`).
    case skipped

    /// What the user typed, which goes into one of the program's fields.
    var typedText: String? {
        switch self {
        case .options(_, let text): text
        case .text(let text): text
        case .option, .skipped: nil
        }
    }
}

/// A dialog asking several questions at once, filled in on the card before
/// any key goes out (ADR 0024). The transcript spells out every question
/// while the screen shows one page at a time, so each page is checked
/// against its question before it is answered, and Claude's review page
/// against the answers before they are submitted.
struct QuestionForm: Equatable, Sendable {
    let program: ChatProgram
    let questions: [ChatQuestion]

    /// The form for a card on the first page of an ask the transcript shows
    /// in full. A single question, or any later page, is answered as the
    /// card shows it.
    init?(card: BlockedCard) {
        guard let request = card.request, request.questions.count > 1,
            request.questions.allSatisfy({ !$0.options.isEmpty })
        else { return nil }
        self.init(program: card.dialog.program, questions: request.questions)
        guard page(card.dialog, shows: 0) else { return nil }
    }

    private init(program: ChatProgram, questions: [ChatQuestion]) {
        self.program = program
        self.questions = questions
    }

    /// Whether a page can be skipped on its own. Antigravity CLI's Esc
    /// skips only the question on screen, which is the form's first until
    /// the answers go out, so a skip is held with the answers and sent on
    /// its own page. Claude Code's and Codex's Esc ends the whole ask, so
    /// their form's Stop acts at once.
    var skipsPageByPage: Bool { program == .agy }

    /// Whether a multi-select page takes a written answer with its checks:
    /// Enter in Antigravity CLI's `Write-in...` field submits both. Claude
    /// Code's Other row on such a page stays in the terminal.
    var writesInWithSelection: Bool { program == .agy }

    /// Whether `dialog` is the page asking question `index`, with the
    /// options the call lists.
    func page(_ dialog: BlockedDialog, shows index: Int) -> Bool {
        guard questions.indices.contains(index) else { return false }
        let question = questions[index]
        switch dialog.kind {
        case .claudeQuestion:
            let headers = dialog.subject.questionHeaders
            guard headers.count == questions.count, dialog.progress == headers[index],
                dialog.isMultiSelect == question.isMultiSelect
            else { return false }
        case .codexQuestion:
            guard dialog.progress == "Question \(index + 1)/\(questions.count)" else { return false }
        case .agyQuestion:
            guard dialog.progress == "Question \(index + 1)/\(questions.count)",
                dialog.isMultiSelect == question.isMultiSelect
            else { return false }
        default:
            return false
        }
        let shown = dialog.options.filter { $0.role == .answer }.map { DialogRowScanner.comparable($0.label) }
        return DialogRowScanner.comparable(dialog.subject.question ?? dialog.title)
            == DialogRowScanner.comparable(question.text)
            && shown == question.options.map { DialogRowScanner.comparable($0.label) }
    }

    /// What gives `answer` on `dialog`, the page for question `index`.
    func action(
        _ answer: QuestionFormAnswer, forQuestion index: Int, on dialog: BlockedDialog
    ) throws(DialogPlanError) -> DialogAction {
        guard page(dialog, shows: index) else {
            throw .unsupported("Question \(index + 1) on screen isn't the one the card showed.")
        }
        let answers = dialog.options.filter { $0.role == .answer }
        let isMultiSelect = dialog.isMultiSelect
        switch answer {
        case .option(let choice) where !isMultiSelect && answers.indices.contains(choice):
            return .choose(ordinal: answers[choice].ordinal)
        case .options(let choices, let text) where isMultiSelect && choices.allSatisfy(answers.indices.contains):
            return .submitSelection(Set(choices.map { answers[$0].ordinal }), text: text)
        case .text(let text) where !isMultiSelect:
            if let field = dialog.options.first(where: { $0.role == .otherText }) {
                return .respond(ordinal: field.ordinal, text: text)
            }
        case .skipped where skipsPageByPage:
            return .skipQuestion
        default:
            break
        }
        throw .unsupported("Question \(index + 1) doesn't take that answer.")
    }

    /// Whether Claude's review page lists exactly `answers`.
    func review(_ dialog: BlockedDialog, shows answers: [QuestionFormAnswer]) -> Bool {
        let shown = dialog.subject.reviewAnswers
        guard dialog.kind == .claudeQuestionReview, shown.count == questions.count, answers.count == questions.count
        else { return false }
        return questions.indices.allSatisfy { index in
            DialogRowScanner.comparable(shown[index].question) == DialogRowScanner.comparable(questions[index].text)
                && Self.parts(shown[index].answer) == Self.parts(text(of: answers[index], for: questions[index]))
        }
    }

    /// The answer as the review page words it: option labels joined by
    /// commas, any written answer last, or the typed text.
    func text(of answer: QuestionFormAnswer, for question: ChatQuestion) -> String {
        let labels = question.options.map(\.label)
        switch answer {
        case .option(let index):
            return labels.indices.contains(index) ? labels[index] : ""
        case .options(let indices, let text):
            let written = text.map { [$0.trimmingCharacters(in: .whitespaces)] } ?? []
            return (indices.sorted().filter(labels.indices.contains).map { labels[$0] } + written)
                .joined(separator: ", ")
        case .text(let text):
            return text.trimmingCharacters(in: .whitespaces)
        case .skipped:
            return ""
        }
    }

    /// The comma-separated parts in any order, since Heeler doesn't rely on
    /// the order the review lists checked options in.
    private static func parts(_ text: String) -> [String] {
        text.split(separator: ",").map { DialogRowScanner.comparable(String($0)) }.sorted()
    }
}

/// A question form's answers while the card holds them, and the page it
/// shows. Turning a page sends nothing: the screen stays on the first
/// question whichever page the card shows, so nothing here acts on the
/// screen before the answers go out together.
struct QuestionFormDraft: Equatable {
    let form: QuestionForm
    private(set) var page = 0
    /// A single-select question's option, by question.
    private(set) var choices: [Int?]
    /// A multi-select question's checked options, by question.
    private(set) var selections: [Set<Int>]
    /// A typed answer, by question. It wins over a chosen option, and goes
    /// with a multi-select question's checks where the form takes that.
    private(set) var texts: [String]
    /// The questions skipped, where a page can be (`QuestionForm.skipsPageByPage`).
    private(set) var skipped: Set<Int> = []

    /// - Parameter checked: The first question's options already checked
    ///   in the terminal, which stay checked.
    init(form: QuestionForm, checked: Set<Int> = []) {
        self.form = form
        let count = form.questions.count
        choices = Array(repeating: nil, count: count)
        selections = [checked] + Array(repeating: [], count: max(0, count - 1))
        texts = Array(repeating: "", count: count)
    }

    var question: ChatQuestion { form.questions[page] }
    var isLastPage: Bool { page == form.questions.count - 1 }
    var isSkipped: Bool { skipped.contains(page) }

    /// Every question's answer, nil while one has none.
    var answers: [QuestionFormAnswer]? {
        let answers = form.questions.indices.compactMap(answer(at:))
        return answers.count == form.questions.count ? answers : nil
    }

    func answer(at index: Int) -> QuestionFormAnswer? {
        let text = texts[index].trimmingCharacters(in: .whitespaces)
        if form.questions[index].isMultiSelect {
            let written = form.writesInWithSelection && !text.isEmpty ? text : nil
            if !selections[index].isEmpty || written != nil { return .options(selections[index], text: written) }
        } else {
            if !text.isEmpty { return .text(text) }
            if let choice = choices[index] { return .option(choice) }
        }
        return skipped.contains(index) ? .skipped : nil
    }

    func isChosen(_ option: Int) -> Bool {
        choices[page] == option && texts[page].trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isChecked(_ option: Int) -> Bool { selections[page].contains(option) }

    var text: String { texts[page] }

    /// An option answers a single-select question and moves on, as a digit
    /// does in the terminal; the last page waits for Submit.
    mutating func choose(_ option: Int) {
        choices[page] = option
        texts[page] = ""
        skipped.remove(page)
        if !isLastPage { page += 1 }
    }

    mutating func toggle(_ option: Int) {
        selections[page].formSymmetricDifference([option])
        if !selections[page].isEmpty { skipped.remove(page) }
    }

    mutating func type(_ text: String) {
        texts[page] = text
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { skipped.remove(page) }
    }

    /// Skips the page shown, not the one on screen, and moves on as a
    /// chosen option does; the last page waits for Submit. The store sends
    /// the skip as that page's key, in its turn.
    mutating func skip() {
        guard form.skipsPageByPage else { return }
        choices[page] = nil
        selections[page] = []
        texts[page] = ""
        skipped.insert(page)
        if !isLastPage { page += 1 }
    }

    mutating func go(to target: Int) {
        guard form.questions.indices.contains(target) else { return }
        page = target
    }
}
