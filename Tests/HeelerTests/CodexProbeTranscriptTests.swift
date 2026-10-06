import Foundation
import Testing

@testable import Heeler

/// The two captured probe rollouts, projected whole. Line numbers follow the
/// brief (P1, P2; 1-based).
@Suite("Codex probe transcripts")
struct CodexProbeTranscriptTests {
    private let idle = ChatProjectionContext(activity: .idle)

    @Test("P2 has six turns with their prompts, replies and statuses")
    func probe2Transcript() throws {
        let probe = try CodexProbe.probe2()
        #expect(probe.lines.count == 119)
        let reducer = probe.reducer()
        #expect(reducer.support == .supported(.paginated))
        let projection = reducer.projection(idle)

        #expect(
            projection.turns.map(\.id) == [
                "01a10fc8-3970-7ef3-85cb-61cfa2ca0cbb", "01a10fc8-be92-79f2-a957-4a455c620f60",
                "01a10fc9-48f1-7242-8e79-fb06b99075c5", "01a10fca-f0cb-7e91-a335-5495e8e3a03d",
                "01a10fcb-f797-7e61-89d7-8c11ae401735", "01a10fce-5e5d-7482-badd-42af70f04607",
            ])
        #expect(
            projection.turns.map(\.status) == [
                .completed, .interrupted, .completed, .completed, .interrupted, .completed,
            ])
        let entries = projection.transcript.entries
        #expect(entries.filter { $0.user != nil }.map(\.sourceOffset) == [10, 27, 44, 61, 93, 106].map(probe.offset))
        #expect(
            entries.filter { $0.assistant != nil }.map(\.sourceOffset)
                == [11, 18, 28, 62, 94, 107, 115].map(probe.offset))
        #expect(entries.first?.user?.text == "Run the shell command: touch x1.txt in the current directory")
        #expect(entries.first?.id.rawValue == "codex/\(CodexProbe.probe2ID)/01a10fc8-3970-7ef3-85cb-61cfa2ca0cbb/01a10fc8-4092-7433-8d50-24d4941fb6a7")
        #expect(
            projection.transcript.recordedPrompts.map(\.offset) == [10, 27, 44, 61, 93, 106].map(probe.offset))
        #expect(projection.transcript.diagnostics == ChatTranscriptDiagnostics())
        #expect(projection.ordinals == CodexOrdinalDiagnostics())
        #expect(!projection.transcript.needsOlderHistory)
    }

    @Test("Response-item twins never render")
    func twinsNeverRender() throws {
        let probe = try CodexProbe.probe2()
        let offsets = Set(probe.reducer().transcript(idle).entries.map(\.sourceOffset))
        for number in [9, 12, 19, 26, 60, 77, 85] {
            #expect(!offsets.contains(probe.offset(number)), "P2:L\(number) rendered")
        }
    }

    @Test("A file change that completes after the abort stays in its turn")
    func lateItemStaysInTurn() throws {
        let probe = try CodexProbe.probe2()
        let turn = probe.reducer().projection(idle).entries(inTurn: 1)

        #expect(turn.map(\.sourceOffset) == [27, 28, 36, 35].map(probe.offset))
        let patch = try #require(turn[2].tool)
        #expect(patch.kind == .fileWrite)
        #expect(patch.name == "FileChange")
        #expect(patch.title == "patch.txt")
        #expect(patch.status == .failed)
        #expect(patch.diff == ChatDiffStats(added: 1, removed: 0))
        #expect(patch.preview == ChatToolPreview(text: "execution error: TurnAborted", isTruncated: false))
        #expect(patch.output == ChatOutputReference(offset: probe.offset(36), length: probe.line(36).length))
        #expect(turn[3].notice == ChatNotice(kind: .stopped, title: "Stopped"))
        #expect(turn[3].id.rawValue == "codex/\(CodexProbe.probe2ID)/01a10fc8-be92-79f2-a957-4a455c620f60/~stopped")
    }

    @Test("Empty final answers are skipped")
    func emptyFinalSkipped() throws {
        let probe = try CodexProbe.probe2()
        let entries = probe.reducer().transcript(idle).entries
        let offsets = Set(entries.map(\.sourceOffset))
        #expect(!offsets.contains(probe.offset(50)))
        #expect(!offsets.contains(probe.offset(84)))
        #expect(!entries.contains { $0.assistant?.text.isEmpty == true })
    }

    @Test("A sync question shows its verified answers", arguments: CodexQuestionSource.allCases)
    func syncAnswered(source: CodexQuestionSource) throws {
        let probe = try CodexProbe.probe2()
        let lines = source == .verifiedAnswer ? probe.lines : probe.lines.filter { $0 != probe.line(47) }
        let projection = probe.reducer(lines).projection(idle)
        let turn = projection.entries(inTurn: 2)

        #expect(turn.map(\.sourceOffset) == [44, 45].map(probe.offset))
        #expect(
            turn[1].tool
                == ChatToolActivity(
                    kind: .question, name: "request_user_input", title: "Pick a color", status: .succeeded,
                    questions: [
                        ChatQuestion(
                            id: "color", header: "Color", text: "Pick a color",
                            options: [
                                .init(label: "Red", detail: "Choose red."),
                                .init(label: "Green", detail: "Choose green."),
                            ],
                            answer: "Red"),
                        ChatQuestion(
                            id: "size", header: "Size", text: "Pick a size",
                            options: [
                                .init(label: "Small", detail: "Choose small."),
                                .init(label: "Large", detail: "Choose large."),
                            ],
                            answer: "None of the above\nuser_note: Medium please"),
                    ], callID: "call_H7ieHhHMR8EkXwMKqGbHpnSB"))
        #expect(projection.transcript.pendingRequests.allSatisfy { $0.toolName != "request_user_input" })
    }

    @Test("An async question takes its answer from a later reply")
    func asyncQuestion() throws {
        let probe = try CodexProbe.probe2()
        let projection = probe.reducer().projection(idle)
        let turn = projection.entries(inTurn: 3)
        let fruitID = #"["request_user_input_async","call_OXMaHSs1BtzjPdK2walFl4Zv",0]"#
        let drinkID = #"["request_user_input_async","call_OXMaHSs1BtzjPdK2walFl4Zv",1]"#
        let drink = ChatQuestion(id: drinkID, text: "Pick a drink", options: ["Tea", "Coffee"])

        #expect(turn.map(\.sourceOffset) == [61, 62, 65, 78, 81].map(probe.offset))
        #expect(
            turn[2].questionSet
                == ChatQuestionSet(questions: [
                    ChatQuestion(id: fruitID, text: "Pick a fruit", options: ["Apple", "Banana"], answer: "Apple"),
                    drink,
                ]))
        #expect(
            turn[3].notice
                == ChatNotice(
                    kind: .answered, title: "Answered",
                    questions: [ChatQuestion(id: fruitID, text: "Pick a fruit", answer: "Apple")]))
        #expect(
            projection.transcript.pendingRequests == [
                ChatPendingRequest(
                    entryID: turn[2].id, callID: "call_OXMaHSs1BtzjPdK2walFl4Zv", kind: .question,
                    toolName: "request_user_input_async", summary: "Pick a drink", questions: [drink])
            ])
        #expect(!projection.transcript.recordedPrompts.contains { $0.offset == probe.offset(78) })
    }

    @Test("Parallel commands from one cell are separate rows; the cell is not a row")
    func parallelCommands() throws {
        let probe = try CodexProbe.probe2()
        let turn = probe.reducer().projection(idle).entries(inTurn: 5)

        #expect(turn.map(\.sourceOffset) == [106, 107, 111, 112, 115].map(probe.offset))
        #expect(turn.compactMap(\.tool).map(\.title) == ["touch par-c.txt", "touch par-d.txt"])
        #expect(turn.compactMap(\.tool).map(\.status) == [.succeeded, .succeeded])
        #expect(turn.compactMap(\.tool).map(\.exitCode) == [0, 0])
    }

    @Test("An aborted cell leaves no command row, only Stopped")
    func abortedCellNoRow() throws {
        let probe = try CodexProbe.probe2()
        let turn = probe.reducer().projection(idle).entries(inTurn: 4)

        #expect(turn.map(\.sourceOffset) == [93, 94, 101].map(probe.offset))
        #expect(turn.allSatisfy { $0.tool == nil })
        #expect(turn.last?.notice == ChatNotice(kind: .stopped, title: "Stopped"))
    }

    @Test("P1 places a late command in its turn and answers its question")
    func probe1() throws {
        let probe = try CodexProbe.probe1()
        #expect(probe.lines.count == 65)
        let projection = probe.reducer().projection(idle)

        #expect(projection.turns.map(\.status) == [.completed, .interrupted, .completed])
        let first = projection.entries(inTurn: 0)
        #expect(first.map(\.sourceOffset) == [10, 11, 21, 26].map(probe.offset))
        #expect(first.compactMap(\.tool).map(\.title) == ["touch heeler-probe.txt"])

        let question = try #require(projection.entries(inTurn: 2).compactMap(\.tool).first)
        #expect(question.title == "请选择 A 或 B。")
        #expect(question.status == .succeeded)
        #expect(
            question.questions == [
                ChatQuestion(
                    id: "pick_a_or_b", header: "选择", text: "请选择 A 或 B。",
                    options: [.init(label: "A", detail: "选择 A。"), .init(label: "B", detail: "选择 B。")], answer: "B")
            ])
        #expect(projection.transcript.pendingRequests.isEmpty)
    }
}

/// Which line answers P2's sync question.
enum CodexQuestionSource: CaseIterable, CustomTestStringConvertible {
    case verifiedAnswer
    case toolOutputOnly

    var testDescription: String {
        switch self {
        case .verifiedAnswer: "verified answer (L47)"
        case .toolOutputOnly: "tool output only (L47 removed)"
        }
    }
}
