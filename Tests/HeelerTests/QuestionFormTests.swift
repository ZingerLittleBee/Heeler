import Foundation
import Testing

@testable import Heeler

/// Several questions filled in on the card, then answered page by page:
/// which cards get a form, the action each page takes, and the drive
/// against a drawn program, which stops wherever a page isn't the one
/// expected.
@MainActor
@Suite("Question form", .timeLimit(.minutes(1)))
struct QuestionFormTests {
    // MARK: Which cards

    @Test func theFirstPageOfAnAskTheTranscriptSpellsOutGetsAForm() throws {
        let form = try #require(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", Self.claudeRequest)))
        #expect(form.questions.map(\.text) == ["Which colors?", "Which size?"])
        #expect(QuestionForm(card: try Self.card("codex-04-x3-q1", Self.codexRequest)) != nil)
    }

    @Test func otherPagesAndAsksKeepTheCardTheyShow() throws {
        // A later page goes on as the screen shows it.
        #expect(QuestionForm(card: try Self.card("claude-11-c4-q2", Self.claudeRequest)) == nil)
        #expect(QuestionForm(card: try Self.card("codex-05-x3-q2", Self.codexRequest)) == nil)
        let colors = try Self.dialog("claude-08-c4-auq-q1")
        #expect(QuestionForm(card: BlockedCard(dialog: colors, request: nil)) == nil)

        var single = Self.claudeRequest
        single.questions.removeLast()
        #expect(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", single)) == nil)
        var otherOptions = Self.claudeRequest
        otherOptions.questions[0].options = ["Red", "Green", "Purple"]
        #expect(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", otherOptions)) == nil)
        var singleSelect = Self.claudeRequest
        singleSelect.questions[0].isMultiSelect = false
        #expect(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", singleSelect)) == nil)
    }

    // MARK: Actions

    @Test func eachAnswerBecomesTheActionItsPageTakes() throws {
        let form = try #require(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", Self.claudeRequest)))
        let colors = try Self.dialog("claude-08-c4-auq-q1")
        #expect(try form.action(.options([0, 2]), forQuestion: 0, on: colors) == .submitSelection([1, 3]))
        #expect(throws: DialogPlanError.self) { try form.action(.option(0), forQuestion: 0, on: colors) }
        #expect(throws: DialogPlanError.self) { try form.action(.text("Teal"), forQuestion: 0, on: colors) }

        let size = try Self.dialog("claude-11-c4-q2")
        #expect(try form.action(.option(1), forQuestion: 1, on: size) == .choose(ordinal: 2))
        #expect(try form.action(.text("Medium"), forQuestion: 1, on: size) == .respond(ordinal: 3, text: "Medium"))
        // A page answers only its own question.
        #expect(throws: DialogPlanError.self) { try form.action(.option(1), forQuestion: 0, on: size) }

        let codex = try #require(QuestionForm(card: try Self.card("codex-04-x3-q1", Self.codexRequest)))
        let color = try Self.dialog("codex-04-x3-q1")
        #expect(try codex.action(.option(1), forQuestion: 0, on: color) == .choose(ordinal: 2))
        #expect(
            try codex.action(.text("Medium please"), forQuestion: 1, on: try Self.dialog("codex-05-x3-q2"))
                == .respond(ordinal: 3, text: "Medium please"))
    }

    @Test func theReviewMustListTheAnswersGiven() throws {
        let form = try #require(QuestionForm(card: try Self.card("claude-08-c4-auq-q1", Self.claudeRequest)))
        let review = try Self.dialog("claude-14-c4-review")
        #expect(form.review(review, shows: [.options([0, 2]), .text("Medium")]))
        #expect(!form.review(review, shows: [.options([0]), .text("Medium")]))
        #expect(!form.review(review, shows: [.options([0, 2]), .option(0)]))
        #expect(!form.review(try Self.dialog("claude-11-c4-q2"), shows: [.options([0, 2]), .text("Medium")]))
    }

    // MARK: The drawn program

    @Test func theDrawnProgramReadsLikeTheCaptures() async throws {
        for (stem, program, questions) in [
            ("claude-08-c4-auq-q1", ChatProgram.claude, Self.claudeQuestions),
            ("codex-04-x3-q1", .codex, Self.codexQuestions),
        ] {
            let screen = await FakeQuestionTUI(program, questions).read()
            let drawn = try #require(BlockedDialogParser.parse(screen, program: program).dialog)
            let captured = try Self.dialog(stem)
            #expect(drawn.kind == captured.kind)
            #expect(drawn.title == captured.title)
            #expect(drawn.progress == captured.progress)
            #expect(drawn.subject.questionHeaders == captured.subject.questionHeaders)
            #expect(drawn.options.map(\.label) == captured.options.map(\.label))
            #expect(drawn.options.map(\.role) == captured.options.map(\.role))
            #expect(drawn.options.map(\.number) == captured.options.map(\.number))
            #expect(drawn.focus == captured.focus)
        }
    }

    // MARK: Driving

    @Test func claudeGetsEveryPageAnsweredThenItsReviewSubmitted() async throws {
        let tui = FakeQuestionTUI(.claude, Self.claudeQuestions)
        let store = try await Self.store(tui, request: Self.claudeRequest)

        await store.submit([.options([0, 2]), .text("Medium")])

        let colors = [["1"], ["3"], ["down"], ["down"], ["down"], ["down"], ["enter"]]
        #expect(await tui.keys == colors + [["3"], ["enter"], ["1"]])
        #expect(await tui.pastes == ["Medium"])
        #expect(await tui.answers == ["Red, Blue", "Medium"])
        #expect(await tui.state == .submitted)
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.content == .none)
    }

    @Test func codexSubmitsEveryAnswerWithTheLast() async throws {
        let tui = FakeQuestionTUI(.codex, Self.codexQuestions)
        let store = try await Self.store(tui, request: Self.codexRequest)

        await store.submit([.option(1), .text("Medium please")])

        #expect(await tui.keys == [["2"], ["down"], ["down"], ["enter"]])
        #expect(await tui.pastes == ["Medium please"])
        #expect(await tui.answers == ["Green", "None of the above: Medium please"])
        #expect(await tui.state == .submitted)
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    @Test func aPageAskingSomethingElseStopsBeforeItsKeys() async throws {
        let tui = FakeQuestionTUI(.claude, Self.claudeQuestions)
        await tui.draw(question: 1, as: "Which shape?")
        let store = try await Self.store(tui, request: Self.claudeRequest)

        await store.submit([.options([0, 2]), .option(0)])

        #expect(await tui.keys == [["1"], ["3"], ["down"], ["down"], ["down"], ["down"], ["enter"]])
        #expect(await tui.state == .asking)
        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered[1] == "Small")
        #expect(store.notice == "Question 2 on screen isn't the one the card showed. Finish here or in the terminal.")
        #expect(store.progress == .ready)
    }

    @Test func aKeyTheProgramIgnoresStopsTheAnswersThere() async throws {
        let tui = FakeQuestionTUI(.claude, Self.claudeQuestions)
        await tui.ignore("enter")
        let store = try await Self.store(tui, request: Self.claudeRequest)

        await store.submit([.options([0]), .option(1)])

        #expect(await tui.keys == [["1"], ["down"], ["down"], ["down"], ["down"], ["enter"]])
        guard case .generic = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(store.notice?.hasPrefix("Heeler stopped at question 1:") == true)
    }

    @Test func aReviewListingOtherAnswersIsNeverSubmitted() async throws {
        let tui = FakeQuestionTUI(.claude, Self.claudeQuestions)
        await tui.review(question: 1, as: "Large")
        let store = try await Self.store(tui, request: Self.claudeRequest)

        await store.submit([.options([0, 2]), .option(0)])

        #expect(await tui.keys.last == ["1"])
        #expect(await tui.keys.count == 8)
        #expect(await tui.state == .asking)
        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered == [1: "Submit answers", 2: "Cancel"])
        #expect(store.notice?.hasPrefix("Claude's review lists other answers") == true)
    }

    @Test func textTheDialogWontTakeSendsNothing() async throws {
        let tui = FakeQuestionTUI(.claude, Self.claudeQuestions)
        let store = try await Self.store(tui, request: Self.claudeRequest)

        await store.submit([.options([0]), .text("Medium\nplease")])

        #expect(await tui.keys.isEmpty)
        #expect(store.notice == DialogPlanError.multilineText.message)
        #expect(store.progress == .ready)
    }

    // MARK: Helpers

    static let claudeQuestions = [
        FakeQuestionTUI.Question(
            header: "Colors", text: "Which colors?", options: ["Red", "Green", "Blue"], isMultiSelect: true),
        FakeQuestionTUI.Question(header: "Size", text: "Which size?", options: ["Small", "Large"]),
    ]

    static let codexQuestions = [
        FakeQuestionTUI.Question(header: "Color", text: "Pick a color", options: ["Red", "Green"]),
        FakeQuestionTUI.Question(header: "Size", text: "Pick a size", options: ["Small", "Large"]),
    ]

    static let claudeRequest = ChatPendingRequest(
        entryID: ChatEntryID("tool:toolu_q"), callID: "toolu_q", kind: .question, toolName: "AskUserQuestion",
        summary: "Which colors?\nWhich size?",
        questions: claudeQuestions.map {
            ChatQuestion(
                header: $0.header, text: $0.text, options: $0.options.map { ChatQuestion.Option(label: $0) },
                isMultiSelect: $0.isMultiSelect)
        })

    static let codexRequest = ChatPendingRequest(
        entryID: ChatEntryID("call_q"), callID: "call_q", kind: .question, toolName: "request_user_input",
        summary: "Pick a color\nPick a size",
        questions: codexQuestions.map {
            ChatQuestion(header: $0.header, text: $0.text, options: $0.options.map { ChatQuestion.Option(label: $0) })
        })

    private static func dialog(_ stem: String) throws -> BlockedDialog {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private static func card(_ stem: String, _ request: ChatPendingRequest) throws -> BlockedCard {
        BlockedCard(dialog: try dialog(stem), request: request)
    }

    /// A store showing the drawn program's first page as a form.
    private static func store(_ tui: FakeQuestionTUI, request: ChatPendingRequest) async throws -> BlockedCardStore {
        let store = BlockedCardStore(
            program: tui.program,
            io: BlockedScreenIO(
                readScreen: { await tui.read() },
                sendKeys: { await tui.send($0) },
                paste: { await tui.paste($0) }),
            clock: ManualClock().clock)
        store.update(transcript: ChatTranscript(entries: [], pendingRequests: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return store
        }
        _ = try #require(QuestionForm(card: card))
        return store
    }
}
