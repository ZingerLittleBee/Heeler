import Foundation

/// A turn's state as far as the loaded lines tell.
enum CodexTurnStatus: String, Equatable, Sendable, Codable {
    case inProgress
    case completed
    case failed
    case interrupted
}

/// A sync `request_user_input` call with whatever answered it.
struct CodexQuestionState: Equatable, Sendable {
    var callID: String
    var questions: [ChatQuestion]
    /// An output arrived without answers: Codex closed the question.
    var isClosed: Bool

    var isAnswered: Bool { questions.contains { $0.answer != nil } }
}

/// What the lines say about one sync question call so far. The call, the
/// accepted answers and the tool output are separate lines, and any of them
/// may fall outside the loaded window.
struct CodexQuestionBuild: Equatable, Sendable {
    var questions: [CodexSyncQuestion] = []
    /// `verified_answer`: the answers Codex accepted, keyed by question text.
    var verified: [CodexVerifiedAnswer.Answer]?
    /// The tool output's answers by question id.
    var outputAnswers: [String: String]?
    var hasOutput = false

    /// The questions with their answers. A verified answer wins over the
    /// output's; its question text is the call's, sometimes followed by the
    /// chosen option's description on later lines.
    func state(callID: String) -> CodexQuestionState {
        var questions = questions.map { question in
            let verified = verified?.first { answer in
                answer.question == question.text || answer.question.hasPrefix(question.text + "\n")
            }
            return ChatQuestion(
                id: question.id, header: question.header, text: Self.firstLine(question.text),
                options: question.options,
                answer: verified?.answer ?? question.id.flatMap { outputAnswers?[$0] })
        }
        if questions.isEmpty, let verified {
            questions = verified.map { ChatQuestion(text: Self.firstLine($0.question), answer: $0.answer) }
        }
        let answered = questions.contains { $0.answer != nil }
        return CodexQuestionState(callID: callID, questions: questions, isClosed: hasOutput && !answered)
    }

    private static func firstLine(_ text: String) -> String {
        String(text.prefix { $0 != "\n" && $0 != "\r\n" })
    }
}

/// An entry before display rules: user messages, open calls and questions
/// still depend on the projection context.
struct CodexTimelineEntry: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case item(CodexItem.Content)
        case question(CodexQuestionState)
        case stopped(CodexAbortReason, error: String?)
        case failed(String?)
        case divider(ChatDivider)
    }

    var id: ChatEntryID
    var sourceOffset: UInt64
    /// The Codex item id, which async question ids are built from.
    var itemID: String?
    /// The rollout whose line placed the entry. Only the live rollout's
    /// prompts are offered to pending-echo matching.
    var rolloutID: String
    /// The file that line is in, or nil for the live rollout.
    var path: String?
    var content: Content
}

/// One turn with its entries in display order.
struct CodexTimelineTurn: Equatable, Sendable {
    var id: String
    /// Nil when no loaded line says (a tail window that has not reached the
    /// turn's end, or an implicit legacy turn still open at the end).
    var status: CodexTurnStatus?
    var entries: [CodexTimelineEntry]
    /// The Stopped or failure row that ends the turn.
    var ending: CodexTimelineEntry?
    /// On the Host's clock, from the turn's own events.
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    /// False when the turn started above the loaded lines, so its first
    /// loaded row is not where it began.
    var opensInWindow = true
}

/// Everything a projection needs, before display rules.
struct CodexTimeline: Equatable, Sendable {
    /// Rows above the first turn: a divider where older history is missing.
    var leading: [CodexTimelineEntry] = []
    var turns: [CodexTimelineTurn] = []
}

/// A turn as tests and diagnostics see it.
struct CodexTurnSummary: Equatable, Sendable {
    var id: String
    var status: CodexTurnStatus?
    var entryIDs: [ChatEntryID]
}

/// Applies the projection context to a timeline: open calls resolve against
/// herdr's activity, replies fill the questions they answer, and skills read
/// as commands.
enum CodexTimelineProjector {
    struct Output: Equatable, Sendable {
        var entries: [ChatEntry] = []
        var pendingRequests: [ChatPendingRequest] = []
        var recordedPrompts: [ChatRecordedPrompt] = []
        var turns: [CodexTurnSummary] = []
        var chatTurns: [ChatTurn] = []
        var precedingTurnEnd: ChatTurnEnd?
        var echoCandidates: [CodexEchoCandidate] = []
    }

    static func project(
        _ timeline: CodexTimeline, context: ChatProjectionContext, liveRolloutID: String
    ) -> Output {
        let answers = Answers(timeline)
        var output = Output()
        for entry in timeline.leading {
            output.entries.append(
                project(
                    entry, wasQueued: false, open: .noResult, answers: answers, context: context,
                    liveRolloutID: liveRolloutID, output: &output))
        }
        // Only the newest turn can still be running: Codex runs one turn at
        // a time, so an older turn left open was cut off.
        let liveTurn = timeline.turns.indices.last.flatMap { index in
            let status = timeline.turns[index].status
            return status == nil || status == .inProgress ? index : nil
        }
        for (index, turn) in timeline.turns.enumerated() {
            let open = openStatus(turn, isLive: index == liveTurn, activity: context.activity)
            var entryIDs: [ChatEntryID] = []
            for (position, entry) in turn.entries.enumerated() {
                let chatEntry = project(
                    entry, wasQueued: position > 0, open: open, answers: answers, context: context,
                    liveRolloutID: liveRolloutID, output: &output)
                output.entries.append(chatEntry)
                entryIDs.append(chatEntry.id)
            }
            if let ending = turn.ending {
                let chatEntry = project(
                    ending, wasQueued: false, open: open, answers: answers, context: context,
                    liveRolloutID: liveRolloutID, output: &output)
                output.entries.append(chatEntry)
                entryIDs.append(chatEntry.id)
            }
            output.turns.append(CodexTurnSummary(id: turn.id, status: turn.status, entryIDs: entryIDs))
            let ending: ChatTurn.Ending? =
                switch turn.status {
                case .completed: .completed
                case .interrupted: .interrupted
                case .failed: .failed
                case .inProgress, nil: nil
                }
            if index == 0, !turn.opensInWindow {
                // A turn the window opens inside is the one the rows above
                // it began; only its end is news.
                output.precedingTurnEnd = ending.map { ChatTurnEnd(ending: $0, endedAt: turn.endedAt) }
            } else if let first = entryIDs.first {
                output.chatTurns.append(
                    ChatTurn(firstEntryID: first, startedAt: turn.startedAt, endedAt: turn.endedAt, ending: ending))
            }
        }
        return output
    }

    /// What a call without a recorded outcome shows
    /// (docs/research/codex-rollout-format.md, "Paginated turns"): the newest
    /// open turn follows herdr's activity; any other open turn was cut off.
    private static func openStatus(
        _ turn: CodexTimelineTurn, isLive: Bool, activity: ChatAgentActivity
    ) -> ChatToolActivity.Status {
        switch turn.status {
        case .interrupted:
            return .interrupted
        case .completed, .failed:
            return .noResult
        case .inProgress, nil:
            guard isLive else { return turn.status == .inProgress ? .interrupted : .noResult }
            switch activity {
            case .working: return .running
            case .blocked: return .awaitingApproval
            case .idle, .unknown: return .noResult
            }
        }
    }

    private static func project(
        _ entry: CodexTimelineEntry, wasQueued: Bool, open: ChatToolActivity.Status, answers: Answers,
        context: ChatProjectionContext, liveRolloutID: String, output: inout Output
    ) -> ChatEntry {
        let isLive = entry.rolloutID == liveRolloutID
        let content: ChatEntry.Content
        switch entry.content {
        case .item(.user(let user)):
            switch CodexMessageFormatter.display(user, skillNames: context.skillNames, wasQueued: wasQueued) {
            case .reply(let replies):
                content = .notice(
                    ChatNotice(
                        kind: .answered, title: "Answered",
                        questions: replies.map {
                            ChatQuestion(id: $0.questionItemID, text: $0.question, answer: $0.answer)
                        }))
            case .message(let message):
                content = .user(message)
                if isLive {
                    output.recordedPrompts.append(
                        ChatRecordedPrompt(offset: entry.sourceOffset, text: user.text, entryID: entry.id))
                    output.echoCandidates.append(
                        CodexEchoCandidate(
                            rolloutID: entry.rolloutID, offset: entry.sourceOffset, entryID: entry.id,
                            kind: .prompt(text: user.text, localImagePaths: user.localImagePaths)))
                }
            }
        case .item(.agent(let agent)):
            guard !agent.questions.isEmpty else {
                content = .assistant(ChatAssistantMessage(text: agent.text))
                break
            }
            var unanswered: [ChatQuestion] = []
            let questions = agent.questions.enumerated().map { index, question in
                let id = entry.itemID.map { CodexMessageFormatter.asyncQuestionID(itemID: $0, index: index) }
                let reply = answers.reply(questionID: id, itemID: entry.itemID, title: question.title)
                let chatQuestion = ChatQuestion(
                    id: id, text: question.title, options: question.options.map { ChatQuestion.Option(label: $0) },
                    answer: reply?.answer)
                if reply == nil {
                    unanswered.append(chatQuestion)
                }
                return chatQuestion
            }
            content = .questions(ChatQuestionSet(questions: questions))
            // A set without an id cannot be answered from Chat, so it never
            // feeds the question card.
            if let itemID = entry.itemID, let first = unanswered.first {
                output.pendingRequests.append(
                    ChatPendingRequest(
                        entryID: entry.id, callID: itemID, kind: .question, toolName: "request_user_input_async",
                        summary: first.text, questions: unanswered))
            }
        case .item(.reasoning(let text, let duration)):
            content = .reasoning(ChatReasoning(text: text, durationMilliseconds: duration))
        case .item(.plan(let text)):
            content = .plan(ChatPlan(text: text, status: .succeeded))
        case .item(.compaction):
            content = .divider(ChatDivider(kind: .compaction))
            if isLive {
                output.echoCandidates.append(
                    CodexEchoCandidate(
                        rolloutID: entry.rolloutID, offset: entry.sourceOffset, entryID: entry.id, kind: .compaction))
            }
        case .item(.hook(let text)):
            content = .notice(ChatNotice(kind: .hook, title: "Hook", detail: text.isEmpty ? nil : text))
        case .item(.review(let title, let detail)):
            content = .notice(ChatNotice(kind: .review, title: title, detail: detail))
        case .item(.tool(let snapshot)):
            let status = snapshot.status ?? open
            var reference = snapshot.output
            if entry.path != nil {
                reference?.path = entry.path
            }
            content = .tool(
                ChatToolActivity(
                    kind: snapshot.kind, name: snapshot.name, title: snapshot.title, subtitle: snapshot.subtitle,
                    status: status, note: snapshot.note, diff: snapshot.diff, exitCode: snapshot.exitCode,
                    callID: snapshot.callID, preview: snapshot.preview, output: reference))
            if status == .running || status == .awaitingApproval {
                output.pendingRequests.append(
                    ChatPendingRequest(
                        entryID: entry.id, callID: snapshot.callID, kind: snapshot.kind, toolName: snapshot.name,
                        summary: snapshot.title, detail: snapshot.subtitle))
            }
        case .question(let state):
            var status = open
            var note: String?
            if state.isAnswered {
                status = .succeeded
            } else if state.isClosed {
                status = .notCompleted
                note = "Question closed"
            }
            let title = state.questions.first?.text ?? "Question"
            content = .tool(
                ChatToolActivity(
                    kind: .question, name: "request_user_input", title: title, status: status, note: note,
                    questions: state.questions, callID: state.callID))
            if status == .running || status == .awaitingApproval {
                output.pendingRequests.append(
                    ChatPendingRequest(
                        entryID: entry.id, callID: state.callID, kind: .question, toolName: "request_user_input",
                        summary: title, questions: state.questions))
            }
        case .stopped(let reason, let error):
            content = .notice(
                ChatNotice(
                    kind: .stopped, title: reason == .budgetLimited ? "Stopped (budget)" : "Stopped", detail: error))
        case .failed(let message):
            content = .notice(ChatNotice(kind: .error, title: "Turn failed", detail: message))
        case .divider(let divider):
            content = .divider(divider)
        }
        return ChatEntry(id: entry.id, sourceOffset: entry.sourceOffset, content: content)
    }

    /// Answers from async-question replies. Current clients name each
    /// question by its JSON id. Older desktop clients name the whole message,
    /// which settles every question in it (`resolve_answers`); the answer
    /// shown is the one whose question text matches, if any.
    private struct Answers {
        struct Reply {
            var answer: String?
        }

        private var byQuestionID: [String: String] = [:]
        private var byItemID: [String: [CodexMessageFormatter.QuestionReply]] = [:]

        init(_ timeline: CodexTimeline) {
            for turn in timeline.turns {
                for entry in turn.entries {
                    guard case .item(.user(let user)) = entry.content,
                        let replies = CodexMessageFormatter.questionReplies(in: user.text)
                    else { continue }
                    for reply in replies {
                        if reply.questionItemID.hasPrefix("[") {
                            byQuestionID[reply.questionItemID] = byQuestionID[reply.questionItemID] ?? reply.answer
                        } else {
                            byItemID[reply.questionItemID, default: []].append(reply)
                        }
                    }
                }
            }
        }

        /// The reply that settles a question, or nil while it is open.
        func reply(questionID: String?, itemID: String?, title: String) -> Reply? {
            if let questionID, let answer = byQuestionID[questionID] {
                return Reply(answer: answer)
            }
            guard let itemID, let replies = byItemID[itemID] else { return nil }
            return Reply(answer: replies.first { $0.question == title }?.answer)
        }
    }
}
