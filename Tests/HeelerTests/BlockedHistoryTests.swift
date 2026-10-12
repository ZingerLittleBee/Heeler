import Foundation
import Testing

@testable import Heeler

/// Answers given on Blocked cards, marked on the timeline only where the
/// transcript agrees with them.
@Suite("Blocked history")
struct BlockedHistoryTests {
    @Test func anAllowedCallIsMarkedOnceItRuns() {
        var history = BlockedHistory()
        history.record(.allowed, forCall: "toolu_1")

        #expect(Self.answer(history, status: .succeeded) == .allowed)
        #expect(Self.answer(history, status: .failed) == .allowed)
        // Still waiting, or declined after all: the transcript says otherwise.
        #expect(Self.answer(history, status: .awaitingApproval) == nil)
        #expect(Self.answer(history, status: .declined) == nil)
    }

    @Test func aStoppedCallIsMarkedWhereTheTranscriptSaysDeclined() {
        var history = BlockedHistory()
        history.record(.stopped, forCall: "toolu_1")

        #expect(Self.answer(history, status: .declined) == .stopped)
        #expect(Self.answer(history, status: .interrupted) == .stopped)
        #expect(Self.answer(history, status: .succeeded) == nil)
    }

    @Test func otherCallsAreLeftAlone() {
        var history = BlockedHistory()
        history.record(.allowed, forCall: "toolu_other")

        #expect(Self.answer(history, status: .succeeded) == nil)
    }

    @Test func aQueuedAnswerShowsUntilTheTranscriptRecordsOne() {
        var history = BlockedHistory()
        history.queue("Apple", forQuestion: "item-1:0")
        history.queue("Tea", forQuestion: "item-1:1")
        let entry = ChatEntry(
            id: ChatEntryID("item-1"), sourceOffset: 0,
            content: .questions(
                ChatQuestionSet(questions: [
                    ChatQuestion(id: "item-1:0", text: "Pick a fruit"),
                    ChatQuestion(id: "item-1:1", text: "Pick a drink", answer: "Coffee"),
                ])))

        guard case .questions(let set) = history.marking([entry]).first?.content else {
            Issue.record("Expected the question set")
            return
        }
        #expect(set.questions.map(\.queuedAnswer) == ["Apple", nil])
        #expect(set.questions.map(\.answer) == [nil, "Coffee"])
    }

    @Test func noHistoryLeavesTheEntriesAsTheyAre() {
        let entries = [Self.tool(status: .succeeded)]
        #expect(BlockedHistory().marking(entries) == entries)
    }

    private static func answer(
        _ history: BlockedHistory, status: ChatToolActivity.Status
    ) -> ChatToolActivity.CardAnswer? {
        guard case .tool(let tool) = history.marking([tool(status: status)]).first?.content else { return nil }
        return tool.cardAnswer
    }

    private static func tool(status: ChatToolActivity.Status) -> ChatEntry {
        ChatEntry(
            id: ChatEntryID("tool:toolu_1"), sourceOffset: 0,
            content: .tool(
                ChatToolActivity(
                    kind: .command, name: "Bash", title: "touch c1.txt", status: status, callID: "toolu_1")))
    }
}
