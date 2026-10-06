import Foundation

/// One question's answer in a question form, held until every question has
/// one.
enum QuestionFormAnswer: Hashable, Sendable {
    /// One of the question's options, by its index in the call.
    case option(Int)
    /// A multi-select question's options, by index.
    case options(Set<Int>)
    /// An answer the user typed: Claude's `Type something.` row, Codex's
    /// `None of the above` with notes.
    case text(String)
}

/// A dialog asking several questions at once, filled in on the card before
/// any key goes out (ADR 0020). The transcript spells out every question
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

    /// Whether `dialog` is the page asking question `index`, with the
    /// options the call lists.
    func page(_ dialog: BlockedDialog, shows index: Int) -> Bool {
        guard questions.indices.contains(index) else { return false }
        let question = questions[index]
        switch dialog.kind {
        case .claudeQuestion:
            let headers = dialog.subject.questionHeaders
            guard headers.count == questions.count, dialog.progress == headers[index],
                Self.isMultiSelect(dialog) == question.isMultiSelect
            else { return false }
        case .codexQuestion:
            guard dialog.progress == "Question \(index + 1)/\(questions.count)" else { return false }
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
        let isMultiSelect = Self.isMultiSelect(dialog)
        switch answer {
        case .option(let choice) where !isMultiSelect && answers.indices.contains(choice):
            return .choose(ordinal: answers[choice].ordinal)
        case .options(let choices) where isMultiSelect && choices.allSatisfy(answers.indices.contains):
            return .submitSelection(Set(choices.map { answers[$0].ordinal }))
        case .text(let text) where !isMultiSelect:
            if let field = dialog.options.first(where: { $0.role == .otherText }) {
                return .respond(ordinal: field.ordinal, text: text)
            }
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
    /// commas, or the typed text.
    func text(of answer: QuestionFormAnswer, for question: ChatQuestion) -> String {
        let labels = question.options.map(\.label)
        switch answer {
        case .option(let index):
            return labels.indices.contains(index) ? labels[index] : ""
        case .options(let indices):
            return indices.sorted().filter(labels.indices.contains).map { labels[$0] }.joined(separator: ", ")
        case .text(let text):
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Matches the planner: a multi-select page has a `Next` button.
    private static func isMultiSelect(_ dialog: BlockedDialog) -> Bool {
        dialog.options.contains { $0.role == .next }
    }

    /// The comma-separated parts in any order, since Heeler doesn't rely on
    /// the order the review lists checked options in.
    private static func parts(_ text: String) -> [String] {
        text.split(separator: ",").map { DialogRowScanner.comparable(String($0)) }.sorted()
    }
}
