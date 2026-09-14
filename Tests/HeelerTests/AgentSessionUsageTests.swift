import Foundation
import Testing

@testable import Heeler

/// The accounting rule (#325) is one rule with three entry kinds; these rows
/// are session files, and the expectation is the figure omp's own bar renders
/// for that file. A row that mixes entry kinds catches the two variants that
/// look right on the happy path: counting assistant entries alone, and
/// recursing through `details`.
@Suite("Agent session usage")
struct AgentSessionUsageTests {
    private struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        let cost: Double?
        let tokens: Int?
        let model: String?

        var testDescription: String { name }
    }

    /// A turn that reached a provider: it anchors the prompt it measured.
    private static func anchored(
        model: String, promptTokens: Int, cost: Double, removed: Int? = nil,
        stopReason: String = "endTurn"
    ) -> String {
        let removedField = removed.map { #","historyRewriteTokensRemoved":\#($0)"# } ?? ""
        return #"{"type":"message","message":{"role":"assistant","stopReason":"\#(stopReason)","model":"\#(model)","contextSnapshot":{"promptTokens":\#(promptTokens)\#(removedField)},"usage":{"cost":{"total":\#(cost)}}}}"#
    }

    private static let rows: [Row] = [
        Row(
            name: "an assistant turn bills its usage and anchors the prompt it measured",
            lines: [
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.89)
            ],
            cost: 0.89,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "a task toolResult bills details.usage without recursing",
            lines: [
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.89),
                #"{"type":"message","message":{"role":"toolResult","toolName":"task","details":{"usage":{"cost":{"total":0.61},"nested":{"usage":{"cost":{"total":1.22}}}}}}}"#,
            ],
            cost: 1.5,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "another tool's toolResult bills nothing",
            lines: [
                #"{"type":"message","message":{"role":"assistant","model":"gemini-3-pro","usage":{"cost":{"total":0.89}}}}"#,
                #"{"type":"message","message":{"role":"toolResult","toolName":"bash","details":{"usage":{"cost":{"total":9.99}}}}}"#,
            ],
            cost: 0.89,
            tokens: nil,
            model: "gemini-3-pro"),
        Row(
            name: "model_usage entries bill their own usage",
            lines: [
                #"{"type":"model_usage","usage":{"cost":{"total":0.05}}}"#,
                #"{"type":"model_usage","usage":{"cost":{"total":0.1}}}"#,
            ],
            cost: 0.15,
            tokens: nil,
            model: nil),
        Row(
            name: "the newest anchored turn wins for the prompt and the model",
            lines: [
                anchored(model: "deepseek-flash", promptTokens: 167_000, cost: 0.89),
                #"{"type":"message","message":{"role":"user"}}"#,
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.1),
            ],
            cost: 0.99,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "a turn that aborted never blanks what an earlier one measured",
            lines: [
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.1),
                // The turn failed before reaching a provider, so its snapshot
                // describes a prompt that was never sent.
                anchored(
                    model: "ghost", promptTokens: 999_999, cost: 0.0, stopReason: "aborted"),
            ],
            cost: 0.1,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "a turn that reported no usage keeps the earlier prompt too",
            lines: [
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.1),
                #"{"type":"message","message":{"role":"assistant","stopReason":"endTurn","model":"phantom","usage":{}}}"#,
            ],
            cost: 0.1,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "removed history is subtracted from the measured prompt",
            lines: [
                anchored(
                    model: "gemini-3-pro", promptTokens: 100_000, cost: 0.1, removed: 5_000)
            ],
            cost: 0.1,
            tokens: 95_000,
            model: "gemini-3-pro"),
        Row(
            name: "with no snapshot the prompt-side counters stand in",
            lines: [
                #"{"type":"message","message":{"role":"assistant","stopReason":"endTurn","usage":{"input":500,"cacheRead":80000,"cacheWrite":0}}}"#
            ],
            cost: nil,
            tokens: 80_500,
            model: nil),
        Row(
            name: "null, missing, and non-numeric costs bill nothing",
            lines: [
                #"{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":null}}}}"#,
                #"{"type":"message","message":{"role":"assistant","usage":{"totalTokens":12}}}"#,
                #"{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":"free"}}}}"#,
                #"{"type":"model_usage"}"#,
            ],
            cost: nil,
            tokens: nil,
            model: nil),
        Row(
            name: "malformed, empty, and truncated lines are skipped",
            lines: [
                "",
                "not json at all",
                anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 0.89),
                #"{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":0.1"#,
                #"{"type":"custom","data":{}}"#,
                #"{"type":"message","message":{"role":"user","content":[{"type":"text"}]}}"#,
            ],
            cost: 0.89,
            tokens: 248_000,
            model: "gemini-3-pro"),
        Row(
            name: "an entry with no cost object leaves the sum alone",
            lines: [
                #"{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":0.5}}}}"#,
                #"{"type":"model_usage","usage":null}"#,
                #"{"type":"message","message":{"role":"toolResult","toolName":"task"}}"#,
            ],
            cost: 0.5,
            tokens: nil,
            model: nil),
        Row(
            name: "an empty line list reports nothing",
            lines: [],
            cost: nil,
            tokens: nil,
            model: nil),
    ]

    @Test("folds the accounting rule", arguments: rows)
    private func foldsAccountingRule(_ row: Row) {
        var usage = AgentSessionUsage()
        for line in row.lines {
            usage.fold(line: Data(line.utf8))
        }
        // Money arrives as decimal doubles and is summed, so bit-exact
        // equality is not a property it has: 0.05 + 0.1 is not 0.15.
        switch (usage.cost, row.cost) {
        case (nil, nil):
            break
        case let (actual?, expected?) where abs(actual - expected) < 1e-9:
            break
        default:
            Issue.record(
                Comment(
                    rawValue: "\(row.name): cost "
                        + "\(usage.cost.map(String.init(describing:)) ?? "nil") != "
                        + "\(row.cost.map(String.init(describing:)) ?? "nil")"))
        }
        #expect(usage.contextTokens == row.tokens, "\(row.name): tokens")
        #expect(usage.model == row.model, "\(row.name): model")
    }

    @Test("a folded total never becomes NaN or infinite")
    func foldedTotalStaysFinite() {
        var usage = AgentSessionUsage()
        usage.fold(line: Data(#"{"type":"model_usage","usage":{"cost":{"total":1e308}}}"#.utf8))
        usage.fold(line: Data(#"{"type":"model_usage","usage":{"cost":{"total":1e308}}}"#.utf8))
        let cost = usage.cost ?? 0
        #expect(cost.isFinite)
    }

    @Test("the strip's figures are nil exactly when the value is unknown")
    func figuresOmitUnknownValues() {
        var empty = AgentSessionUsage()
        #expect(empty.costText == nil && empty.contextText == nil)
        empty.fold(
            line: Data(
                Self.anchored(model: "gemini-3-pro", promptTokens: 248_000, cost: 1.65).utf8))
        #expect(empty.costText == "$1.65")
        #expect(empty.contextText == "248K")
    }

    /// The shape an Agent's own status line uses, so a reader comparing the two
    /// is not misled by a different rounding rule.
    @Test("context figures carry an order of magnitude and round rather than truncate")
    func contextTextContracts() {
        func text(promptTokens: Int) -> String? {
            var usage = AgentSessionUsage()
            usage.fold(
                line: Data(
                    Self.anchored(model: "gemini-3-pro", promptTokens: promptTokens, cost: 0.1)
                        .utf8))
            return usage.contextText
        }
        #expect(text(promptTokens: 0) == "0")
        #expect(text(promptTokens: 999) == "999")
        #expect(text(promptTokens: 1_000) == "1K")
        #expect(text(promptTokens: 9_500) == "9.5K")
        #expect(text(promptTokens: 76_675) == "77K")
        #expect(text(promptTokens: 124_523) == "125K")
        #expect(text(promptTokens: 1_000_000) == "1M")
        #expect(text(promptTokens: 1_500_000) == "1.5M")
        #expect(text(promptTokens: 12_400_000) == "12M")
    }
}

/// The store's half of the rule: read only the appended tail, keep what was
/// already folded, and start over when the file it was reading is gone.
/// Money is summed from decimal doubles, so a bit-exact comparison is not a
/// property it has: 0.05 + 0.1 is not 0.15. Reads the store's main-actor
/// state, so it is main-actor isolated like the suite that calls it.
@MainActor
private func sumsTo(_ store: AgentSessionUsageStore, _ expected: Double) -> Bool {
    guard let value = store.usage.cost else { return false }
    return abs(value - expected) < 1e-9
}

@MainActor
@Suite("Agent session usage store")
struct AgentSessionUsageStoreTests {
    /// A session file that grows.
    private final class SessionFile {
        var contents = Data()
        init() {}

        func append(_ line: String) {
            contents.append(Data(line.utf8))
            contents.append(0x0A)
        }
    }

    private static func assistant(model: String, tokens: Int, cost: Double) -> String {
        #"{"type":"message","message":{"role":"assistant","stopReason":"endTurn","model":"\#(model)","contextSnapshot":{"promptTokens":\#(tokens)},"usage":{"cost":{"total":\#(cost)}}}}"#
    }

    /// Reads from the scripted file while recording what was asked for, so a
    /// test can tell a tail read from a whole-file re-read. The recorder is an
    /// actor, so reading it back is async; neither closure is `@Sendable`,
    /// matching `refresh(path:read:)` and letting them hold the mutable file.
    private static func reader(
        _ file: SessionFile
    ) -> ((RemoteFileRange) async throws -> RemoteFileSlice, () async -> [RemoteFileRange]) {
        let recorder = RangeRecorder()
        let read: (RemoteFileRange) async throws -> RemoteFileSlice = { range in
            await recorder.record(range)
            let contents = file.contents
            guard range.offset < UInt64(contents.count) else {
                return RemoteFileSlice(data: Data(), length: UInt64(contents.count))
            }
            let start = contents.startIndex.advanced(by: Int(range.offset))
            let end = min(contents.endIndex, start + range.maxBytes)
            return RemoteFileSlice(
                data: contents[start..<end], length: UInt64(contents.count))
        }
        return (read, { await recorder.ranges })
    }

    private actor RangeRecorder {
        private(set) var ranges: [RemoteFileRange] = []

        func record(_ range: RemoteFileRange) {
            ranges.append(range)
        }
    }

    @Test("a second refresh reads only what the file gained")
    func refreshReadsAppendedTailOnly() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_000, cost: 1.65))
        let store = AgentSessionUsageStore()
        let (read, ranges) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 1.65))
        #expect(store.usage.contextTokens == 248_000)
        #expect(store.usage.model == "gemini-3-pro")
        let firstOffset = UInt64(file.contents.count)

        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_100, cost: 0.1))
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)

        #expect(sumsTo(store, 1.75))
        #expect(store.usage.contextTokens == 248_100)
        let recorded = await ranges()
        #expect(recorded.count == 2)
        #expect(recorded.first?.offset == 0)
        #expect(recorded.last?.offset == firstOffset)
    }

    @Test("a line still being written is folded once its newline lands")
    func partialLineWaitsForItsNewline() async {
        let file = SessionFile()
        file.contents = Data(
            #"{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":0.25}}}}"#
                .utf8)
        let store = AgentSessionUsageStore()
        let (read, _) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(store.usage.cost == nil)

        file.contents.append(0x0A)
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 0.25))
    }

    @Test("an offset past the end of a replaced file starts the read over")
    func shorterFileResetsTheOffset() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "deepseek-flash", tokens: 167_000, cost: 0.89))
        file.append(Self.assistant(model: "deepseek-flash", tokens: 167_100, cost: 0.9))
        let store = AgentSessionUsageStore()
        let (read, ranges) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 1.79))

        // Rotation: the same path now holds a shorter, unrelated session.
        file.contents = Data()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 12_000, cost: 0.05))
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)

        #expect(sumsTo(store, 0.05))
        #expect(store.usage.contextTokens == 12_000)
        let recorded = await ranges()
        #expect(recorded.last?.offset == 0)
    }

    @Test("an absent session file shows nothing")
    func absentFileClearsTheTotals() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_000, cost: 1.65))
        let store = AgentSessionUsageStore()
        let (read, ranges) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 1.65))

        let absent: @Sendable (RemoteFileRange) async throws -> RemoteFileSlice = { _ in
            RemoteFileSlice(data: Data(), length: nil)
        }
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: absent)
        #expect(store.usage.cost == nil)
        #expect(store.usage.contextTokens == nil)
        #expect(await ranges().count == 1)
    }

    @Test("a failed read keeps the totals it already had")
    func failedReadKeepsTotals() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_000, cost: 1.65))
        let store = AgentSessionUsageStore()
        let (read, _) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        let failing: @Sendable (RemoteFileRange) async throws -> RemoteFileSlice = { _ in
            throw TransportError.channelFailed(detail: "link down")
        }
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: failing)
        #expect(sumsTo(store, 1.65))

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_100, cost: 0.1))
        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 1.75))
    }

    @Test("another Agent's path drops the previous totals")
    func pathChangeStartsOver() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "deepseek-flash", tokens: 167_000, cost: 0.89))
        let store = AgentSessionUsageStore()
        let (read, ranges) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/first.jsonl", read: read)
        #expect(sumsTo(store, 0.89))

        file.contents = Data()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 12_000, cost: 0.05))
        await store.refresh(path: "/home/dev/.omp/sessions/second.jsonl", read: read)

        #expect(sumsTo(store, 0.05))
        let recorded = await ranges()
        #expect(recorded.last?.path == "/home/dev/.omp/sessions/second.jsonl")
        #expect(recorded.last?.offset == 0)
    }

    @Test("clearing drops the followed file")
    func clearDropsState() async {
        let file = SessionFile()
        file.append(Self.assistant(model: "gemini-3-pro", tokens: 248_000, cost: 1.65))
        let store = AgentSessionUsageStore()
        let (read, _) = Self.reader(file)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        store.clear()
        #expect(store.usage.cost == nil)

        await store.refresh(path: "/home/dev/.omp/sessions/s.jsonl", read: read)
        #expect(sumsTo(store, 1.65))
    }
}

/// The ranged read is a Transport requirement, so a double that never expected
/// one must fail loudly instead of quietly returning an empty file.
@Suite("Ranged session reads")
struct AgentSessionFileRangeTransportTests {
    private static let range = RemoteFileRange(
        path: "/home/dev/.omp/sessions/s.jsonl", offset: 0, maxBytes: 1_024)

    @Test("an unscripted ranged read throws")
    func unscriptedReadThrows() async throws {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "0.9.0-fake", protocolVersion: 17)))
        await #expect(throws: TransportError.self) {
            _ = try await transport.readFileSlice(Self.range)
        }
    }

    @Test("a scripted ranged read answers the requested range")
    func scriptedReadAnswersRange() async throws {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "0.9.0-fake", protocolVersion: 17)))
        await transport.setFileSlices([
            RemoteFileSlice(data: Data("tail\n".utf8), length: 9_000)
        ])
        let slice = try await transport.readFileSlice(Self.range)
        #expect(slice.data == Data("tail\n".utf8))
        #expect(slice.length == 9_000)
        #expect(await transport.fileRanges == [Self.range])
    }
}
