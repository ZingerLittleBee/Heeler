import Foundation
import Testing

@testable import Heeler

@Suite("Chat conversation engine")
struct ChatConversationEngineTests {
    private static let sessionID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
    private static let cwd = "/home/dev/proj"
    private static let claudePath = "/home/dev/.claude/projects/-home-dev-proj/\(sessionID).jsonl"
    private static let codexPath =
        "/home/dev/.codex/sessions/2026/10/06/rollout-2026-10-06T12-45-25-\(thread).jsonl"
    private static let host = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    /// 2026-10-06T06:00:00Z, the day the Codex thread started.
    private static let start = Date(timeIntervalSince1970: 1_791_266_400)

    /// Small limits so a few hundred bytes exercise windows and pages.
    private static let limits = TranscriptFollower.Limits(
        tailWindow: 64, readChunk: 16, pollBudget: 1_024, olderPage: 32, maximumOlderPage: 128,
        lineStartSearch: 1_024, anchorLength: 8, headLength: 32, lineCap: 4_096, prefixCap: 16)

    private final class Clock: @unchecked Sendable {
        var now = start
    }

    private struct Fixture {
        let files = VirtualHostFiles()
        let cache = VolatileChatTranscriptCache()
        let clock = Clock()
        let program: ChatProgram
        let revision: Int
        let limits: TranscriptFollower.Limits

        init(
            program: ChatProgram = .claude, revision: Int = 1,
            limits: TranscriptFollower.Limits = ChatConversationEngineTests.limits
        ) {
            self.program = program
            self.revision = revision
            self.limits = limits
        }

        var path: String { program == .claude ? claudePath : codexPath }

        var key: ChatCacheKey {
            ChatCacheKey(
                hostID: host, herdrSession: "", program: program,
                conversationID: program == .claude ? sessionID : thread)
        }

        func makeEngine(
            workflowLimits: ChatConversationEngine.WorkflowLimits = ChatConversationEngine.WorkflowLimits()
        ) -> ChatConversationEngine {
            let clock = clock
            return ChatConversationEngine(
                reference: ConversationReference(program: program, sessionID: key.conversationID),
                cacheKey: key, files: files.hostFiles(), cache: cache,
                adapter: NumberedChatReducer.adapter(
                    revision: revision, limits: limits, wantsFirstLine: program == .codex),
                workflowLimits: workflowLimits, now: { clock.now })
        }

        func open(_ engine: ChatConversationEngine) async -> ChatConversationSnapshot {
            await engine.open(directories: [cwd], context: ChatProjectionContext(activity: .idle))
        }

        func poll(_ engine: ChatConversationEngine) async -> ChatConversationSnapshot {
            await engine.poll(context: ChatProjectionContext(activity: .idle))
        }

        func loadOlder(_ engine: ChatConversationEngine) async -> ChatConversationSnapshot {
            await engine.loadOlder(context: ChatProjectionContext(activity: .idle))
        }

        func savedDocument() async -> ChatCacheDocument? {
            guard case .hit(let document) = await cache.load(key) else { return nil }
            return document
        }

        func document(
            numbers: Range<Int>, head: String, coverageEnd: UInt64, reachedStart: Bool = true,
            revision: Int? = nil
        ) -> ChatCacheDocument {
            ChatCacheDocument(
                key: key, adapterRevision: revision ?? self.revision, transcriptPath: path,
                head: Data(head.utf8), coverageStart: 0, coverageEnd: coverageEnd,
                reachedStart: reachedStart, title: nil,
                entries: numbers.map { n in
                    ChatEntry(
                        id: ChatEntryID("n-\(n)"), sourceOffset: NumberedChatReducer.offset(of: n),
                        content: .user(ChatUserMessage(text: "\(n)")))
                },
                savedAt: start)
        }
    }

    private static func lines(_ range: Range<Int>) -> String {
        NumberedChatReducer.lines(range)
    }

    private static func offset(of n: Int) -> UInt64 {
        NumberedChatReducer.offset(of: n)
    }

    private static func numbers(_ snapshot: ChatConversationSnapshot) -> [String] {
        snapshot.transcript.entries.map(\.id.rawValue)
    }

    private static func ids(_ range: Range<Int>) -> [String] {
        NumberedChatReducer.ids(range)
    }

    // MARK: Opening and following

    @Test func opensAtTheTailAndPagesBackToTheStart() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<30), at: Self.claudePath)
        let engine = fixture.makeEngine()

        var snapshot = await fixture.open(engine)

        #expect(snapshot.phase == .following(path: Self.claudePath))
        #expect(!snapshot.isFromCache)
        #expect(snapshot.older == .available)
        #expect(snapshot.readOffset == UInt64(Self.lines(0..<30).utf8.count))
        let tail = Self.numbers(snapshot)
        #expect(tail.last == "n-29")
        #expect(tail.count < 30)

        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await fixture.loadOlder(engine)
            pages += 1
        }

        #expect(snapshot.older == .reachedStart)
        #expect(Self.numbers(snapshot) == Self.ids(0..<30))
    }

    @Test func appendedLinesShowOnTheNextPollAndAQuietPollChangesNothing() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)

        let quiet = await fixture.poll(engine)
        #expect(quiet.revision == opened.revision)

        await fixture.files.append(Self.lines(3..<5), to: Self.claudePath)
        let polled = await fixture.poll(engine)

        #expect(Self.numbers(polled) == Self.ids(0..<5))
        #expect(polled.revision > opened.revision)
        #expect(polled.readOffset == Self.offset(of: 5))
    }

    @Test func aReplacedFileStartsOverAndDropsTheCache() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3), at: Self.claudePath)
        let engine = fixture.makeEngine()
        _ = await fixture.open(engine)
        await engine.save(force: true)
        #expect(await fixture.savedDocument() != nil)

        await fixture.files.write(Self.lines(7..<9), at: Self.claudePath)
        let polled = await fixture.poll(engine)

        #expect(Self.numbers(polled) == Self.ids(7..<9))
        #expect(await fixture.savedDocument() == nil)
    }

    @Test func aMissingFileKeepsWhatShowsAndReportsItNotFound() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3), at: Self.claudePath)
        let engine = fixture.makeEngine()
        _ = await fixture.open(engine)

        await fixture.files.remove(Self.claudePath)
        let polled = await fixture.poll(engine)

        #expect(polled.phase == .unavailable(.notFound(searchedAll: true)))
        #expect(polled.isFromCache)
        #expect(Self.numbers(polled) == Self.ids(0..<3))

        // The file comes back: opening again follows it.
        await fixture.files.write(Self.lines(0..<4), at: Self.claudePath)
        let reopened = await fixture.open(engine)

        #expect(reopened.phase == .following(path: Self.claudePath))
        #expect(Self.numbers(reopened) == Self.ids(0..<4))
    }

    @Test func aReadFailureKeepsTheEntriesUntilTheNextReadSucceeds() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3), at: Self.claudePath)
        let engine = fixture.makeEngine()
        _ = await fixture.open(engine)

        await fixture.files.failNext(.status, with: TransportError.hostFileTimedOut)
        let failed = await fixture.poll(engine)

        #expect(failed.readFailure == .hostFileTimedOut)
        #expect(failed.phase == .following(path: Self.claudePath))
        #expect(Self.numbers(failed) == Self.ids(0..<3))

        let recovered = await fixture.poll(engine)

        #expect(recovered.readFailure == nil)
    }

    @Test func aFailedLocateIsRetriedByOpeningAgain() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3), at: Self.claudePath)
        let engine = fixture.makeEngine()
        await fixture.files.failNext(.home, with: TransportError.hostFileTimedOut)

        let failed = await fixture.open(engine)

        #expect(failed.phase == .locating)
        #expect(failed.readFailure == .hostFileTimedOut)

        let opened = await fixture.open(engine)

        #expect(opened.phase == .following(path: Self.claudePath))
        #expect(opened.readFailure == nil)
    }

    @Test func noTranscriptYetIsReportedAsNotFound() async throws {
        let fixture = Fixture()
        let engine = fixture.makeEngine()

        let snapshot = await fixture.open(engine)

        #expect(snapshot.phase == .unavailable(.notFound(searchedAll: true)))
        #expect(!snapshot.isFromCache)
    }

    @Test func historyTooLongToPageEndsWithADivider() async throws {
        let fixture = Fixture()
        let long = #"{"pad":""# + String(repeating: "x", count: 2_000) + "\"}\n"
        await fixture.files.write(long + Self.lines(0..<10), at: Self.claudePath)
        let engine = fixture.makeEngine()
        var snapshot = await fixture.open(engine)

        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await fixture.loadOlder(engine)
            pages += 1
        }

        #expect(snapshot.older == .reachedStart)
        #expect(snapshot.transcript.entries.first?.content == .divider(ChatDivider(kind: .historyUnavailable)))
        #expect(Array(Self.numbers(snapshot).dropFirst()) == Self.ids(0..<10))
    }

    @Test func anUnsupportedFormatStopsFollowing() async throws {
        let fixture = Fixture()
        await fixture.files.write(#"{"format":"old"}"# + "\n" + Self.lines(0..<2), at: Self.claudePath)
        let engine = fixture.makeEngine()

        let snapshot = await fixture.open(engine)

        #expect(snapshot.phase == .unavailable(.unsupportedFormat("old")))
        #expect(snapshot.transcript.entries.isEmpty)
    }

    @Test func codexReducersAreSeededWithTheRolloutsFirstLine() async throws {
        let fixture = Fixture(program: .codex)
        let meta = #"{"type":"session_meta","payload":{"id":"\#(Self.thread)"}}"#
        await fixture.files.write(meta + "\n" + Self.lines(0..<30), at: Self.codexPath)
        let engine = fixture.makeEngine()

        let snapshot = await fixture.open(engine)

        #expect(snapshot.phase == .following(path: Self.codexPath))
        #expect(snapshot.older == .available)
        #expect(snapshot.transcript.title == meta)
    }

    // MARK: Workflow journals

    private static func journal(_ run: Int) -> String {
        "/home/dev/.claude/projects/-home-dev-proj/\(sessionID)/subagents/workflows/wf_\(run)/journal.jsonl"
    }

    private static let launched = #"{"type":"launched"}"# + "\n"

    private static func started(_ key: String) -> String {
        #"{"type":"started","key":"\#(key)","agentId":"a-\#(key)","label":"audit:\#(key)","phase":"Audit"}"# + "\n"
    }

    private static func result(_ key: String) -> String {
        #"{"type":"result","key":"\#(key)","agentId":"a-\#(key)","result":"Done."}"# + "\n"
    }

    /// A transcript that launched `runs` Workflows, each with a journal of
    /// one started agent, opened and polled once.
    private static func following(
        _ runs: Range<Int>, workflowLimits: ChatConversationEngine.WorkflowLimits = .init()
    ) async -> (Fixture, ChatConversationEngine) {
        let fixture = Fixture(limits: TranscriptFollower.Limits())
        let launches = runs.map { NumberedChatReducer.launch("w\($0)", journal: journal($0)) }.joined()
        await fixture.files.write(lines(0..<2) + launches, at: claudePath)
        for run in runs {
            await fixture.files.write(launched + started("k\(run)"), at: journal(run))
        }
        let engine = fixture.makeEngine(workflowLimits: workflowLimits)
        _ = await fixture.open(engine)
        return (fixture, engine)
    }

    private static func journalLooks(_ fixture: Fixture) async -> [String] {
        await fixture.files.statuses.filter { $0.hasSuffix("journal.jsonl") }
    }

    @Test func aListedWorkflowsJournalIsReadOnlyWhileTheTranscriptIs() async throws {
        let fixture = Fixture(limits: TranscriptFollower.Limits())
        await fixture.files.write(Self.lines(0..<2) + NumberedChatReducer.launch("w1", journal: Self.journal(1)), at: Self.claudePath)
        await fixture.files.write(Self.launched + Self.started("k1"), at: Self.journal(1))
        let engine = fixture.makeEngine()

        // Nothing is followed yet.
        #expect(await engine.followWorkflows().isEmpty)
        #expect(await Self.journalLooks(fixture).isEmpty)

        _ = await fixture.open(engine)
        let progress = await engine.followWorkflows()

        #expect(progress["w1"]?.agents == [ChatWorkflowProgress.Agent(id: "k1", label: "audit:k1", phase: "Audit", state: .running)])
        #expect(progress["w1"]?.updatedAt != nil)

        // A transcript read that failed leaves the journals alone.
        await fixture.files.failNext(.status, path: Self.claudePath, with: TransportError.hostFileTimedOut)
        _ = await fixture.poll(engine)
        await fixture.files.clearRecords()
        #expect(await engine.followWorkflows() == progress)
        #expect(await Self.journalLooks(fixture).isEmpty)
    }

    @Test func aQuietJournalCostsOneStatAndAnEndedWorkflowIsReadToItsEndOnce() async throws {
        let (fixture, engine) = await Self.following(1..<2)
        _ = await engine.followWorkflows()
        await fixture.files.clearRecords()

        _ = await engine.followWorkflows()
        #expect(await fixture.files.statuses == [Self.journal(1)])
        #expect(await fixture.files.reads.isEmpty)

        await fixture.files.append(Self.result("k1"), to: Self.journal(1))
        await fixture.files.append(NumberedChatReducer.end("w1"), to: Self.claudePath)
        _ = await fixture.poll(engine)
        let final = await engine.followWorkflows()
        #expect(final["w1"]?.done == 1)

        await fixture.files.clearRecords()
        #expect(await engine.followWorkflows() == final)
        #expect(await Self.journalLooks(fixture).isEmpty)

        // The next prompt takes it off the list, and it is forgotten.
        await fixture.files.append(NumberedChatReducer.prompt("Thanks"), to: Self.claudePath)
        _ = await fixture.poll(engine)
        #expect(await engine.followWorkflows().isEmpty)
    }

    @Test func aJournalThatFailsWaitsAndNeverTouchesTheTranscript() async throws {
        let (fixture, engine) = await Self.following(1..<2)
        await fixture.files.failNext(.status, path: Self.journal(1), with: TransportError.hostFileTimedOut)

        #expect(await engine.followWorkflows().isEmpty)
        let polled = await fixture.poll(engine)
        #expect(polled.readFailure == nil)

        // Within the backoff nothing is asked.
        await fixture.files.clearRecords()
        #expect(await engine.followWorkflows().isEmpty)
        #expect(await Self.journalLooks(fixture).isEmpty)

        fixture.clock.now = Self.start.addingTimeInterval(2)
        #expect(await engine.followWorkflows()["w1"]?.started == 1)
    }

    @Test func eachCallLooksAtTheLeastRecentlyReadJournalsFirst() async throws {
        let (fixture, engine) = await Self.following(1..<4)

        let first = await engine.followWorkflows()
        #expect(first.keys.sorted() == ["w1", "w2"])
        await fixture.files.clearRecords()

        let second = await engine.followWorkflows()
        #expect(second.keys.sorted() == ["w1", "w2", "w3"])
        #expect(await Self.journalLooks(fixture) == [Self.journal(3), Self.journal(1)])
    }

    @Test func aJournalCatchesUpOverSeveralCallsAndShowsOnlyOnceRead() async throws {
        var limits = ChatConversationEngine.WorkflowLimits()
        limits.follower.readChunk = 64
        limits.journalBudget = 64
        let (fixture, engine) = await Self.following(1..<2, workflowLimits: limits)
        await fixture.files.append(Self.started("k2") + Self.started("k3"), to: Self.journal(1))

        var calls = 0
        var progress: [String: ChatWorkflowProgress] = [:]
        while progress["w1"] == nil, calls < 10 {
            progress = await engine.followWorkflows()
            calls += 1
        }
        #expect(calls > 1)
        #expect(progress["w1"]?.started == 3)
    }

    // MARK: Cache

    @Test func workLaunchedAboveALaterWindowStaysListedAndEndsInIt() async throws {
        let fixture = Fixture()
        await fixture.files.write(
            Self.lines(0..<2) + NumberedChatReducer.launch("w1", journal: nil), at: Self.claudePath)
        let first = fixture.makeEngine()
        var snapshot = await fixture.open(first)
        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await fixture.loadOlder(first)
            pages += 1
        }
        #expect(snapshot.transcript.listedBackgroundWork.map(\.id) == ["w1"])
        await first.save(force: true)

        // Reopened once the launch is above the tail window.
        await fixture.files.append(Self.lines(2..<8), to: Self.claudePath)
        let second = fixture.makeEngine()
        _ = await second.restore()
        snapshot = await fixture.open(second)
        // The launch line is above the window; the saved entries fill in.
        #expect(Self.numbers(snapshot) == Self.ids(0..<8))
        let listed = snapshot.transcript.listedBackgroundWork
        #expect(listed.map(\.id) == ["w1"])
        #expect(listed.first?.state == .running)

        let endOffset = UInt64(await fixture.files.contents(of: Self.claudePath)?.count ?? 0)
        await fixture.files.append(NumberedChatReducer.end("w1"), to: Self.claudePath)
        snapshot = await fixture.poll(second)
        #expect(snapshot.transcript.listedBackgroundWork.first?.state == .completed)
        #expect(snapshot.transcript.listedBackgroundWork.first?.endOffset == endOffset)
    }

    @Test func savedEntriesShowBeforeTheHostAnswers() async throws {
        let fixture = Fixture()
        await fixture.cache.save(
            fixture.document(numbers: 0..<3, head: Self.lines(0..<3), coverageEnd: Self.offset(of: 3)))
        let engine = fixture.makeEngine()

        let restored = await engine.restore()

        #expect(restored.phase == .locating)
        #expect(restored.isFromCache)
        #expect(restored.older == .reachedStart)
        #expect(Self.numbers(restored) == Self.ids(0..<3))
    }

    @Test func savedEntriesFillInAboveTheLiveWindow() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<30), at: Self.claudePath)
        await fixture.cache.save(
            fixture.document(numbers: 0..<25, head: Self.lines(0..<30), coverageEnd: Self.offset(of: 25)))
        let engine = fixture.makeEngine()
        _ = await engine.restore()

        let snapshot = await fixture.open(engine)

        #expect(snapshot.phase == .following(path: Self.claudePath))
        #expect(!snapshot.isFromCache)
        #expect(snapshot.older == .reachedStart)
        #expect(Self.numbers(snapshot) == Self.ids(0..<30))
    }

    @Test func aGapBeforeTheLiveWindowKeepsSavedEntriesOutUntilPagesCloseIt() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<30), at: Self.claudePath)
        await fixture.cache.save(
            fixture.document(numbers: 0..<5, head: Self.lines(0..<30), coverageEnd: Self.offset(of: 5)))
        let engine = fixture.makeEngine()
        _ = await engine.restore()

        var snapshot = await fixture.open(engine)

        #expect(snapshot.older == .available)
        #expect(!Self.numbers(snapshot).contains("n-0"))

        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await fixture.loadOlder(engine)
            pages += 1
        }

        #expect(Self.numbers(snapshot) == Self.ids(0..<30))
        // The saved entries closed the gap before the window reached the head.
        #expect(snapshot.older == .reachedStart)
        #expect(snapshot.transcript.needsOlderHistory)
    }

    @Test func anotherConversationUnderTheSameNameDropsTheSavedEntries() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(10..<12), at: Self.claudePath)
        await fixture.cache.save(
            fixture.document(numbers: 0..<3, head: Self.lines(0..<3), coverageEnd: Self.offset(of: 3)))
        let engine = fixture.makeEngine()
        _ = await engine.restore()

        let snapshot = await fixture.open(engine)

        #expect(Self.numbers(snapshot) == Self.ids(10..<12))
        #expect(await fixture.savedDocument() == nil)
    }

    @Test func entriesFromAnOlderAdapterRevisionAreDiscarded() async throws {
        let fixture = Fixture(revision: 2)
        await fixture.cache.save(
            fixture.document(
                numbers: 0..<3, head: Self.lines(0..<3), coverageEnd: Self.offset(of: 3), revision: 1))
        let engine = fixture.makeEngine()

        let restored = await engine.restore()

        #expect(restored.transcript.entries.isEmpty)
        #expect(await fixture.savedDocument() == nil)
    }

    @Test func savingRecordsCoverageAndIsThrottledUnlessForced() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<30), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)

        await engine.save()
        let first = try #require(await fixture.savedDocument())

        #expect(first.transcriptPath == Self.claudePath)
        #expect(first.coverageEnd == opened.readOffset)
        #expect(first.coverageStart == opened.transcript.entries.first?.sourceOffset)
        #expect(!first.reachedStart)
        #expect(first.head == Data(Self.lines(0..<30).utf8.prefix(32)))

        await fixture.files.append(Self.lines(30..<31), to: Self.claudePath)
        _ = await fixture.poll(engine)
        fixture.clock.now = Self.start.addingTimeInterval(5)
        await engine.save()

        #expect(await fixture.savedDocument()?.entries.last?.id.rawValue == "n-29")

        await engine.save(force: true)

        #expect(await fixture.savedDocument()?.entries.last?.id.rawValue == "n-30")
    }

    @Test func nothingIsSavedBeforeTheTranscriptIsFollowed() async throws {
        let fixture = Fixture()
        await fixture.cache.save(
            fixture.document(numbers: 0..<3, head: Self.lines(0..<3), coverageEnd: Self.offset(of: 3)))
        let engine = fixture.makeEngine()
        _ = await engine.restore()
        _ = await fixture.open(engine)

        await engine.save(force: true)

        // Not found keeps the saved entries rather than overwriting them.
        #expect(await fixture.savedDocument()?.entries.count == 3)
    }
}
