import Foundation
import Testing

@testable import Heeler

/// Hand-written transcripts in the compact JSON Claude Code writes, one
/// record per line.
enum ClaudeSample {
    static func lines(_ jsonl: String, lineCap: Int = 8 * 1_024 * 1_024, prefixCap: Int = 16 * 1_024) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data((jsonl + "\n").utf8), lineCap: lineCap, prefixCap: prefixCap)
    }

    static func reducer(_ lines: [ChatLine], role: ClaudeTranscriptReducer.Role = .main) -> ClaudeTranscriptReducer {
        var reducer = ClaudeTranscriptReducer(role: role)
        reducer.append(lines)
        return reducer
    }

    static func transcript(
        _ jsonl: String, activity: ChatAgentActivity = .idle, role: ClaudeTranscriptReducer.Role = .main
    ) -> ChatTranscript {
        reducer(lines(jsonl), role: role).transcript(ChatProjectionContext(activity: activity))
    }

    static func entry(_ id: String, in transcript: ChatTranscript) -> ChatEntry.Content? {
        transcript.entries.first { $0.id.rawValue == id }?.content
    }
}

@Suite("Claude chain resolver")
struct ClaudeChainResolverTests {
    private static let probe = "claude/probe2-transcript.jsonl"

    private static func chain(
        _ lines: [ChatLine], role: ClaudeTranscriptReducer.Role = .main, windowStart: UInt64 = 0
    ) -> ClaudeChain {
        ClaudeSample.reducer(lines, role: role).chain(ChatProjectionContext(windowStart: windowStart))
    }

    @Test("The leaf is the newest message, not the record last-prompt names (M L139)")
    func leafIgnoresLastPrompt() throws {
        let chain = Self.chain(try ChatFixture.lines(Self.probe))
        #expect(chain.leafUUID == "fb1b2513-838c-477a-bf91-3660ff9e7d84")
        #expect(chain.terminalUUID == "8ff90fe4-dc7c-4146-b4f2-66759889e25d")
        #expect(chain.leafUUID != "5d5575cf-c088-46e5-93bb-59521370f5a1")
        #expect(chain.missingParent == nil)
    }

    @Test("All 119 records are selected in file order, dead-end results L85 and L162 included")
    func selectedSet() throws {
        let chain = Self.chain(try ChatFixture.lines(Self.probe))
        #expect(chain.records.count == 119)
        #expect(zip(chain.records, chain.records.dropFirst()).allSatisfy { $0.byteOffset < $1.byteOffset })
        let selected = Set(chain.records.map(\.uuid))
        #expect(selected.contains("b8824044-ee11-4063-ba63-bacb461e7a14"))
        #expect(selected.contains("4a0d5156-cd70-49c1-a8d0-568d5bb8de7d"))
        let offsets = Dictionary(uniqueKeysWithValues: chain.records.map { ($0.uuid, $0.byteOffset) })
        for record in chain.records {
            guard let parent = record.parentUUID else { continue }
            #expect((offsets[parent] ?? .max) < record.byteOffset, "parent of \(record.uuid)")
        }
    }

    @Test("A tail window from L97 reports L96 as missing; prepending L1-L96 converges")
    func windowNeedsOlder() throws {
        let lines = try ChatFixture.lines(Self.probe)
        var reducer = ClaudeSample.reducer(lines.filter { $0.offset >= 58245 })
        let window = reducer.chain(ChatProjectionContext(windowStart: 58245))
        #expect(window.missingParent == "bad3c1b6-dd8f-409c-aa1d-1dbe1c2fb1fa")
        #expect(window.records.first?.uuid == "d26638ad-4d4a-4f14-aaa1-9efe8d823dfd")
        #expect(window.leafUUID == "fb1b2513-838c-477a-bf91-3660ff9e7d84")

        reducer.prepend(lines.filter { $0.offset < 58245 })
        #expect(reducer.chain(ChatProjectionContext()) == Self.chain(lines))
    }

    @Test("A block can hang off the result of the block before it (M L74-L77)")
    func streamingParent() throws {
        let chain = Self.chain(try ChatFixture.lines(Self.probe))
        let records = chain.records.filter { (35529...40140).contains($0.byteOffset) }
        #expect(records.map(\.uuid) == [
            "e063b5ab-112b-4c43-9b72-2bf7a8df5810", "2791fe96-4b8f-4838-9796-2265181ea0bf",
            "f23f4598-cc00-41bc-8972-df41f9bea745", "19c79d02-4ebf-4b0c-8a7d-5aed31f5e602",
        ])
        #expect(records.map(\.parentUUID) == [
            "a890fcde-8130-4a8b-a723-1b8de87e63d1", "e063b5ab-112b-4c43-9b72-2bf7a8df5810",
            "2791fe96-4b8f-4838-9796-2265181ea0bf", "f23f4598-cc00-41bc-8972-df41f9bea745",
        ])
        #expect(records[1].toolResults.map(\.toolUseID) == ["toolu_01RQqSDbAi69XVjZCC3iKvkW"])
    }

    @Test("A subagent file is one linear chain of 19 sidechain records")
    func subagentChain() throws {
        let lines = try ChatFixture.lines("claude/probe2-subagent.jsonl")
        let chain = Self.chain(lines, role: .subagent)
        #expect(chain.records.count == 19)
        #expect(chain.records.first?.parentUUID == nil)
        #expect(zip(chain.records, chain.records.dropFirst()).allSatisfy { $1.parentUUID == $0.uuid })
        #expect(chain.records.allSatisfy { $0.isSidechain })
        // Attachments carry no agent id; the messages do.
        #expect(chain.records.filter { $0.isUserOrAssistant }.allSatisfy { $0.agentID == "a9985bf0a8b4ebbe3" })
        #expect(chain.leafUUID == "82723790-3667-4f64-ae54-79504aea2337")
        // Read as a main transcript, a subagent's records never show.
        #expect(ClaudeSample.reducer(lines).transcript(ChatProjectionContext()).entries.isEmpty)
    }

    // MARK: - Compaction

    private static let beforeCompaction = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"First question"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"First answer"}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
        {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Second question"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Second answer"}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t2","parentUuid":"a2","durationMs":900}
        """#

    private static let afterCompaction = #"""
        {"type":"user","uuid":"s1","parentUuid":"b1","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"Summary: two questions were answered."}}
        {"type":"user","uuid":"p3","parentUuid":"s1","message":{"role":"user","content":"Third question"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a3","parentUuid":"p3","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Third answer"}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t3","parentUuid":"a3","durationMs":900}
        """#

    private static let compactedEntries = [
        "user:p1", "text:a1", "user:p2", "text:a2", "compact:b1", "user:p3", "text:a3",
    ]

    private struct Boundary: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        /// Where the first message after the summary hangs once relinked.
        let thirdPromptParent: String
        var testDescription: String { name }
    }

    private static let boundaries = [
        Boundary(
            name: "preserved segment",
            json: #"{"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"t2","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":5200,"preservedSegment":{"headUuid":"p2","anchorUuid":"s1","tailUuid":"t2"}}}"#,
            thirdPromptParent: "t2"),
        Boundary(
            name: "preserved messages",
            json: #"{"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"t2","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":5200,"preservedMessages":{"anchorUuid":"s1","uuids":["p2","a2"]}}}"#,
            thirdPromptParent: "a2"),
        Boundary(
            name: "incomplete preserved messages fall back to the segment",
            json: #"{"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"t2","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preservedMessages":{"anchorUuid":"s1","uuids":["p2","gone"]},"preservedSegment":{"headUuid":"p2","anchorUuid":"s1","tailUuid":"t2"}}}"#,
            thirdPromptParent: "t2"),
        Boundary(
            name: "no logical parent",
            json: #"{"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"content":"Conversation compacted","compactMetadata":{"trigger":"manual","preservedSegment":{"headUuid":"p2","anchorUuid":"s1","tailUuid":"t2"}}}"#,
            thirdPromptParent: "t2"),
    ]

    @Test("Compaction relinks preserved messages and keeps the history above it", arguments: boundaries)
    private func compaction(_ boundary: Boundary) {
        let lines = ClaudeSample.lines([Self.beforeCompaction, boundary.json, Self.afterCompaction].joined(separator: "\n"))
        let reducer = ClaudeSample.reducer(lines)
        let chain = reducer.chain(ChatProjectionContext())
        #expect(chain.parents["p2"] == "s1")
        #expect(chain.parents["p3"] == boundary.thirdPromptParent)
        #expect(chain.leafUUID == "a3")
        #expect(chain.records.count == 11)

        let transcript = reducer.transcript(ChatProjectionContext())
        #expect(transcript.entries.map(\.id.rawValue) == Self.compactedEntries)
        #expect(
            ClaudeSample.entry("compact:b1", in: transcript)
                == .divider(ChatDivider(kind: .compaction, detail: "Summary: two questions were answered.")))
    }

    @Test("History above a compaction follows the boundary's logical parent, not an abandoned branch")
    func compactionAfterRewind() {
        let transcript = ClaudeSample.transcript(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"First question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"First answer"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
            {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Abandoned question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Abandoned answer"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t2","parentUuid":"a2","durationMs":900}
            {"type":"user","uuid":"p2b","parentUuid":"t1","message":{"role":"user","content":"Edited question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a2b","parentUuid":"p2b","message":{"id":"m2b","role":"assistant","content":[{"type":"text","text":"Edited answer"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t2b","parentUuid":"a2b","durationMs":900}
            {"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"t2b","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preservedSegment":{"headUuid":"p2b","anchorUuid":"s1","tailUuid":"t2b"}}}
            {"type":"user","uuid":"s1","parentUuid":"b1","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"Summary"}}
            {"type":"user","uuid":"p3","parentUuid":"s1","message":{"role":"user","content":"Third question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a3","parentUuid":"p3","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Third answer"}]},"apiBlockIndex":0}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == [
            "user:p1", "text:a1", "user:p2b", "text:a2b", "compact:b1", "user:p3", "text:a3",
        ])
    }

    // MARK: - Branches and damage

    @Test("A rewind hides the old branch; its prompt stays recorded without an entry")
    func rewind() {
        let transcript = ClaudeSample.transcript(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"First question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"First answer"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
            {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Original question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Original answer"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t2","parentUuid":"a2","durationMs":900}
            {"type":"user","uuid":"p2b","parentUuid":"t1","message":{"role":"user","content":"Edited question"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a2b","parentUuid":"p2b","message":{"id":"m2b","role":"assistant","content":[{"type":"text","text":"Edited answer"}]},"apiBlockIndex":0}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "user:p2b", "text:a2b"])
        #expect(transcript.recordedPrompts.map(\.text) == ["First question", "Original question", "Edited question"])
        #expect(transcript.recordedPrompts.map(\.entryID?.rawValue) == ["user:p1", nil, "user:p2b"])
    }

    private static let unreadableResult = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Dump the log"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_big","name":"Bash","input":{"command":"cat big.log"}}]},"apiBlockIndex":0}
        {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_big","content":"\#(String(repeating: "x", count: 600))"}]}}
        {"type":"assistant","uuid":"a2","parentUuid":"r1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The log is long."}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a2","durationMs":900}
        """#

    @Test("With the head loaded, the walk bridges an unreadable line")
    func bridgesUnreadableLine() {
        let lines = ClaudeSample.lines(Self.unreadableResult, lineCap: 400, prefixCap: 64)
        #expect(lines.filter(\.isTruncated).count == 1)
        let reducer = ClaudeSample.reducer(lines)

        let whole = reducer.chain(ChatProjectionContext())
        #expect(whole.missingParent == "r1")
        #expect(whole.records.map(\.uuid) == ["p1", "a1", "a2", "t1"])
        let transcript = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_big", "text:a2"])
        guard case .tool(let row) = ClaudeSample.entry("tool:toolu_big", in: transcript) else {
            Issue.record("no Bash row")
            return
        }
        #expect(row.status == .noResult)
        #expect(transcript.diagnostics.oversizedLines == 1)

        // In a tail window the same gap is where an older page continues.
        let window = reducer.transcript(ChatProjectionContext(windowStart: 1, activity: .idle))
        #expect(window.entries.map(\.id.rawValue) == ["text:a2"])
        #expect(window.needsOlderHistory)
    }

    @Test("Of two records for one block, the walked one stays")
    func duplicateBlocks() {
        let transcript = ClaudeSample.transcript(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Hi"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"d1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Draft"}]},"apiBlockIndex":0}
            {"type":"assistant","uuid":"d2","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Final"}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"d2","durationMs":900}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:d2"])
    }

    @Test("A parent cycle ends the walk instead of looping")
    func parentCycle() {
        let lines = ClaudeSample.lines(
            #"""
            {"type":"user","uuid":"x2","parentUuid":"x3","message":{"role":"user","content":"two"},"promptSource":"typed"}
            {"type":"user","uuid":"x3","parentUuid":"x2","message":{"role":"user","content":"three"},"promptSource":"typed"}
            {"type":"assistant","uuid":"x1","parentUuid":"x2","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"one"}]},"apiBlockIndex":0}
            """#)
        let chain = ClaudeSample.reducer(lines).chain(ChatProjectionContext())
        #expect(chain.leafUUID == "x1")
        #expect(Set(chain.records.map(\.uuid)) == ["x1", "x2", "x3"])
    }
}
