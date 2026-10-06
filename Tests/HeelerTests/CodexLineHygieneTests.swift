import Foundation
import Testing

@testable import Heeler

/// Lines Codex itself would skip, repeat or cut short, and the ordinals that
/// decide which line counts (§4 R5, §9).
@Suite("Codex line hygiene")
struct CodexLineHygieneTests {
    private let idle = ChatProjectionContext(activity: .idle)

    @Test("A repeated ordinal keeps its first line")
    func duplicateOrdinal() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        builder.agentMessage("t1", id: "a1", text: "kept")
        builder.nextOrdinal -= 1
        builder.agentMessage("t1", id: "a1", text: "written again")
        builder.turnComplete("t1")

        let projection = builder.reducer().projection(idle)
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/u1", "codex/r1/t1/a1"])
        #expect(projection.transcript.entries.last?.assistant == ChatAssistantMessage(text: "kept"))
        #expect(projection.ordinals == CodexOrdinalDiagnostics(duplicates: 1))
    }

    @Test("A line without an ordinal is skipped")
    func missingOrdinal() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        builder.item(
            "t1", ["type": "AgentMessage", "id": "a0", "content": [["type": "Text", "text": "unordered"]]],
            ordinal: .some(nil))
        builder.agentMessage("t1", id: "a1", text: "ordered")
        builder.turnComplete("t1")

        let projection = builder.reducer().projection(idle)
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/u1", "codex/r1/t1/a1"])
        #expect(projection.ordinals == CodexOrdinalDiagnostics(missing: 1))
    }

    @Test("A gap in the ordinals is counted and skips nothing")
    func ordinalGap() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        builder.nextOrdinal += 3
        builder.agentMessage("t1", id: "a1", text: "after the gap")
        builder.turnComplete("t1")

        let projection = builder.reducer().projection(idle)
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/u1", "codex/r1/t1/a1"])
        #expect(projection.ordinals == CodexOrdinalDiagnostics(gaps: 1))
    }

    @Test("A subagent's inherited history is accepted but not shown")
    func inheritedHistory() {
        // Ordinals 0 to 3: the subagent's header and its parent's turn.
        var builder = CodexRolloutBuilder(subagentHistoryStartOrdinal: 4)
        builder.turnStarted("parent")
        builder.userMessage("parent", id: "p1", text: "parent prompt")
        builder.turnComplete("parent")
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "subagent task")
        builder.turnComplete("t1")

        let projection = builder.reducer().projection(idle)
        #expect(projection.turns.map(\.id) == ["t1"])
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/u1"])
        #expect(projection.ordinals == CodexOrdinalDiagnostics(inherited: 4))
    }

    @Test("A torn line before its rewrite is skipped and gives up its ordinal")
    func crashFragment() throws {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        var torn = builder
        torn.agentMessage("t1", id: "a1", text: "complete answer")
        let whole = try #require(torn.lines.last)
        let cut = try #require(whole.range(of: "complete answer")).lowerBound
        // The writer died inside the text. On reopen Codex ends the fragment
        // with a newline and writes the record again under the same ordinal.
        builder.raw(String(whole[..<cut]) + "comp")
        builder.agentMessage("t1", id: "a1", text: "complete answer")
        builder.turnComplete("t1")

        let projection = builder.reducer().projection(idle)
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/u1", "codex/r1/t1/a1"])
        #expect(projection.transcript.entries.last?.assistant == ChatAssistantMessage(text: "complete answer"))
        #expect(projection.transcript.diagnostics == ChatTranscriptDiagnostics(invalidLines: 1))
        #expect(projection.ordinals == CodexOrdinalDiagnostics())
    }

    @Test("Unknown records, items, phases and inputs never stop the transcript")
    func unknowns() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.record("future_record", ["detail": 1])
        builder.event("future_event", [("turn_id", "t1")])
        builder.item("t1", ["type": "FutureItem", "id": "f1"])
        builder.item(
            "t1",
            [
                "type": "UserMessage", "id": "u1",
                "content": [["type": "text", "text": "look", "text_elements": []], ["type": "future_input", "blob": "x"]],
            ])
        builder.agentMessage("t1", id: "a1", text: "partial", phase: "partial_answer")
        builder.agentMessage("t1", id: "a2", text: "final", phase: "future_phase")
        builder.item("t1", ["type": "Extension", "id": "e1", "kind": "future.kind"])
        builder.turnAborted("t1", reason: "future_reason")

        let projection = builder.reducer().projection(idle)
        let entries = projection.transcript.entries
        #expect(
            entries.map(\.id.rawValue) == [
                "codex/r1/t1/u1", "codex/r1/t1/a1", "codex/r1/t1/a2", "codex/r1/t1/~stopped",
            ])
        #expect(
            entries.map(\.content) == [
                .user(ChatUserMessage(text: "look", attachmentLabels: ["Attachment"])),
                .assistant(ChatAssistantMessage(text: "partial")),
                .assistant(ChatAssistantMessage(text: "final")),
                .notice(ChatNotice(kind: .stopped, title: "Stopped")),
            ])
        #expect(projection.turns.map(\.status) == [.interrupted])
        #expect(
            projection.transcript.diagnostics
                == ChatTranscriptDiagnostics(unknownRecordTypes: [
                    "future_record", "event_msg/future_event", "item_completed/FutureItem",
                    "item_completed/Extension/future.kind",
                ]))
        // A newer writer numbered the three lines this reader cannot parse.
        #expect(projection.ordinals == CodexOrdinalDiagnostics(gaps: 1))
    }

    @Test("A 3 MiB command line is titled from its prefix and changes nothing else")
    func hugeLine() throws {
        let output = String(repeating: "y\n", count: 1_572_864)
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "print a lot")
        builder.command("t1", id: "c1", argv: ["bash", "-lc", "yes | head -n 1572864"], output: output)
        builder.agentMessage("t1", id: "a1", text: "done")
        builder.turnComplete("t1")
        let commandLine = builder.chatLines[3]
        #expect(commandLine.length > 3 * 1_024 * 1_024)

        var framer = JSONLLineFramer(startOffset: 0, lineCap: 1_024 * 1_024, prefixCap: 16 * 1_024)
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        var largestHeld = 0
        for chunk in ChatFixture.chunks(builder.data, size: 512 * 1_024) {
            let lines = framer.append(chunk)
            largestHeld = max(largestHeld, lines.map(\.data.count).max() ?? 0)
            reducer.append(lines)
        }
        #expect(largestHeld == 16 * 1_024)

        // The prefix keeps the argv and status but not the exit code, which
        // follows the output.
        let cut = reducer.transcript(idle)
        let row = ChatToolActivity(
            kind: .command, name: "CommandExecution", title: "yes | head -n 1572864", status: .succeeded,
            callID: "c1", output: ChatOutputReference(offset: commandLine.offset, length: commandLine.length))
        #expect(cut.entries.map(\.id.rawValue) == ["codex/r1/t1/u1", "codex/r1/t1/c1", "codex/r1/t1/a1"])
        #expect(cut.entries[1].tool == row)
        #expect(cut.diagnostics == ChatTranscriptDiagnostics())

        let whole = builder.reducer().transcript(idle)
        var complete = row
        complete.exitCode = 0
        complete.preview = ChatToolPreview(capping: output)
        #expect(whole.entries[1].tool == complete)
        #expect(whole.entries.filter { $0.tool == nil } == cut.entries.filter { $0.tool == nil })
    }

    @Test("A message cut to its prefix is counted and skipped")
    func oversizedMessage() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: String(repeating: "a", count: 40_000))
        builder.agentMessage("t1", id: "a1", text: "short")
        builder.turnComplete("t1")

        var reducer = CodexRolloutReducer(rolloutID: "r1")
        reducer.append(JSONLLineFramer.lines(in: builder.data, lineCap: 32 * 1_024, prefixCap: 16 * 1_024))
        let projection = reducer.projection(idle)
        #expect(projection.transcript.entries.map(\.id.rawValue) == ["codex/r1/t1/a1"])
        #expect(projection.transcript.diagnostics == ChatTranscriptDiagnostics(oversizedLines: 1))
        #expect(projection.ordinals == CodexOrdinalDiagnostics())
    }
}
