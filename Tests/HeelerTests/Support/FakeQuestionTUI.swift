import Foundation

@testable import Heeler

/// A multi-question ask as Claude Code and Codex draw it, in the captures'
/// colors and layout, reacting to keys and pastes the way the probes saw.
/// It reaches states no capture holds, such as focus on every row, so a
/// question form can be driven page by page.
actor FakeQuestionTUI {
    struct Question: Sendable {
        var header: String
        var text: String
        var options: [String]
        var isMultiSelect = false
    }

    enum State: Equatable, Sendable {
        case asking
        case submitted
        case cancelled
    }

    let program: ChatProgram
    let questions: [Question]
    private let width: Int
    /// Where Claude's review wraps an answer.
    private let reviewWidth: Int
    /// The question on screen; `questions.count` is Claude's review page.
    private(set) var page = 0
    private var focus = 1
    private var checked: [Set<Int>]
    /// Claude: text in a page's `Type something.` row.
    private var typed: [String?]
    /// Codex: the open notes, nil while closed.
    private var notes: String?
    /// What each question was answered with.
    private(set) var answers: [String?]
    private(set) var state: State = .asking
    private(set) var keys: [[String]] = []
    private(set) var pastes: [String] = []
    private var ignoredKeys: Set<String> = []
    private var drawnTexts: [Int: String] = [:]
    private var drawnAnswers: [Int: String] = [:]

    /// `width` matches the captures; the widest footer needs 87 columns.
    init(_ program: ChatProgram, _ questions: [Question], width: Int = 120, reviewWidth: Int? = nil) {
        self.program = program
        self.questions = questions
        self.width = width
        self.reviewWidth = reviewWidth ?? width - 5
        checked = Array(repeating: [], count: questions.count)
        typed = Array(repeating: nil, count: questions.count)
        answers = Array(repeating: nil, count: questions.count)
    }

    /// The program does nothing on `key`.
    func ignore(_ key: String) {
        ignoredKeys.insert(key)
    }

    /// Draws a question with other text than the call's.
    func draw(question index: Int, as text: String) {
        drawnTexts[index] = text
    }

    /// Claude's review page lists another answer for a question.
    func review(question index: Int, as answer: String) {
        drawnAnswers[index] = answer
    }

    func read() -> ANSIScreen {
        ScreenFixture.synthetic(state == .asking ? (program == .claude ? claudeRows() : codexRows()) : doneRows)
    }

    func send(_ keys: [String]) {
        self.keys.append(keys)
        for key in keys where !ignoredKeys.contains(key) && state == .asking {
            switch program {
            case .claude: claudePress(key)
            case .codex: codexPress(key)
            }
        }
    }

    func paste(_ text: String) {
        pastes.append(text)
        guard state == .asking else { return }
        switch program {
        case .claude:
            // Text goes into a focused `Type something.` row.
            guard page < questions.count, !questions[page].isMultiSelect else { return }
            if focus == questions[page].options.count + 1 { typed[page] = (typed[page] ?? "") + text }
        case .codex:
            // A paste on the highlighted option opens its notes.
            notes = (notes ?? "") + text
        }
    }

    private var doneRows: [String] { ["", program == .claude ? "⏺ Thanks." : "• Thanks.", ""] }

    // MARK: Claude

    private func claudePress(_ key: String) {
        guard page < questions.count else {
            switch key {
            case "1": state = .submitted
            case "2", "esc": state = .cancelled
            case "up", "down": focus = focus == 1 ? 2 : 1
            case "enter": state = focus == 1 ? .submitted : .cancelled
            default: break
            }
            return
        }
        let question = questions[page]
        let count = question.options.count
        let other = count + 1
        // Ordinals: the answers, Type something, Next on a multi-select
        // page, Chat about this.
        let next = question.isMultiSelect ? count + 2 : nil
        let chat = question.isMultiSelect ? count + 3 : count + 2
        if focus == other, !question.isMultiSelect, key.count == 1 {
            // A focused field takes characters as text.
            typed[page] = (typed[page] ?? "") + key
            return
        }
        if let number = Int(key), (1...9).contains(number) {
            if number <= count {
                if question.isMultiSelect {
                    checked[page].formSymmetricDifference([number])
                } else {
                    focus = number
                    answer(question.options[number - 1])
                }
            } else if number == other {
                if !question.isMultiSelect, let text = typed[page], !text.isEmpty {
                    answer(text)
                } else {
                    focus = other
                }
            } else if number == count + 2 {
                state = .cancelled
            }
            return
        }
        switch key {
        case "down": focus = min(focus + 1, chat)
        case "up": focus = max(focus - 1, 1)
        case "esc": state = .cancelled
        case "enter":
            if focus == next {
                let labels = checked[page].sorted().map { question.options[$0 - 1] }
                if !labels.isEmpty { answer(labels.joined(separator: ", ")) }
            } else if focus <= count {
                if question.isMultiSelect {
                    checked[page].formSymmetricDifference([focus])
                } else {
                    answer(question.options[focus - 1])
                }
            } else if focus == other, let text = typed[page], !text.isEmpty {
                answer(text)
            } else if focus == chat {
                state = .cancelled
            }
        default:
            break
        }
    }

    private func answer(_ text: String) {
        answers[page] = text
        page += 1
        focus = 1
    }

    private func claudeRows() -> [String] {
        let rule = R.reset + R.inactive + String(repeating: "─", count: width) + R.reset
        var rows = ["", "⏺ Asking.", "", rule, tabBar(), ""]
        guard page < questions.count else { return rows + reviewRows() }
        let question = questions[page]
        let count = question.options.count
        let other = count + 1
        let next = question.isMultiSelect ? count + 2 : nil
        rows += [R.reset + R.bold + R.white + (drawnTexts[page] ?? question.text) + R.reset, ""]
        for (index, label) in question.options.enumerated() {
            let number = index + 1
            let box = box(number, of: question)
            rows.append(Self.optionRow(number, box: box, label: label, isFocused: focus == number))
            let indent = String(repeating: " ", count: question.isMultiSelect ? 9 : 5)
            rows.append(indent + R.reset + R.inactive + label + R.reset)
        }
        rows.append(otherRow(question, number: other))
        if let next {
            rows.append(
                focus == next
                    ? R.reset + R.accent + "❯" + R.reset + "    " + R.reset + R.bold + R.accent + "Next" + R.reset
                    : "     " + R.reset + R.bold + "Next" + R.reset)
        }
        rows += [rule, "  \(count + 2). Chat about this", ""]
        let editHint = focus == other || focus == next ? " · ctrl+g to edit in VS Code" : ""
        rows.append(
            R.reset + R.inactive + "Enter to select · Tab/Arrow keys to navigate" + editHint + " · Esc to cancel"
                + R.reset)
        return rows
    }

    /// A numbered row; focus adds `❯` and the accent.
    private static func optionRow(_ number: Int, box: String, label: String, isFocused: Bool) -> String {
        let numbered = R.reset + R.inactive + "\(number). " + box
        return isFocused
            ? R.reset + R.accent + "❯ " + numbered + R.reset + R.accent + label + R.reset
            : "  " + numbered + label
    }

    private func box(_ number: Int, of question: Question) -> String {
        guard question.isMultiSelect else { return R.reset }
        return checked[page].contains(number) ? R.reset + R.green + "[✔] " + R.reset : R.reset + "[ ] "
    }

    /// `Type something.`: the placeholder, or a field with Claude's
    /// reverse-video cursor while it has focus.
    private func otherRow(_ question: Question, number: Int) -> String {
        let placeholder = question.isMultiSelect ? "Type something" : "Type something."
        let numbered = R.reset + R.inactive + "\(number). " + R.reset + (question.isMultiSelect ? "[ ] " : "")
        if focus == number {
            let field =
                typed[page].map { R.reset + $0 + R.reset + R.reverse + " " + R.reset }
                ?? R.reset + R.reverse + "T" + R.reset + R.dim + String(placeholder.dropFirst()) + R.reset
            return R.reset + R.accent + "❯ " + numbered + field
        }
        if let text = typed[page] { return "  " + numbered + text }
        // An empty single-select row draws its number and placeholder in
        // one run.
        return question.isMultiSelect
            ? "  " + numbered + R.reset + R.inactive + placeholder + R.reset
            : "  " + R.reset + R.inactive + "\(number). " + placeholder + R.reset
    }

    private func tabBar() -> String {
        var row = R.reset + R.inactive + "← " + R.reset
        for (index, question) in questions.enumerated() {
            let mark = answers[index] != nil || !checked[index].isEmpty ? "☒" : "☐"
            row += tab(" \(mark) \(question.header) ", isActive: index == page)
        }
        return row + tab(" ✔ Submit ", isActive: page == questions.count) + " →"
    }

    private func tab(_ text: String, isActive: Bool) -> String {
        isActive ? R.black + R.accentBackground + text + R.reset : text
    }

    private func reviewRows() -> [String] {
        var rows = [R.reset + R.bold + R.white + "Review your answers" + R.reset, " "]
        for (index, question) in questions.enumerated() {
            rows.append(" ● " + question.text)
            let answer = drawnAnswers[index] ?? answers[index] ?? ""
            for (line, text) in Self.wrap("→ " + answer, width: reviewWidth).enumerated() {
                rows.append((line == 0 ? "   " : "     ") + R.reset + R.green + text + R.reset)
            }
        }
        rows += ["", R.reset + R.inactive + "Ready to submit your answers?" + R.reset, ""]
        for (index, label) in ["Submit answers", "Cancel"].enumerated() {
            let ordinal = index + 1
            let marker = ordinal == focus ? R.reset + R.accent + "❯" + R.reset + " " : "  "
            let color = ordinal == focus ? R.accent : ""
            rows.append(marker + R.reset + R.inactive + "\(ordinal). " + R.reset + color + label + R.reset)
        }
        return rows
    }

    /// Words greedily packed into rows `width` wide.
    private static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        return lines + [line]
    }

    // MARK: Codex

    private func codexPress(_ key: String) {
        let question = questions[page]
        let count = question.options.count + 1
        if notes != nil {
            switch key {
            case "enter": codexAnswer(focus)
            case "esc", "tab": notes = nil
            default: if key.count == 1 { notes = (notes ?? "") + key }
            }
            return
        }
        if let number = Int(key), (1...count).contains(number) {
            focus = number
            codexAnswer(number)
            return
        }
        switch key {
        case "down": focus = focus % count + 1
        case "up": focus = (focus + count - 2) % count + 1
        case "enter": codexAnswer(focus)
        case "tab": notes = ""
        case "esc": state = .cancelled
        default: break
        }
    }

    private func codexAnswer(_ number: Int) {
        let question = questions[page]
        let label = number <= question.options.count ? question.options[number - 1] : "None of the above"
        answers[page] = notes.map { "\(label): \($0)" } ?? label
        notes = nil
        if page == questions.count - 1 {
            if !answers.contains(where: { $0 == nil }) { state = .submitted }
        } else {
            page += 1
            focus = 1
        }
    }

    private func codexRows() -> [String] {
        let question = questions[page]
        let unanswered = answers.filter { $0 == nil }.count
        var rows = ["", "• Asking.", "", " "]
        rows.append(
            "  " + R.reset + R.dim + "Question \(page + 1)/\(questions.count) (\(unanswered) unanswered)" + R.reset)
        rows.append("  " + R.reset + R.blue + (drawnTexts[page] ?? question.text) + R.reset)
        rows.append(" ")
        let labels = question.options + ["None of the above"]
        let column = (labels.map(\.count).max() ?? 0) + 2
        for (index, label) in labels.enumerated() {
            let number = index + 1
            let numbered = "\(number). " + label.padding(toLength: column, withPad: " ", startingAt: 0)
            let isOther = index == question.options.count
            let detail = isOther ? "Optionally, add details in notes (tab)" : "Choose \(label.lowercased())."
            // The highlight runs in reverse video to the row's end.
            rows.append(
                number == focus
                    ? "  " + R.reset + R.bold + R.reverse + "› " + numbered + R.reset + R.reverse + detail + R.reset
                        + R.bold + R.reverse + "          " + R.reset
                    : "    " + numbered + R.reset + R.dim + detail + R.reset)
        }
        if let notes {
            rows += [" ", "  " + R.reset + R.bold + "›" + R.reset + " " + notes]
        }
        return rows + ["", codexFooter()]
    }

    private func codexFooter() -> String {
        let submit = page == questions.count - 1 ? "submit all" : "submit answer"
        let bar = R.reset + R.dim + " | "
        if notes != nil {
            return "  " + Self.key("tab") + R.dim + " or " + Self.key("esc") + R.dim + " to clear notes | "
                + Self.key("enter") + " to " + submit
        }
        return "  " + Self.key("tab") + " to add notes" + bar + Self.key("enter") + " to " + submit + bar
            + Self.key("←/→") + " to navigate questions" + bar + Self.key("esc") + " to interrupt"
    }

    private static func key(_ name: String) -> String {
        R.reset + R.bold + name + R.reset
    }

    /// The captures' SGR spellings.
    private enum R {
        static let reset = SGR.reset
        static let bold = SGR.bold
        static let dim = SGR.dim
        static let reverse = SGR.reverse
        static let inactive = SGR.claudeInactive
        static let accent = SGR.claudeAccent
        static let accentBackground = SGR.bg(177, 185, 249)
        static let black = SGR.fg(0, 0, 0)
        static let white = SGR.fg(255, 255, 255)
        static let green = SGR.fg(78, 186, 101)
        static let blue = SGR.fg(99, 168, 248)
    }
}
