import Foundation
import Testing

@testable import Heeler

/// `/compact` turns (docs/research/codex-rollout-format.md, "Compaction
/// command") and reverted rollouts that continue a base file ("Revert").
@Suite("Codex compaction and revert lineage")
struct CodexLineageTests {
    private let idle = ChatProjectionContext(activity: .idle)

    @Test("A /compact turn shows only its divider and settles the pending send")
    func compactTurn() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        builder.agentMessage("t1", id: "a1", text: "hi")
        builder.turnComplete("t1")
        let cursor = CodexEchoCursor(rolloutID: "r1", offset: UInt64(builder.endOffset))
        // The record order `compact()` writes.
        builder.turnStarted("t2")
        builder.compacted(message: "")
        builder.record("world_state", ["cwd": "/work"])
        builder.record("turn_context", ["cwd": "/work", "model": "gpt-5.5"])
        builder.event("thread_settings_applied", [("thread_id", "thread-1")])
        builder.compaction("t2", id: "c1")
        builder.turnComplete("t2")

        let projection = builder.reducer().projection(idle)
        #expect(projection.turns.map(\.id) == ["t1", "t2"])
        #expect(projection.turns.map(\.status) == [.completed, .completed])
        let compaction = projection.entries(inTurn: 1)
        #expect(compaction.map(\.id.rawValue) == ["codex/r1/t2/c1"])
        #expect(compaction.map(\.content) == [.divider(ChatDivider(kind: .compaction))])
        #expect(projection.transcript.diagnostics == ChatTranscriptDiagnostics())
        #expect(projection.ordinals == CodexOrdinalDiagnostics())

        // The prompt sent before the cursor is not this turn's echo.
        let pending = [
            CodexPendingSend(text: "/compact ", cursor: cursor), CodexPendingSend(text: "hello ", cursor: cursor),
        ]
        #expect(
            CodexPendingEcho.match(pending: pending, candidates: projection.echoCandidates) == [
                ChatEntryID("codex/r1/t2/c1"), nil,
            ])
    }

    @Test("A reverted rollout continues its base up to the boundary")
    func revertLineage() throws {
        let baseLines = Self.base().chatLines
        let boundary = baseLines[9].offset
        var reducer = Self.child(baseID: "base1", endOrdinal: 9, endOffset: boundary).reducer(rolloutID: "child1")
        #expect(
            reducer.pendingHistoryBase
                == CodexHistoryBase(baseRolloutID: "base1", endOrdinalExclusive: 9, endByteOffset: boundary))
        let alone = reducer.transcript(idle)
        #expect(alone.needsOlderHistory)
        #expect(alone.entries.map(\.id.rawValue) == ["codex/child1/t4/u4", "codex/child1/t4/a4"])

        reducer.setBaseSegment(rolloutID: "base1", path: "/sessions/base1.jsonl", lines: baseLines)
        #expect(reducer.pendingHistoryBase == nil)
        let projection = reducer.projection(idle)
        #expect(projection.turns.map(\.id) == ["t1", "t2", "t4"])
        #expect(projection.turns.map(\.status) == [.completed, .completed, .completed])
        #expect(
            projection.transcript.entries.map(\.id.rawValue) == [
                "codex/base1/t1/u1", "codex/base1/t1/a1", "codex/base1/t2/u2", "codex/base1/t2/c2",
                "codex/child1/t4/u4", "codex/child1/t4/a4",
            ])
        #expect(!projection.transcript.needsOlderHistory)
        #expect(projection.ordinals == CodexOrdinalDiagnostics())

        // A base row's output is re-read from the base file.
        let command = try #require(projection.transcript.entries[3].tool)
        #expect(
            command.output
                == ChatOutputReference(
                    path: "/sessions/base1.jsonl", offset: baseLines[7].offset, length: baseLines[7].length))
        // Only the live rollout's prompts can be the echo of a send.
        #expect(projection.transcript.recordedPrompts.map(\.text) == ["after the revert"])
    }

    @Test("Base history stays hidden until the window reaches the live file's head")
    func baseHiddenInTailWindow() {
        let baseLines = Self.base().chatLines
        var reducer = Self.child(baseID: "base1", endOrdinal: 9, endOffset: baseLines[9].offset)
            .reducer(rolloutID: "child1")
        reducer.setBaseSegment(rolloutID: "base1", path: "/sessions/base1.jsonl", lines: baseLines)

        let tail = reducer.transcript(ChatProjectionContext(windowStart: 100, activity: .idle))
        #expect(tail.entries.map(\.id.rawValue) == ["codex/child1/t4/u4", "codex/child1/t4/a4"])
        #expect(tail.needsOlderHistory)
    }

    @Test("Each base names its own base until the chain ends")
    func lineageChain() {
        var base0 = CodexRolloutBuilder()
        base0.turnStarted("t1")
        base0.userMessage("t1", id: "u1", text: "one")
        base0.turnComplete("t1")
        base0.turnStarted("t2")
        base0.userMessage("t2", id: "u2", text: "undone by base1")
        let base0Lines = base0.chatLines

        var base1 = CodexRolloutBuilder(
            historyBase: (rolloutID: "base0", endOrdinal: 4, endOffset: Int(base0Lines[4].offset)), firstOrdinal: 4)
        base1.turnStarted("t3")
        base1.userMessage("t3", id: "u3", text: "three")
        base1.turnComplete("t3")
        base1.turnStarted("t4")
        base1.userMessage("t4", id: "u4", text: "undone by the child")
        let base1Lines = base1.chatLines

        var child = CodexRolloutBuilder(
            historyBase: (rolloutID: "base1", endOrdinal: 8, endOffset: Int(base1Lines[4].offset)), firstOrdinal: 8)
        child.turnStarted("t5")
        child.userMessage("t5", id: "u5", text: "five")
        child.turnComplete("t5")

        var reducer = child.reducer(rolloutID: "child1")
        reducer.setBaseSegment(rolloutID: "base1", path: "/sessions/base1.jsonl", lines: base1Lines)
        #expect(reducer.pendingHistoryBase?.baseRolloutID == "base0")
        #expect(reducer.transcript(idle).needsOlderHistory)

        reducer.setBaseSegment(rolloutID: "base0", path: "/sessions/base0.jsonl", lines: base0Lines)
        #expect(reducer.pendingHistoryBase == nil)
        let transcript = reducer.transcript(idle)
        #expect(
            transcript.entries.map(\.id.rawValue) == [
                "codex/base0/t1/u1", "codex/base1/t3/u3", "codex/child1/t5/u5",
            ])
        #expect(!transcript.needsOlderHistory)
    }

    @Test("A base that cannot continue the history shows it as unavailable", arguments: CodexBrokenLineage.allCases)
    func brokenLineage(_ broken: CodexBrokenLineage) {
        let baseLines = Self.base().chatLines
        let boundary = baseLines[9].offset
        var baseID = "base1"
        var endOrdinal = 9
        var endOffset = boundary
        var supplied = baseLines
        switch broken {
        case .baseMissing:
            supplied = []
        case .baseShorter:
            supplied = Array(baseLines[..<6])
        case .boundaryInsideLine:
            endOffset = boundary + 5
        case .ordinalMismatch:
            endOrdinal = 8
        case .legacyBase:
            var legacy = CodexRolloutBuilder(.legacy)
            legacy.legacyUser("first")
            legacy.legacyAgent("one")
            supplied = legacy.chatLines
            endOffset = UInt64(legacy.endOffset)
        case .selfReference:
            baseID = "child1"
        }
        var reducer = Self.child(baseID: baseID, endOrdinal: endOrdinal, endOffset: endOffset)
            .reducer(rolloutID: "child1")
        reducer.setBaseSegment(rolloutID: baseID, path: "/sessions/\(baseID).jsonl", lines: supplied)

        let transcript = reducer.transcript(idle)
        #expect(reducer.pendingHistoryBase == nil)
        #expect(!transcript.needsOlderHistory)
        #expect(
            transcript.entries.map(\.id.rawValue) == [
                "codex/child1/~history-unavailable", "codex/child1/t4/u4", "codex/child1/t4/a4",
            ])
        #expect(transcript.entries.first?.divider == ChatDivider(kind: .historyUnavailable))
    }

    /// A rollout whose third turn (ordinals 9 on) a revert dropped.
    private static func base() -> CodexRolloutBuilder {
        var base = CodexRolloutBuilder()
        base.turnStarted("t1")  // 1
        base.userMessage("t1", id: "u1", text: "first")  // 2
        base.agentMessage("t1", id: "a1", text: "one")  // 3
        base.turnComplete("t1")  // 4
        base.turnStarted("t2")  // 5
        base.userMessage("t2", id: "u2", text: "second")  // 6
        base.command("t2", id: "c2", argv: ["ls"])  // 7
        base.turnComplete("t2")  // 8
        base.turnStarted("t3")  // 9
        base.userMessage("t3", id: "u3", text: "reverted")  // 10
        base.turnComplete("t3")  // 11
        return base
    }

    /// The rollout the revert started: its header takes the first ordinal
    /// the base gave up.
    private static func child(baseID: String, endOrdinal: Int, endOffset: UInt64) -> CodexRolloutBuilder {
        var child = CodexRolloutBuilder(
            historyBase: (rolloutID: baseID, endOrdinal: endOrdinal, endOffset: Int(endOffset)),
            firstOrdinal: UInt64(endOrdinal))
        child.turnStarted("t4")
        child.userMessage("t4", id: "u4", text: "after the revert")
        child.agentMessage("t4", id: "a4", text: "four")
        child.turnComplete("t4")
        return child
    }
}

/// Ways a revert's base fails to continue the history.
enum CodexBrokenLineage: CaseIterable, CustomTestStringConvertible {
    case baseMissing
    case baseShorter
    case boundaryInsideLine
    case ordinalMismatch
    case legacyBase
    case selfReference

    var testDescription: String {
        switch self {
        case .baseMissing: "base file gone"
        case .baseShorter: "base ends before the boundary"
        case .boundaryInsideLine: "boundary inside a line"
        case .ordinalMismatch: "last ordinal is not end - 1"
        case .legacyBase: "base is a legacy rollout"
        case .selfReference: "base names the rollout itself"
        }
    }
}
