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
        olderSearchPage: 32, lineStartSearch: 1_024, anchorLength: 8, headLength: 32, lineCap: 4_096, prefixCap: 16)

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

        func loadOlder(_ engine: ChatConversationEngine, automatic: Bool = false) async -> ChatConversationSnapshot {
            await engine.loadOlder(context: ChatProjectionContext(activity: .idle), automatic: automatic)
        }

        /// The bytes read from the Host since the records were cleared.
        func bytesRead() async -> Int {
            await files.reads.reduce(0) { $0 + $1.maxBytes }
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

    // MARK: A new Claude Code conversation

    private static let sessionEnvironment = "/home/dev/.claude/session-env/\(sessionID)"

    /// Claude Code starts a session, which herdr reports, and writes its
    /// transcript with the first message. While it is new, looking again
    /// stats the Agent's directory alone until herdr reports the Agent
    /// doing something else.
    @Test func aStartedClaudeSessionIsNewUntilItsFileAppears() async throws {
        let fixture = Fixture()
        await fixture.files.makeDirectory(Self.sessionEnvironment)
        for index in 0..<3 {
            await fixture.files.makeDirectory("/home/dev/.claude/projects/-p\(index)")
        }
        let engine = fixture.makeEngine()

        let first = await fixture.open(engine)

        #expect(first.phase == .unavailable(.awaitingFirstMessage(.claude)))
        #expect(!first.isFromCache)

        await fixture.files.clearRecords()
        let again = await fixture.open(engine)

        #expect(again.phase == .unavailable(.awaitingFirstMessage(.claude)))
        #expect(await fixture.files.statuses == [Self.claudePath])
        #expect(await fixture.files.listings.isEmpty)

        // A prompt: every project directory once more, then the Agent's.
        await fixture.files.clearRecords()
        let working = ChatProjectionContext(activity: .working)
        #expect(
            await engine.open(directories: [Self.cwd], context: working).phase
                == .unavailable(.awaitingFirstMessage(.claude)))
        #expect(await fixture.files.listings.count == 1)
        await fixture.files.clearRecords()
        _ = await engine.open(directories: [Self.cwd], context: working)
        #expect(await fixture.files.listings.isEmpty)

        await fixture.files.write(Self.lines(0..<2), at: Self.claudePath)
        let followed = await engine.open(directories: [Self.cwd], context: working)

        #expect(followed.phase == .following(path: Self.claudePath))
        #expect(Self.numbers(followed) == Self.ids(0..<2))
    }

    /// A search of every project directory that fails is not repeated on
    /// every pass: the Agent's directory is still looked at.
    @Test func aFailedSearchForANewClaudeConversationRunsOncePerActivity() async throws {
        let fixture = Fixture()
        await fixture.files.makeDirectory(Self.sessionEnvironment)
        await fixture.files.makeDirectory("/home/dev/.claude/projects/-p0")
        let engine = fixture.makeEngine()
        #expect(await fixture.open(engine).phase == .unavailable(.awaitingFirstMessage(.claude)))
        let working = ChatProjectionContext(activity: .working)

        await fixture.files.failNext(.list, with: TransportError.hostFileTimedOut)
        let failed = await engine.open(directories: [Self.cwd], context: working)

        #expect(failed.phase == .unavailable(.awaitingFirstMessage(.claude)))
        #expect(failed.readFailure == .hostFileTimedOut)

        await fixture.files.clearRecords()
        let again = await engine.open(directories: [Self.cwd], context: working)

        #expect(again.readFailure == nil)
        #expect(await fixture.files.listings.isEmpty)
        #expect(await fixture.files.statuses == [Self.claudePath])
    }

    @Test func aClaudeFileShownBeforeThatIsGoneIsNotFound() async throws {
        let fixture = Fixture()
        await fixture.files.makeDirectory(Self.sessionEnvironment)
        await fixture.files.write(Self.lines(0..<2), at: Self.claudePath)
        let engine = fixture.makeEngine()
        #expect(await fixture.open(engine).phase == .following(path: Self.claudePath))
        await engine.save(force: true)

        await fixture.files.remove(Self.claudePath)

        #expect(await fixture.poll(engine).phase == .unavailable(.notFound(searchedAll: true)))

        // Saved on the device, then gone from the Host, on a later visit.
        let later = fixture.makeEngine()
        _ = await later.restore()
        #expect(await fixture.open(later).phase == .unavailable(.notFound(searchedAll: true)))
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

    @Test("After a Codex undo, relocating follows the thread's new file, which a poll never reaches")
    func codexUndoMovesTheLiveFile() async throws {
        let fixture = Fixture(program: .codex)
        let meta = #"{"type":"session_meta","payload":{"id":"\#(Self.thread)"}}"#
        await fixture.files.write(meta + "\n" + Self.lines(0..<10), at: Self.codexPath)
        let engine = fixture.makeEngine()
        let context = ChatProjectionContext(activity: .idle)
        #expect(await fixture.open(engine).phase == .following(path: Self.codexPath))
        // Nothing moved: relocating only polls.
        #expect(await engine.relocate(context: context).phase == .following(path: Self.codexPath))

        // The undo leaves the base file as it was and continues in a sibling.
        let segment =
            "/home/dev/.codex/sessions/2026/10/06/rollout-2026-10-06T13-00-00-\(Self.thread)_01a10f9a-0000-7000-8000-000000000001.jsonl"
        await fixture.files.write(meta + "\n" + Self.lines(40..<43), at: segment)
        #expect(await fixture.poll(engine).phase == .following(path: Self.codexPath))

        let moved = await engine.relocate(context: context)
        #expect(moved.phase == .following(path: segment))
        #expect(Array(Self.numbers(moved).suffix(3)) == Self.ids(40..<43))
        #expect(Set(Self.numbers(moved)).isDisjoint(with: Self.ids(0..<10)))
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

    @Test func loadingOlderReadsPastPagesThatShowNothing() async throws {
        let fixture = Fixture()
        // Records that show nothing, many pages of them, inside one turn.
        let silent = String(repeating: NumberedChatReducer.end("none"), count: 40)
        await fixture.files.write(
            NumberedChatReducer.prompt("a") + Self.lines(0..<3) + silent + Self.lines(3..<10), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)
        #expect(Self.numbers(opened).first == "n-3")

        // One request reads every page back to the turn's prompt.
        let snapshot = await fixture.loadOlder(engine)
        #expect(Self.numbers(snapshot).first == "p-0")
        #expect(snapshot.older == .reachedStart)
    }

    @Test func loadingOlderReadsBackToTheOldestTurnsOpener() async throws {
        let fixture = Fixture()
        let first = NumberedChatReducer.prompt("a") + Self.lines(0..<4)
        let second = UInt64(first.utf8.count)
        await fixture.files.write(first + NumberedChatReducer.prompt("b") + Self.lines(4..<14), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)
        #expect(Self.numbers(opened).first?.hasPrefix("n-") == true)

        // The window opened inside the second turn: one request reads back
        // to its prompt, maybe past it, and the next to the first turn's.
        var snapshot = await fixture.loadOlder(engine)
        #expect(snapshot.transcript.turns.map(\.firstEntryID.rawValue) == ["p-\(second)"])
        #expect(!Self.numbers(snapshot).contains("n-0"))
        snapshot = await fixture.loadOlder(engine)
        #expect(Self.numbers(snapshot).first == "p-0")
    }

    @Test func loadingOlderStopsSearchingAtItsLimit() async throws {
        var limits = Self.limits
        limits.olderSearch = 64
        let fixture = Fixture(limits: limits)
        let silent = String(repeating: NumberedChatReducer.end("none"), count: 40)
        await fixture.files.write(Self.lines(0..<3) + silent + Self.lines(3..<6), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = Self.numbers(await fixture.open(engine))

        let snapshot = await fixture.loadOlder(engine)

        #expect(Self.numbers(snapshot) == opened)
        #expect(snapshot.older == .available)
    }

    /// Short turns bring an opener within what a bounded request Chat
    /// makes by itself may read, so it reads and shows what the user's
    /// would.
    @Test func automaticRequestsLoadShortTurnsAsTheUsersDo() async throws {
        var limits = Self.limits
        limits.automaticOlderSearch = 160
        let text = (0..<8).map { turn in
            NumberedChatReducer.prompt("t\(turn)") + Self.lines((turn * 3)..<(turn * 3 + 3))
                + NumberedChatReducer.turnEnd
        }.joined()
        let automatic = Fixture(limits: limits)
        let user = Fixture(limits: limits)
        await automatic.files.write(text, at: Self.claudePath)
        await user.files.write(text, at: Self.claudePath)
        let byItself = automatic.makeEngine()
        let asked = user.makeEngine()
        var snapshot = await automatic.open(byItself)
        _ = await user.open(asked)

        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await automatic.loadOlder(byItself, automatic: true)
            let expected = await user.loadOlder(asked)
            #expect(Self.numbers(snapshot) == Self.numbers(expected))
            #expect(snapshot.transcript.turns == expected.transcript.turns)
            #expect(snapshot.older == expected.older)
            #expect(!snapshot.olderAwaitsUser)
            pages += 1
        }

        #expect(pages > 3)
        #expect(snapshot.older == .reachedStart)
        let userReads = await user.files.reads
        #expect(await automatic.files.reads == userReads)
    }

    /// A turn longer than a bounded request Chat makes by itself may read:
    /// the request stops at its limit and leaves the rest to the user, and
    /// the next one reads nothing. The user's request reads on to the
    /// turn's prompt, and then Chat loads by itself again.
    @Test func automaticRequestsStopInsideATurnLongerThanTheirLimit() async throws {
        var limits = Self.limits
        limits.automaticOlderSearch = 96
        let fixture = Fixture(limits: limits)
        let first = NumberedChatReducer.prompt("a") + Self.lines(0..<6) + NumberedChatReducer.turnEnd
        let silent = String(repeating: NumberedChatReducer.end("none"), count: 40)
        await fixture.files.write(
            first + NumberedChatReducer.prompt("b") + silent + Self.lines(6..<10), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)
        try #require(opened.transcript.turns.isEmpty)
        await fixture.files.clearRecords()

        var snapshot = await fixture.loadOlder(engine, automatic: true)
        #expect(await fixture.bytesRead() == 96)
        #expect(snapshot.transcript.turns.isEmpty)
        #expect(snapshot.older == .available)
        #expect(snapshot.olderAwaitsUser)

        await fixture.files.clearRecords()
        snapshot = await fixture.loadOlder(engine, automatic: true)
        #expect(await fixture.files.reads.isEmpty)
        #expect(snapshot.olderAwaitsUser)

        snapshot = await fixture.loadOlder(engine)
        #expect(snapshot.transcript.turns.map(\.firstEntryID.rawValue) == ["p-\(first.utf8.count)"])
        #expect(!snapshot.olderAwaitsUser)

        snapshot = await fixture.loadOlder(engine, automatic: true)
        #expect(Self.numbers(snapshot).first == "p-0")
        #expect(snapshot.older == .reachedStart)
    }

    /// Once a bounded request leaves earlier messages to the user, a fresh
    /// tail lets Chat load by itself again: here the program rewrites the
    /// file shorter, keeping its start, and the poll reloads it.
    @Test func aFreshTailLetsAutomaticRequestsReadAgain() async throws {
        var limits = Self.limits
        limits.automaticOlderSearch = 96
        let fixture = Fixture(limits: limits)
        let first = NumberedChatReducer.prompt("a") + Self.lines(0..<6) + NumberedChatReducer.turnEnd
        func text(silent: Int) -> String {
            first + NumberedChatReducer.prompt("b") + String(repeating: NumberedChatReducer.end("none"), count: silent)
                + Self.lines(6..<10)
        }
        await fixture.files.write(text(silent: 40), at: Self.claudePath)
        let engine = fixture.makeEngine()
        _ = await fixture.open(engine)
        var snapshot = await fixture.loadOlder(engine, automatic: true)
        try #require(snapshot.olderAwaitsUser)

        await fixture.files.write(text(silent: 20), at: Self.claudePath)
        snapshot = await fixture.poll(engine)
        #expect(!snapshot.olderAwaitsUser)

        await fixture.files.clearRecords()
        snapshot = await fixture.loadOlder(engine, automatic: true)
        #expect(await fixture.bytesRead() > 0)
    }

    /// A program that doesn't bound what Chat loads by itself passes the
    /// follower no limit, so the timeline's request reads back past a line
    /// longer than the largest page to the opener above it, as the user's
    /// does. A limit there would stop every pass at that line without
    /// moving the window; the read budget fails such a loop instead of
    /// letting it hang.
    @Test func automaticRequestsReadPastALineLongerThanAPage() async throws {
        try #require(Self.limits.automaticOlderSearch == nil)
        // 201 bytes, more than the 128-byte largest page, just above the
        // tail window.
        let long = #"{"pad":""# + String(repeating: "x", count: 190) + "\"}\n"
        let text = NumberedChatReducer.prompt("a") + Self.lines(0..<2) + long + Self.lines(2..<8)
        let automatic = Fixture()
        let user = Fixture()
        await automatic.files.write(text, at: Self.claudePath)
        await user.files.write(text, at: Self.claudePath)
        let byItself = automatic.makeEngine()
        let asked = user.makeEngine()
        let opened = await automatic.open(byItself)
        _ = await user.open(asked)
        try #require(Self.numbers(opened) == Self.ids(2..<8))
        await automatic.files.clearRecords()
        await user.files.clearRecords()
        // Several times what the request reads.
        await automatic.files.setReadBudget(64)

        let snapshot = await automatic.loadOlder(byItself, automatic: true)
        let expected = await user.loadOlder(asked)

        #expect(
            snapshot.transcript.turns.map(\.firstEntryID.rawValue) == ["p-0"],
            "\(String(describing: snapshot.readFailure))")
        #expect(Self.numbers(snapshot) == Self.numbers(expected))
        #expect(snapshot.transcript.turns == expected.transcript.turns)
        #expect(snapshot.older == expected.older)
        #expect(!snapshot.olderAwaitsUser)
        let userReads = await user.files.reads
        #expect(await automatic.files.reads == userReads)
    }

    @Test func turnsOpenedAboveALaterWindowComeFromTheSavedDocument() async throws {
        let fixture = Fixture()
        await fixture.files.write(NumberedChatReducer.prompt("a") + Self.lines(0..<6), at: Self.claudePath)
        let first = fixture.makeEngine()
        var snapshot = await fixture.open(first)
        var pages = 0
        while snapshot.older == .available, pages < 50 {
            snapshot = await fixture.loadOlder(first)
            pages += 1
        }
        #expect(snapshot.transcript.turns.map(\.firstEntryID.rawValue) == ["p-0"])
        await first.save(force: true)

        // Reopened once the first prompt is above the tail window, which
        // holds the end of its turn.
        await fixture.files.append(NumberedChatReducer.turnEnd, to: Self.claudePath)
        let second = UInt64(await fixture.files.contents(of: Self.claudePath)?.count ?? 0)
        await fixture.files.append(NumberedChatReducer.prompt("b") + Self.lines(8..<10), to: Self.claudePath)
        let reopened = fixture.makeEngine()
        let restored = await reopened.restore()
        #expect(restored.transcript.turns.map(\.firstEntryID.rawValue) == ["p-0"])
        snapshot = await fixture.open(reopened)

        #expect(snapshot.older == .reachedStart)
        #expect(snapshot.transcript.turns.map(\.firstEntryID.rawValue) == ["p-0", "p-\(second)"])
        #expect(snapshot.transcript.turns.map(\.ending) == [.completed, nil])
        // The window's end closes a saved turn, not the rows above it.
        #expect(snapshot.transcript.precedingTurnEnd == nil)
    }

    /// Saved rows above a later window that open no turn belong to the
    /// turn the window opens inside, which the window's end still closes.
    @Test func savedRowsAboveALaterWindowKeepTheEndOfTheirTurn() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<6), at: Self.claudePath)
        let first = fixture.makeEngine()
        let opened = await fixture.open(first)
        try #require(opened.older == .reachedStart)
        await first.save(force: true)

        await fixture.files.append(
            NumberedChatReducer.turnEnd + NumberedChatReducer.prompt("b") + Self.lines(8..<10), to: Self.claudePath)
        let reopened = fixture.makeEngine()
        _ = await reopened.restore()
        let snapshot = await fixture.open(reopened)

        // The tail window starts at the last saved row; the rest fill in.
        #expect(snapshot.transcript.needsOlderHistory)
        #expect(snapshot.older == .reachedStart)
        #expect(Self.numbers(snapshot).prefix(6) == ArraySlice(Self.ids(0..<6)))
        #expect(snapshot.transcript.turns.count == 1)
        #expect(snapshot.transcript.precedingTurnEnd == ChatTurnEnd(ending: .completed))
    }

    /// With Claude Code's limits, a request the list makes by itself reads
    /// saved rows the Host sends again as the user's does: above more than
    /// 4 MiB of short turns kept from an earlier visit, it reads on to the
    /// next turn's prompt.
    @Test func automaticRequestsReadPastSavedRowsAboveALaterWindow() async throws {
        let claude = try #require(ChatTranscriptAdapter.standard(for: .claude))
        try #require(claude.joinsCachedHistory)
        let fixture = Fixture(limits: claude.limits)
        // A 64 KiB line no program reads.
        let filler = String(repeating: "x", count: (64 << 10) - 1) + "\n"
        func turn(_ name: String, kib: Int) -> String {
            NumberedChatReducer.prompt(name) + String(repeating: filler, count: kib / 64) + NumberedChatReducer.turnEnd
        }
        let early = turn("a", kib: 2_048)
        await fixture.files.write(early + (0..<8).map { turn("b\($0)", kib: 768) }.joined(), at: Self.claudePath)
        let first = fixture.makeEngine()
        var snapshot = await fixture.open(first)
        let oldestSaved = ChatEntryID("p-\(early.utf8.count)")
        var pages = 0
        while snapshot.transcript.turns.first?.firstEntryID != oldestSaved, pages < 20 {
            snapshot = await fixture.loadOlder(first)
            pages += 1
        }
        try #require(snapshot.transcript.turns.first?.firstEntryID == oldestSaved)
        await first.save(force: true)
        let saved = try #require(await fixture.savedDocument())

        // Reopened one short turn later: the saved rows fill in above the
        // tail window.
        await fixture.files.append(turn("c", kib: 256), to: Self.claudePath)
        let size = UInt64(await fixture.files.contents(of: Self.claudePath)?.count ?? 0)
        try #require(size - UInt64(claude.limits.tailWindow) - saved.coverageStart > 4 << 20)
        let reopened = fixture.makeEngine()
        _ = await reopened.restore()
        snapshot = await fixture.open(reopened)
        try #require(snapshot.transcript.turns.first?.firstEntryID == oldestSaved)
        try #require(snapshot.older == .available)

        snapshot = await fixture.loadOlder(reopened, automatic: true)

        #expect(snapshot.transcript.turns.first?.firstEntryID == ChatEntryID("p-0"))
        #expect(!snapshot.olderAwaitsUser)
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
        #expect(restored.readOffset == Self.offset(of: 3))
        #expect(Self.numbers(restored) == Self.ids(0..<3))
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
    }

    @Test func restoringBackgroundWorkKeepsTheOfflineTranscriptComplete() async throws {
        let fixture = Fixture(limits: TranscriptFollower.Limits())
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: Self.start)
        await fixture.files.write(Self.lines(0..<3) + launch, at: Self.claudePath)
        let first = fixture.makeEngine()
        let original = await fixture.open(first)
        await first.save()
        let reopened = fixture.makeEngine()

        let restored = await reopened.restore()

        #expect(restored.isFromCache)
        #expect(restored.transcript.listedBackgroundWork == original.transcript.listedBackgroundWork)
        #expect(restored.transcript.listedBackgroundWork.map(\.id) == ["s1"])
        #expect(restored.readOffset == original.readOffset)
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

    @Test("A waiting bubble shows but is never saved, so a later window cannot bring it back")
    func unrecordedEntriesAreNotSaved() async throws {
        let fixture = Fixture()
        await fixture.files.write(Self.lines(0..<3) + NumberedChatReducer.waiting("later"), at: Self.claudePath)
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)
        let bubble = "w-\(Self.offset(of: 3))"
        #expect(Self.numbers(opened) == Self.ids(0..<3) + [bubble])

        await engine.save(force: true)

        #expect(await fixture.savedDocument()?.entries.map(\.id.rawValue) == Self.ids(0..<3))
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

    // MARK: Sources read by query

    private static let recordSession = "s1"
    private static let recordPath = "memory:s1"

    /// Host files that hold nothing and count every call made through them.
    private actor HostFileCalls {
        private(set) var count = 0

        private func record() {
            count += 1
        }

        nonisolated var files: ChatHostFiles {
            ChatHostFiles(
                status: { _ in
                    await self.record()
                    return nil
                },
                list: { _ in
                    await self.record()
                    return nil
                },
                read: { _ in
                    await self.record()
                    return RemoteFileSlice(data: Data(), length: nil)
                },
                home: {
                    await self.record()
                    return "/home/dev"
                })
        }
    }

    /// A conversation its adapter reads by query from an in-memory store.
    private struct RecordFixture {
        let store = InMemoryRecordSource.Store()
        let hostFiles = HostFileCalls()
        let cache = VolatileChatTranscriptCache()
        let program: ChatProgram
        let limits: InMemoryRecordSource.Limits
        let wantsFirstLine: Bool

        init(
            program: ChatProgram = .claude, limits: InMemoryRecordSource.Limits = InMemoryRecordSource.Limits(),
            wantsFirstLine: Bool = false
        ) {
            self.program = program
            self.limits = limits
            self.wantsFirstLine = wantsFirstLine
        }

        var key: ChatCacheKey {
            ChatCacheKey(hostID: host, herdrSession: "", program: program, conversationID: recordSession)
        }

        func makeEngine() -> ChatConversationEngine {
            ChatConversationEngine(
                reference: ConversationReference(program: program, sessionID: recordSession),
                cacheKey: key, files: hostFiles.files, cache: cache,
                adapter: InMemoryRecordSource.adapter(
                    store, sessionID: recordSession, limits: limits, wantsFirstLine: wantsFirstLine),
                now: { start })
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
    }

    @Test func aRecordSourceOpensWithoutLookingForAFile() async throws {
        // Codex relocates by looking for its rollout again, and wants the
        // file's first line under a window that starts past it.
        let fixture = RecordFixture(program: .codex, wantsFirstLine: true)
        await fixture.store.write(Self.lines(0..<30))
        let engine = fixture.makeEngine()

        let opened = await fixture.open(engine)

        #expect(opened.phase == .following(path: Self.recordPath))
        #expect(opened.older == .available)
        #expect(Self.numbers(opened).last == "n-29")
        // The reducer was seeded without a first line.
        #expect(opened.transcript.title == nil)

        await fixture.store.append(Self.lines(30..<31))
        let relocated = await engine.relocate(context: ChatProjectionContext(activity: .idle))

        #expect(relocated.phase == .following(path: Self.recordPath))
        #expect(Self.numbers(relocated).last == "n-30")
        #expect(await fixture.store.calls == [.open, .poll])
        #expect(await fixture.hostFiles.count == 0)
    }

    /// An id the adapter makes no source for is no session to read, in the
    /// program's own terms; nothing is asked of the store or the files.
    @Test func anIDWithoutASourceIsUnidentifiedForItsProgram() async throws {
        let fixture = RecordFixture(program: .opencode)
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: "s2"),
            cacheKey: fixture.key, files: fixture.hostFiles.files, cache: fixture.cache,
            adapter: InMemoryRecordSource.adapter(fixture.store, sessionID: Self.recordSession), now: { Self.start })

        let opened = await fixture.open(engine)

        #expect(opened.phase == .unavailable(.unidentifiedSession(.opencode)))
        #expect(await fixture.store.calls.isEmpty)
        #expect(await fixture.hostFiles.count == 0)
    }

    @Test func aRecordSourcePollAppendsResetsAndReopensWhenMissing() async throws {
        let fixture = RecordFixture()
        await fixture.store.write(Self.lines(0..<3))
        let engine = fixture.makeEngine()
        #expect(Self.numbers(await fixture.open(engine)) == Self.ids(0..<3))

        await fixture.store.append(Self.lines(3..<5))
        let appended = await fixture.poll(engine)

        #expect(Self.numbers(appended) == Self.ids(0..<5))
        #expect(appended.readOffset == Self.offset(of: 5))
        #expect(await fixture.poll(engine).revision == appended.revision)

        // The store replaced its records: the source starts over, and so
        // does the engine.
        await fixture.store.write(Self.lines(7..<9))
        let reset = await fixture.poll(engine)

        #expect(Self.numbers(reset) == Self.ids(7..<9))
        #expect(reset.layoutGeneration > appended.layoutGeneration)

        // The session is gone: the engine opens a new source at once, which
        // finds nothing, and keeps what shows.
        await fixture.store.setMissing(true)
        let missing = await fixture.poll(engine)

        #expect(missing.phase == .unavailable(.notFound(searchedAll: true)))
        #expect(missing.isFromCache)
        #expect(Self.numbers(missing) == Self.ids(7..<9))

        // It comes back: opening again follows it.
        await fixture.store.setMissing(false)
        await fixture.store.append(Self.lines(9..<10))
        let reopened = await fixture.open(engine)

        #expect(reopened.phase == .following(path: Self.recordPath))
        #expect(Self.numbers(reopened) == Self.ids(7..<10))
        #expect(await fixture.store.calls == [.open, .poll, .poll, .poll, .poll, .open, .open])
        #expect(await fixture.hostFiles.count == 0)
    }

    @Test func anUnreadableRecordSourceStopsWithItsReason() async throws {
        let reason = ChatUnavailableReason.unsupportedFormat("probe")
        let fixture = RecordFixture()
        await fixture.store.write(Self.lines(0..<30))
        let engine = fixture.makeEngine()

        // On opening, nothing shows.
        await fixture.store.failNext(with: ChatSourceUnavailable(reason: reason))
        let refused = await fixture.open(engine)

        #expect(refused.phase == .unavailable(reason))
        #expect(refused.readFailure == nil)
        #expect(refused.transcript.entries.isEmpty)

        // On a poll, what showed stays.
        let opened = await fixture.open(engine)
        #expect(opened.phase == .following(path: Self.recordPath))
        await fixture.store.failNext(with: ChatSourceUnavailable(reason: reason))
        let stopped = await fixture.poll(engine)

        #expect(stopped.phase == .unavailable(reason))
        #expect(stopped.readFailure == nil)
        #expect(stopped.isFromCache)
        #expect(Self.numbers(stopped) == Self.numbers(opened))

        // On a page of older records, nothing is left loading.
        _ = await fixture.open(engine)
        await fixture.store.failNext(with: ChatSourceUnavailable(reason: reason))
        let paged = await fixture.loadOlder(engine)

        #expect(paged.phase == .unavailable(reason))
        #expect(paged.older == .available)

        // Any other error is a read failure, and following goes on.
        _ = await fixture.open(engine)
        await fixture.store.failNext(with: TransportError.hostFileTimedOut)
        let failed = await fixture.poll(engine)

        #expect(failed.phase == .following(path: Self.recordPath))
        #expect(failed.readFailure == .hostFileTimedOut)
    }

    @Test func olderRecordsStopWhenTheSourceSpendsItsSearch() async throws {
        let fixture = RecordFixture(limits: InMemoryRecordSource.Limits(olderSearch: 256))
        // Records that show nothing, many pages of them, inside one turn.
        let silent = String(repeating: NumberedChatReducer.end("none"), count: 40)
        await fixture.store.write(Self.lines(0..<3) + silent + Self.lines(3..<6))
        let engine = fixture.makeEngine()
        let opened = Self.numbers(await fixture.open(engine))

        let snapshot = await fixture.loadOlder(engine)

        // Pages double up to the source's largest, until the request has
        // read back as far as one may.
        #expect(Self.numbers(snapshot) == opened)
        #expect(snapshot.older == .available)
        #expect(await fixture.store.olderLengths == [32, 64, 128, 128])

        // The next request searches as far again.
        _ = await fixture.loadOlder(engine)

        #expect(await fixture.store.olderLengths == [32, 64, 128, 128, 32, 64, 128, 128])
    }

    @Test func anExpandedOutputIsReadThroughTheSource() async throws {
        let fixture = RecordFixture()
        await fixture.store.write(Self.lines(0..<2) + NumberedChatReducer.tool(1, output: "line 1\nline 2"))
        let engine = fixture.makeEngine()
        let opened = await fixture.open(engine)
        guard case .tool(let row)? = opened.transcript.entries.last?.content else {
            Issue.record("expected the tool row")
            return
        }
        let reference = try #require(row.output)

        let result = await engine.output(of: row)

        #expect(result == .success(ChatExpandedOutput(preview: ChatToolPreview(text: "line 1\nline 2", isTruncated: false))))
        #expect(await fixture.store.calls.last == .line(reference))

        // A line longer than the fetch cap is never asked for.
        var long = row
        long.output?.length = ChatToolPreview.maximumFetchBytes + 1
        #expect(await engine.output(of: long) == .failure(.tooLong))
        #expect(await fixture.store.calls.last == .line(reference))

        // A source can find a line too long only once it reads it.
        await fixture.store.failNext(with: ChatToolOutputFailure.tooLong)
        #expect(await engine.output(of: row) == .failure(.tooLong))

        // The store no longer holds the line.
        await fixture.store.write(Self.lines(0..<3))
        #expect(await engine.output(of: row) == .failure(.gone))
        #expect(await fixture.hostFiles.count == 0)
    }

    @Test func aRecordSourceIsSavedUnderItsHeadAndWindow() async throws {
        let fixture = RecordFixture()
        await fixture.store.write(Self.lines(0..<30))
        let first = fixture.makeEngine()
        let opened = await fixture.open(first)

        await first.save(force: true)

        let saved = try #require(await fixture.savedDocument())
        #expect(saved.transcriptPath == Self.recordPath)
        #expect(saved.head == Data(Self.recordSession.utf8))
        #expect(saved.coverageStart == opened.transcript.entries.first?.sourceOffset)
        #expect(saved.coverageEnd == opened.readOffset)
        #expect(!saved.reachedStart)

        // The next visit's source names the same conversation, so the saved
        // entries fill in above its later window.
        await fixture.store.append(Self.lines(30..<32))
        let second = fixture.makeEngine()
        #expect(await second.restore().isFromCache)
        let snapshot = await fixture.open(second)

        #expect(snapshot.phase == .following(path: Self.recordPath))
        #expect(Self.numbers(snapshot) == Self.numbers(opened) + Self.ids(30..<32))
        #expect(await fixture.savedDocument() != nil)
    }

    // MARK: OpenCode

    /// A scratch OpenCode store, queried the way a Host's is.
    private actor OpenCodeStore {
        private let harness: OpenCodeSQLiteHarness

        init(scenario: String) throws {
            harness = try OpenCodeSQLiteHarness(scenario: scenario)
        }

        /// Changes the store in one transaction, as OpenCode does.
        func commit(_ sql: String) throws {
            try harness.execute("BEGIN;\n\(sql)\nCOMMIT;")
        }

        func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
            try harness.response(query)
        }

        /// Only queries reach the store: there are no files to read.
        nonisolated var files: ChatHostFiles {
            let none = TransportError.hostFeatureUnavailable(feature: "Files")
            return ChatHostFiles(
                status: { _ in throw none }, list: { _ in throw none }, read: { _ in throw none },
                home: { throw none }, queryOpenCode: { try await self.response($0) })
        }
    }

    @Test func anOpenCodeConversationFollowsThroughItsStore() async throws {
        let id = "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9"
        let store = try OpenCodeStore(scenario: "pong")
        let context = ChatProjectionContext(activity: .idle)
        func makeEngine() -> ChatConversationEngine {
            ChatConversationEngine(
                reference: ConversationReference(program: .opencode, sessionID: id),
                cacheKey: ChatCacheKey(hostID: Self.host, herdrSession: "", program: .opencode, conversationID: id),
                files: store.files, cache: VolatileChatTranscriptCache(), adapter: .openCode, now: { Self.start })
        }
        /// What opening the store afresh shows, which following it must
        /// show too.
        func reopened() async -> ChatTranscript {
            await makeEngine().open(directories: [], context: context).transcript
        }
        func texts(_ snapshot: ChatConversationSnapshot) -> [String] {
            snapshot.transcript.entries.compactMap { entry -> String? in
                switch entry.content {
                case .user(let message): message.text
                case .assistant(let message): message.text
                default: nil
                }
            }
        }
        let engine = makeEngine()

        let opened = await engine.open(directories: [], context: context)

        #expect(opened.phase == .following(path: "opencode:\(id)"))
        #expect(opened.transcript.title == "Pong")
        #expect(texts(opened) == ["Reply with exactly the word pong.", "pong"])
        #expect(opened.older == .reachedStart)
        #expect(opened.readOffset == 13)

        // A prompt's row and the counter move together.
        try await store.commit(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
              VALUES ('msg_0a1b2c3d4e40aaaaaaaaaaaaaa', '\(id)', 'user', 13, 1800000020000, 1800000020000,
                      '{"time":{"created":1800000020000},"text":"Once more.","files":[],"agents":[]}');
            UPDATE event_sequence SET seq = 13 WHERE aggregate_id = '\(id)';
            """)
        let appended = await engine.poll(context: context)

        #expect(texts(appended) == ["Reply with exactly the word pong.", "pong", "Once more."])
        #expect(appended.readOffset == 14)
        #expect(appended.layoutGeneration == opened.layoutGeneration)
        let afresh = await reopened()
        #expect(appended.transcript.entries == afresh.entries)
        #expect(appended.transcript.turns == afresh.turns)

        // The counter alone says nothing changed.
        #expect(await engine.poll(context: context).revision == appended.revision)

        // A committed undo deletes the rows from its boundary on while the
        // counter moves on: following starts over.
        try await store.commit(
            """
            DELETE FROM session_message WHERE session_id = '\(id)' AND seq >= 13;
            UPDATE event_sequence SET seq = 15 WHERE aggregate_id = '\(id)';
            """)
        let reset = await engine.poll(context: context)

        #expect(texts(reset) == ["Reply with exactly the word pong.", "pong"])
        #expect(reset.layoutGeneration > appended.layoutGeneration)
        #expect(reset.readOffset == 16)
        let undone = await reopened()
        #expect(reset.transcript.entries == undone.entries)
        #expect(reset.transcript.turns == undone.turns)
    }
}
