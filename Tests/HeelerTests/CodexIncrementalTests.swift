import Foundation
import Testing

@testable import Heeler

/// However a rollout arrives (read sizes, batches, a tail window first and
/// older pages after), the transcript equals one pass over the whole file.
@Suite("Codex incremental reduction")
struct CodexIncrementalTests {
    private let working = ChatProjectionContext(activity: .working)

    @Test("Any read size gives the same transcript", arguments: [1, 3, 512, 4_096])
    func splitInvariance(readSize: Int) throws {
        let probe = try CodexProbe.probe2()
        let expected = probe.reducer().transcript(working)

        var framer = JSONLLineFramer(startOffset: 0)
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        for chunk in ChatFixture.chunks(probe.data, size: readSize) {
            reducer.append(framer.append(chunk))
        }
        #expect(reducer.transcript(working) == expected)
    }

    @Test("A read boundary inside a multibyte character changes nothing")
    func splitInsideMultibyteCharacter() throws {
        let probe = try CodexProbe.probe2()
        let expected = probe.reducer().transcript(working)
        let line = probe.line(62)
        let splits = line.data.indices.filter { line.data[$0] & 0xC0 == 0x80 }.map {
            Int(line.offset) + $0 - line.data.startIndex
        }
        // 19 CJK characters and punctuation marks, three bytes each.
        #expect(splits.count == 38)

        for split in splits {
            var framer = JSONLLineFramer(startOffset: 0)
            var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
            for chunk in ChatFixture.chunks(probe.data, splitAt: [split]) {
                reducer.append(framer.append(chunk))
            }
            #expect(reducer.transcript(working) == expected, "split at byte \(split)")
        }
    }

    @Test("Feeding P2 in batches equals one batch at every cut")
    func resumeEqualsBatch() throws {
        let probe = try CodexProbe.probe2()
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        var start = 0
        for cut in [22, 36, 53, 88, 101, 119] {
            reducer.append(Array(probe.lines[start..<cut]))
            start = cut
            let batch = probe.reducer(Array(probe.lines[0..<cut]))
            #expect(reducer.projection(working) == batch.projection(working), "after L\(cut)")
        }
        #expect(reducer.transcript(working) == probe.reducer().transcript(working))
    }

    @Test("A tail window from L57 gets T4 to T6 right, with T4's status from L88")
    func tailWindow() throws {
        let probe = try CodexProbe.probe2()
        let windowStart = probe.offset(57)
        #expect(windowStart == 52_156)
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        reducer.setSessionMeta(probe.line(1))
        reducer.append(Array(probe.lines[56...]))

        let context = ChatProjectionContext(windowStart: windowStart, activity: .working)
        let tail = reducer.projection(context)
        let whole = probe.reducer().projection(working)
        #expect(tail.turns.map(\.status) == [.completed, .interrupted, .completed])
        #expect(Array(tail.turns) == Array(whole.turns[3...]))
        #expect(tail.transcript.entries == whole.transcript.entries.filter { $0.sourceOffset >= windowStart })
        #expect(tail.transcript.pendingRequests == whole.transcript.pendingRequests)
        #expect(tail.transcript.needsOlderHistory)
        #expect(tail.ordinals == CodexOrdinalDiagnostics())
        // T4 started at L56, above the window: the window reports its end
        // and opens no turn for it.
        #expect(tail.transcript.turns == Array(whole.transcript.turns[4...]))
        #expect(
            tail.transcript.precedingTurnEnd
                == ChatTurnEnd(ending: .completed, endedAt: whole.transcript.turns[3].endedAt))
    }

    @Test("A tail window plus older pages equals the whole file")
    func appendThenPrepend() throws {
        let probe = try CodexProbe.probe2()
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        reducer.setSessionMeta(probe.line(1))
        reducer.append(Array(probe.lines[56...]))
        reducer.prepend(Array(probe.lines[30..<56]))
        reducer.prepend(Array(probe.lines[0..<30]))

        let whole = probe.reducer()
        #expect(reducer.projection(working) == whole.projection(working))
        #expect(!reducer.transcript(working).needsOlderHistory)
    }

    @Test("Lines fed twice are ignored")
    func overlapIgnored() throws {
        let probe = try CodexProbe.probe2()
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        reducer.append(Array(probe.lines[0..<60]))
        reducer.append(Array(probe.lines[40...]))
        reducer.prepend(Array(probe.lines[0..<10]))
        #expect(reducer.projection(working) == probe.reducer().projection(working))
    }

    @Test("A 70 KB session_meta line waits for its newline, then decides the dialect")
    func headWithoutNewline() throws {
        var builder = CodexRolloutBuilder(metaPadding: 70_000)
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hello")
        builder.agentMessage("t1", id: "a1", text: "hi")
        builder.turnComplete("t1")
        let data = builder.data
        let metaLength = try #require(builder.chatLines.first).length
        #expect(metaLength > 70_000)

        var framer = JSONLLineFramer(startOffset: 0, lineCap: 1_024 * 1_024)
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        var sawPending = false
        for chunk in ChatFixture.chunks(data, size: 4_096) {
            reducer.append(framer.append(chunk))
            if framer.processedEnd == 0 {
                sawPending = true
                #expect(reducer.support == .pending)
                #expect(reducer.transcript(working).entries.isEmpty)
            }
        }
        #expect(sawPending)
        #expect(reducer.support == .supported(.paginated))
        let expected = ["codex/r1/t1/u1", "codex/r1/t1/a1"].map { ChatEntryID($0) }
        #expect(reducer.transcript(working).entries.map(\.id) == expected)

        // Cut to a prefix, the line has lost `history_mode` (it follows the
        // base instructions), and its ordinal still marks it paginated.
        let cut = JSONLLineFramer.lines(in: data, lineCap: 16 * 1_024, prefixCap: 16 * 1_024)
        #expect(cut[0].isTruncated)
        var truncated = CodexRolloutReducer(rolloutID: "r1")
        truncated.setSessionMeta(cut[0])
        truncated.append(Array(cut[1...]))
        #expect(truncated.support == .supported(.paginated))
        #expect(truncated.transcript(working).entries.map(\.id) == expected)
    }

    @Test("Lines before the session_meta wait, then decode once it arrives")
    func linesBeforeMeta() throws {
        let probe = try CodexProbe.probe2()
        var reducer = CodexRolloutReducer(rolloutID: probe.rolloutID)
        reducer.append(Array(probe.lines[56...]))
        #expect(reducer.support == .pending)
        #expect(reducer.transcript(working).entries.isEmpty)

        reducer.prepend(Array(probe.lines[0..<56]))
        #expect(reducer.support == .supported(.paginated))
        #expect(reducer.projection(working) == probe.reducer().projection(working))
    }
}

/// What line 1 says about a rollout (docs/research/codex-rollout-format.md,
/// "Dialect detection").
@Suite("Codex dialect detection")
struct CodexDialectDetectionTests {
    @Test("Line 1 decides support", arguments: CodexHeadCase.allCases)
    func support(head: CodexHeadCase) {
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        reducer.append([ChatLine(offset: 0, data: Data(head.line.utf8))])
        #expect(reducer.support == head.expected)
    }

    @Test("Nothing decides support until line 1 arrives")
    func pendingWithoutHead() {
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        reducer.append([ChatLine(offset: 900, data: Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8))])
        #expect(reducer.support == .pending)
    }

    @Test("The first session_meta wins")
    func firstMetaWins() throws {
        var paginated = CodexRolloutBuilder()
        paginated.turnStarted("t1")
        let legacy = CodexRolloutBuilder(.legacy)
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        reducer.setSessionMeta(try #require(legacy.chatLines.first))
        reducer.append(paginated.chatLines)
        #expect(reducer.support == .supported(.legacy))
    }
}

enum CodexHeadCase: CaseIterable, CustomTestStringConvertible {
    case paginated
    case legacyExplicit
    case legacyAbsent
    case unknownMode
    case malformedMode
    case preEnvelope
    case otherRecord
    case garbage

    var testDescription: String {
        switch self {
        case .paginated: "history_mode paginated"
        case .legacyExplicit: "history_mode legacy"
        case .legacyAbsent: "no history_mode"
        case .unknownMode: "unknown history_mode"
        case .malformedMode: "history_mode not a string"
        case .preEnvelope: "pre-envelope line 1"
        case .otherRecord: "line 1 is not session_meta"
        case .garbage: "line 1 is not JSON"
        }
    }

    var line: String {
        let meta = #"{"timestamp":"2026-10-06T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/w""#
        switch self {
        case .paginated: return meta + #","history_mode":"paginated"}}"#
        case .legacyExplicit: return meta + #","history_mode":"legacy"}}"#
        case .legacyAbsent: return meta + "}}"
        case .unknownMode: return meta + #","history_mode":"tiered"}}"#
        case .malformedMode: return meta + #","history_mode":3}}"#
        case .preEnvelope: return #"{"id":"t","timestamp":"2025-01-01T00:00:00Z","instructions":null}"#
        case .otherRecord: return #"{"timestamp":"2026-10-06T00:00:00.000Z","type":"event_msg","payload":{}}"#
        case .garbage: return "not json"
        }
    }

    var expected: CodexRolloutSupport {
        switch self {
        case .paginated: .supported(.paginated)
        case .legacyExplicit, .legacyAbsent: .supported(.legacy)
        case .unknownMode, .malformedMode: .unsupported(.unknownHistoryMode)
        case .preEnvelope: .unsupported(.preEnvelope)
        case .otherRecord, .garbage: .unsupported(.noSessionMeta)
        }
    }
}
