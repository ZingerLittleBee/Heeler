import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Chat store")
struct AgentChatStoreTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "5b0c6a51-6a3e-4c55-9d0c-9a2f4f1f0c11"
    private static let cwd = "/home/dev/proj"
    private static let host = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    private static let start = Date(timeIntervalSince1970: 1_791_266_400)

    private static func path(_ session: String) -> String {
        "/home/dev/.claude/projects/-home-dev-proj/\(session).jsonl"
    }

    private static func agent(
        session: String?, status: AgentStatus = .idle, program: ChatProgram = .claude
    ) -> Agent {
        Agent(
            terminalID: "term-1", kind: program.rawValue, title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: session.map {
                AgentSessionInfo(
                    agent: program.rawValue, kind: .id, source: "herdr:\(program.rawValue)", value: $0)
            })
    }

    /// What `agent.get` answers, and how often it was asked.
    private actor Server {
        var agent: Agent
        private(set) var reads = 0
        var failure: TransportError?
        private var shouldSuspend = false
        private var pendingRead: CheckedContinuation<Void, Never>?

        init(_ agent: Agent) {
            self.agent = agent
        }

        func read() async throws -> Agent {
            reads += 1
            let answer = agent
            if shouldSuspend {
                shouldSuspend = false
                await withCheckedContinuation { pendingRead = $0 }
            }
            if let failure { throw failure }
            return answer
        }

        func suspendNextRead() {
            shouldSuspend = true
        }

        func releaseRead() {
            pendingRead?.resume()
            pendingRead = nil
        }

        func fail(with failure: TransportError?) {
            self.failure = failure
        }

        func set(_ agent: Agent) {
            self.agent = agent
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    @MainActor
    private struct Fixture {
        let files = VirtualHostFiles()
        let cache = VolatileChatTranscriptCache()
        let clock = Clock()
        let server: Server
        let store: AgentChatStore

        /// - Parameter adapter: how the conversation is read; nil reads
        ///   `NumberedChatReducer` transcript files.
        init(
            session: String?, program: ChatProgram = .claude,
            limits: TranscriptFollower.Limits = TranscriptFollower.Limits(),
            timing: AgentChatStore.Timing = AgentChatStore.Timing(
                activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
            adapter: ChatTranscriptAdapter? = nil,
            cachedSession: @escaping @Sendable (Agent) async -> AgentSessionInfo? = { _ in nil },
            screen: BlockedScreenIO = .unavailable,
            processInfo: (@Sendable () async throws -> PaneProcessInfo)? = nil
        ) {
            let agent = AgentChatStoreTests.agent(session: session, program: program)
            let server = Server(agent)
            let clock = clock
            self.server = server
            store = AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: AgentChatStoreTests.host, paneID: agent.paneID),
                agent: agent, program: program,
                source: AgentChatSource(
                    hostID: AgentChatStoreTests.host, socketLocation: .defaultSession,
                    files: files.hostFiles(), agentInfo: { try await server.read() }, cache: cache,
                    adapter: adapter ?? NumberedChatReducer.adapter(limits: limits, wantsFirstLine: program == .codex),
                    cachedSession: cachedSession, processInfo: processInfo, screen: screen),
                timing: timing, now: { clock.now })
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }
    }

    private static func ids(_ store: AgentChatStore) -> [String] {
        store.conversation.transcript.entries.map(\.id.rawValue)
    }

    /// A Claude Code or Codex store following lines 0..<2 of its transcript
    /// while herdr reports the Agent idle, with the session and the path.
    private static func followed(
        _ program: ChatProgram, screen: BlockedScreenIO
    ) async -> (fixture: Fixture, session: String, path: String) {
        var session = first
        var transcript = Self.path(first)
        var header = ""
        if program == .codex {
            session = "01a10f87-e025-7fb1-8974-8dd09937767a"
            transcript = "/home/dev/.codex/sessions/2026/10/06/rollout-2026-10-06T12-45-25-\(session).jsonl"
            header = #"{"type":"session_meta","payload":{"id":"\#(session)"}}"# + "\n"
        }
        let fixture = Fixture(session: session, program: program, screen: screen)
        await fixture.files.write(header + NumberedChatReducer.lines(0..<2), at: transcript)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: transcript))
        return (fixture, session, transcript)
    }

    // MARK: Background work

    private static let journal =
        "/home/dev/.claude/projects/-home-dev-proj/\(first)/subagents/workflows/wf_1/journal.jsonl"

    private static func paced() -> Fixture {
        Fixture(
            session: first,
            timing: AgentChatStore.Timing(
                activeInterval: .seconds(1), idleInterval: .seconds(4),
                backgroundWorkStaleness: ChatBackgroundWork.Staleness(workflowQuiet: 7_200, subagentRun: 10_800)))
    }

    @Test func runningBackgroundWorkKeepsTheActivePaceUntilItEnds() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(fixture.store.backgroundWork.isLive)

        // Past the linger after the last change, the running Subagent
        // still holds the active pace.
        fixture.advance(60)
        await fixture.store.step()
        #expect(fixture.store.interval == .seconds(1))

        await fixture.files.append(NumberedChatReducer.end("s1"), to: Self.path(Self.first))
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.map(\.item.state) == [.completed])
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func workRunningLongerThanItCouldIsStaleAndHoldsNothing() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now.addingTimeInterval(-4 * 3_600))
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        fixture.advance(60)
        await fixture.store.step()

        #expect(fixture.store.backgroundWork.rows.map(\.isStale) == [true])
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func aFailedReadFreezesTheListInsteadOfHoldingThePace() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        fixture.advance(60)

        await fixture.files.failNext(.status, with: TransportError.hostFileTimedOut)
        await fixture.store.step()

        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(!fixture.store.backgroundWork.isLive)
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func savedBackgroundWorkShowsOnlyAfterALiveRead() async throws {
        let previous = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: previous.clock.now)
        await previous.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await previous.store.step()
        #expect(previous.store.backgroundWork.rows.map(\.id) == ["s1"])
        let key = ChatCacheKey(hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected a saved conversation")
            return
        }

        let fixture = Self.paced()
        await fixture.cache.save(document)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        await fixture.store.step()

        #expect(fixture.store.conversation.isFromCache)
        #expect(Self.ids(fixture.store) == previous.store.conversation.transcript.entries.map(\.id.rawValue))
        #expect(fixture.store.backgroundWork.rows.isEmpty)

        await fixture.server.fail(with: nil)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        fixture.store.retry()
        await fixture.store.step()
        await fixture.store.step()

        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(fixture.store.backgroundWork.isLive)
    }

    @Test func aWorkflowShowsItsJournalAndTheListResetsWithTheConversation() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("w1", journal: Self.journal, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.files.write(
            #"{"type":"launched"}"# + "\n"
                + #"{"type":"started","key":"k1","agentId":"a1","label":"audit:one","phase":"Audit"}"# + "\n",
            at: Self.journal)
        await fixture.store.step()
        // The first poll after opening reads the journal.
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.first?.progress?.started == 1)

        fixture.store.agentDidChange(Self.agent(session: Self.second))
        #expect(fixture.store.backgroundWork == ChatBackgroundWork())
    }

    // MARK: Pace

    /// Every program that writes a transcript file is read at ADR 0024's
    /// pace: each second while the Agent works or is Blocked and for 15 s
    /// after a change, every 4 s otherwise. A read that timed out changes
    /// neither.
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func fileTranscriptsKeepTheirPace(program: ChatProgram) async throws {
        let adapter = try #require(ChatTranscriptAdapter.standard(for: program))
        let fixture = Fixture(
            session: Self.first, program: program,
            timing: AgentChatStore.Timing(activeInterval: .seconds(1), idleInterval: .seconds(4)),
            adapter: adapter)
        /// One look for the transcript, past any backoff, that times out.
        func timedOutRead() async {
            await fixture.files.failNext(.home, with: TransportError.hostFileTimedOut)
            fixture.advance(31)
            await fixture.store.step()
            #expect(fixture.store.conversation.readFailure == .hostFileTimedOut)
        }

        for status in [AgentStatus.working, .blocked] {
            fixture.store.agentDidChange(Self.agent(session: Self.first, status: status, program: program))
            for _ in 0..<3 {
                await timedOutRead()
                #expect(fixture.store.interval == .seconds(1))
            }
        }
        fixture.store.agentDidChange(Self.agent(session: Self.first, program: program))
        #expect(fixture.store.interval == .seconds(1))
        fixture.advance(16)
        #expect(fixture.store.interval == .seconds(4))
        for _ in 0..<3 {
            await timedOutRead()
            #expect(fixture.store.interval == .seconds(4))
        }
    }

    private static let openCodeSession = "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9"

    /// An OpenCode Agent's store whose conversation `records` holds, read
    /// by query, at the default paces.
    private static func queried(_ records: InMemoryRecordSource.Store) -> Fixture {
        Fixture(
            session: openCodeSession, program: .opencode,
            timing: AgentChatStore.Timing(
                activeInterval: .seconds(1), idleInterval: .seconds(4),
                backgroundWorkStaleness: ChatBackgroundWork.Staleness(workflowQuiet: 7_200, subagentRun: 10_800)),
            adapter: InMemoryRecordSource.adapter(records, sessionID: openCodeSession))
    }

    /// Each read of a conversation read by query is an exec on the Host,
    /// so every active arm keeps a pace of its own (ADR 0025).
    @Test func aQueriedConversationLingersAtItsOwnPace() async throws {
        let records = InMemoryRecordSource.Store()
        await records.write(NumberedChatReducer.lines(0..<2))
        let fixture = Self.queried(records)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: "memory:\(Self.openCodeSession)"))

        for status in [AgentStatus.working, .blocked] {
            fixture.store.agentDidChange(Self.agent(session: Self.openCodeSession, status: status, program: .opencode))
            #expect(fixture.store.interval == .seconds(2))
        }
        fixture.store.agentDidChange(Self.agent(session: Self.openCodeSession, program: .opencode))
        #expect(fixture.store.interval == .seconds(2))
        fixture.advance(16)
        #expect(fixture.store.interval == .seconds(4))

        // Work the program still runs in the background holds the pace.
        await records.append(NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now))
        await fixture.store.step()
        fixture.advance(16)
        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(fixture.store.interval == .seconds(2))
    }

    /// A query past its deadline holds the Host's query lane until its
    /// watchdog ends it, so each timeout in a row doubles the pause.
    @Test func aTimedOutQueryBacksOffUntilAReadWorks() async throws {
        let records = InMemoryRecordSource.Store()
        await records.write(NumberedChatReducer.lines(0..<2))
        let fixture = Self.queried(records)
        fixture.store.agentDidChange(Self.agent(session: Self.openCodeSession, status: .working, program: .opencode))
        await fixture.store.step()
        var intervals = [fixture.store.interval]

        for _ in 0..<5 {
            await records.failNext(with: TransportError.hostFileTimedOut)
            await fixture.store.step()
            #expect(fixture.store.conversation.readFailure == .hostFileTimedOut)
            intervals.append(fixture.store.interval)
        }

        #expect(intervals == [2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })

        // Another failure is no timeout in a row, nor a read that worked.
        await records.failNext(with: TransportError.hostStoreUnreadable(detail: "OpenCode's database is busy."))
        await fixture.store.step()
        #expect(fixture.store.interval == .seconds(30))

        await fixture.store.step()
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(fixture.store.interval == .seconds(2))
    }

    /// A problem only the user can fix is not looked at again until Retry
    /// or a change to the Agent; a closed store is, after the usual wait.
    @Test func storeProblemsThatCannotFixThemselvesWaitForRetry() async throws {
        let records = InMemoryRecordSource.Store()
        await records.write(NumberedChatReducer.lines(0..<2))
        let fixture = Self.queried(records)
        let following = ChatConversationSnapshot.Phase.following(path: "memory:\(Self.openCodeSession)")
        func unavailable(_ problem: ChatSessionStoreProblem) -> ChatSourceUnavailable {
            ChatSourceUnavailable(reason: .sessionStore(.opencode, problem))
        }
        func opens() async -> Int {
            await records.calls.filter { $0 == .open }.count
        }

        await records.failNext(with: unavailable(.noReader))
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.sessionStore(.opencode, .noReader)))
        fixture.advance(120)
        await fixture.store.step()
        #expect(await opens() == 1)

        fixture.store.retry()
        await fixture.store.step()
        #expect(await opens() == 2)
        #expect(fixture.store.conversation.phase == following)

        // The poll finds the store closed, and so does the open right after.
        await records.failNext(with: unavailable(.storeClosed))
        await records.failNext(with: unavailable(.storeClosed))
        await fixture.store.step()
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.sessionStore(.opencode, .storeClosed)))
        await fixture.store.step()
        #expect(await opens() == 3)
        fixture.advance(2)
        await fixture.store.step()
        #expect(await opens() == 4)
        #expect(fixture.store.conversation.phase == following)

        await records.failNext(with: unavailable(.subagentSession))
        await records.failNext(with: unavailable(.subagentSession))
        await fixture.store.step()
        await fixture.store.step()
        fixture.advance(120)
        await fixture.store.step()
        #expect(await opens() == 5)

        fixture.store.agentDidChange(Self.agent(session: Self.openCodeSession, status: .working, program: .opencode))
        await fixture.store.step()
        #expect(await opens() == 6)
        #expect(fixture.store.conversation.phase == following)
    }

    @Test func followsTheSessionHerdrReports() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.server.reads == 1)
    }

    @Test func noSessionIsExplainedWithoutReadingTheHost() async throws {
        let fixture = Fixture(session: nil)

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.statuses.isEmpty)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test(arguments: [ChatProgram.claude, .codex, .grok])
    func missingSessionExplainsTheMissingIdentityWithoutAnInstallDiagnosis(program: ChatProgram) {
        let reason = ChatUnavailableReason.noSession(program)
        #expect(reason.title == "Waiting for Conversation")
        #expect(reason.explanation.contains("report"))
        #expect(!reason.explanation.lowercased().contains("install"))
        #expect(reason.offersRetry)
    }

    @Test(arguments: [true, false])
    func aMissingTranscriptBannerClaimsSavedMessagesOnlyWhenThereAreSome(showingSaved: Bool) {
        let text = ChatUnavailableReason.notFound(searchedAll: true)
            .bannerText(showingSavedMessages: showingSaved)
        #expect(text.contains("Showing saved messages") == showingSaved)
        #expect(text.contains("any more") == showingSaved)
    }

    private static func snapshot(
        _ phase: ChatConversationSnapshot.Phase, entries: [ChatEntry] = []
    ) -> ChatConversationSnapshot {
        var snapshot = ChatConversationSnapshot(phase: phase)
        snapshot.transcript.entries = entries
        return snapshot
    }

    private static let savedEntry = ChatEntry(
        id: ChatEntryID("e0"), sourceOffset: 0, content: .assistant(ChatAssistantMessage(text: "hello")))

    /// A first prompt sent before Chat finds the transcript: the timeline
    /// holds only the echo, and nothing is saved.
    @Test func aBannerOverOnlyASentEchoDoesNotClaimSavedMessages() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: Self.snapshot(.unavailable(.notFound(searchedAll: true))),
            hasPendingEchoes: true)
        #expect(lines == [.unavailable(.notFound(searchedAll: true), showingSavedMessages: false)])
        #expect(lines.map(\.text) == ["Heeler hasn't found this conversation's transcript yet."])
    }

    @Test func aBannerOverKeptEntriesSaysTheyAreSaved() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected,
            conversation: Self.snapshot(.unavailable(.notFound(searchedAll: true)), entries: [Self.savedEntry]),
            hasPendingEchoes: false)
        #expect(lines.map(\.text) == ["The transcript isn't on the Host any more. Showing saved messages."])
    }

    @Test(arguments: [EventsSessionStatus?.none, .suspended])
    func aNotConnectedBannerClaimsSavedMessagesOnlyWhenThereAreSome(status: EventsSessionStatus?) {
        let saved = ChatBannerLine.lines(
            hostStatus: status, conversation: Self.snapshot(.locating, entries: [Self.savedEntry]),
            hasPendingEchoes: false)
        #expect(saved.map(\.text) == ["Not connected. Showing saved messages."])
        for conversation in [nil, Self.snapshot(.locating)] {
            let lines = ChatBannerLine.lines(hostStatus: status, conversation: conversation, hasPendingEchoes: true)
            #expect(lines.map(\.text) == ["Not connected."])
        }
    }

    /// The Host is retried, but the rows on screen are what this device
    /// kept, so the banner says so while it keeps its progress.
    @Test(arguments: [
        EventsSessionStatus.connecting, .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
    ])
    func aConnectingBannerSaysWhenItShowsSavedMessages(status: EventsSessionStatus) {
        let saved = ChatBannerLine.lines(
            hostStatus: status, conversation: Self.snapshot(.locating, entries: [Self.savedEntry]),
            hasPendingEchoes: false)
        #expect(saved == [.connecting(showingSavedMessages: true)])
        #expect(saved.map(\.text) == ["Connecting to the Host… Showing saved messages."])
        #expect(saved.map(\.showsProgress) == [true])
        for conversation in [nil, Self.snapshot(.locating)] {
            let lines = ChatBannerLine.lines(hostStatus: status, conversation: conversation, hasPendingEchoes: true)
            #expect(lines.map(\.text) == ["Connecting to the Host…"])
        }
    }

    private static func makeUnreachable(_ fixture: Fixture) async {
        let unreachable = TransportError.sshUnreachable(detail: "offline")
        await fixture.server.fail(with: unreachable)
        for operation in [VirtualHostFiles.Operation.status, .list, .read, .home] {
            await fixture.files.failNext(operation, with: unreachable, count: 20)
        }
    }

    /// An offline Host's Agent this device never read: nothing searches for
    /// the transcript, so Chat says it waits for the Host rather than
    /// showing a search that never ends.
    @Test func anUnreachableHostWithNothingSavedWaitsForTheHost() async throws {
        let fixture = Fixture(session: Self.first)
        await Self.makeUnreachable(fixture)

        await fixture.store.step()
        await fixture.store.step()

        let conversation = fixture.store.conversation
        #expect(conversation.phase == .locating)
        #expect(conversation.transcript.entries.isEmpty)
        #expect(
            ChatSurfacePresentation(conversation: conversation, hasPendingEchoes: false, isHostConnected: false)
                == .awaitingHost)
        #expect(
            ChatSurfacePresentation(conversation: conversation, hasPendingEchoes: false, isHostConnected: true)
                == .locating)
    }

    @Test func anUnreachableHostShowsWhatTheDeviceSaved() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await Self.makeUnreachable(fixture)

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(
            ChatSurfacePresentation(
                conversation: fixture.store.conversation, hasPendingEchoes: false, isHostConnected: false)
                == .timeline)
    }

    @Test func messagesSentFromHereShowWhileTheHostIsAway() {
        #expect(
            ChatSurfacePresentation(conversation: nil, hasPendingEchoes: false, isHostConnected: false)
                == .disconnected)
        #expect(
            ChatSurfacePresentation(conversation: Self.snapshot(.locating), hasPendingEchoes: true, isHostConnected: false)
                == .timeline)
    }

    /// With nothing to show, the unavailable view explains instead.
    @Test func noUnavailableBannerWithoutATimeline() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: Self.snapshot(.unavailable(.mismatched)), hasPendingEchoes: false)
        #expect(lines.isEmpty)
    }

    /// A file under the session's name was read and holds another
    /// conversation, so Heeler did find it: the banner says what the
    /// unavailable view says, not that nothing was found yet.
    @Test(arguments: [true, false])
    func aMismatchedTranscriptBannerSaysItHoldsAnotherConversation(showingSaved: Bool) {
        let text = ChatUnavailableReason.mismatched.bannerText(showingSavedMessages: showingSaved)
        #expect(text.hasPrefix(ChatUnavailableReason.mismatched.explanation))
        #expect(text.contains("Showing saved messages") == showingSaved)
        #expect(!text.contains("hasn't found"))
    }

    @Test func aFailedSessionQueryIsVisibleAndRetryClearsItWithoutReadingFiles() async throws {
        let fixture = Fixture(session: nil)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.reads.isEmpty)

        await fixture.server.fail(with: nil)
        fixture.store.retry()
        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == nil)
        #expect(await fixture.server.reads == 2)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test func aFailedSessionQueryKeepsMessagesAndRetriesWhileFollowing() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        fixture.store.retry()

        await fixture.store.step()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))
        #expect(await fixture.server.reads == 2)

        await fixture.server.fail(with: nil)
        fixture.advance(5)
        await fixture.store.step()

        #expect(await fixture.server.reads == 3)
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
    }

    @Test func aFailedSessionQueryKeepsRestoredMessagesWhenTheTranscriptIsMissing() async throws {
        let previous = Fixture(session: Self.first)
        await previous.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await previous.store.step()
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected a saved conversation")
            return
        }
        let fixture = Fixture(session: Self.first)
        await fixture.cache.save(document)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))

        await fixture.server.fail(with: nil)
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.readFailure == nil)
    }

    private static func seedCache(_ fixture: Fixture, session: String, numbers: Range<Int>) async throws {
        let previous = Fixture(session: session)
        await previous.files.write(NumberedChatReducer.lines(numbers), at: path(session))
        await previous.store.step()
        let key = ChatCacheKey(hostID: host, herdrSession: "", program: .claude, conversationID: session)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected the first transcript read to be saved immediately")
            return
        }
        await fixture.cache.save(document)
    }

    @Test func cachedMessagesShowWhileTheFirstAgentQueryIsStillWaiting() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .locating)
        #expect(await fixture.files.reads.isEmpty)
        let generation = fixture.store.conversationGeneration
        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
        await fixture.files.append(NumberedChatReducer.lines(4..<5), to: Self.path(Self.first))
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<5))
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func anInitiallyMissingLiveSessionRestoresTheLocalBindingBeforeTheHostAnswers() async throws {
        let binding = Self.agent(session: Self.first).agentSession
        let fixture = Fixture(session: nil, cachedSession: { _ in binding })
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(fixture.store.conversation.isFromCache)
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        let generation = fixture.store.conversationGeneration
        await fixture.server.releaseRead()
        await step.value

        // The Host still reports nil. The old remote file must remain unread.
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        await fixture.server.set(Self.agent(session: Self.first))
        fixture.store.retry()
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func aNewExplicitSessionReplacesTheInitiallyInferredCacheBinding() async throws {
        let binding = Self.agent(session: Self.first).agentSession
        let fixture = Fixture(session: nil, cachedSession: { _ in binding })
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.set(Self.agent(session: Self.second))

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversationGeneration == 2)
    }

    @Test func refreshedSessionRestoresOnlyItsOwnCachedMessages() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.files.failNext(.home, with: TransportError.hostFileTimedOut)

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversation.isFromCache)
    }

    @Test(arguments: [false, true])
    func anUnreportedSessionKeepsCachedMessagesUntilTheSameBindingReturns(viaSnapshot: Bool) async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.set(Self.agent(session: nil))
        let generation = fixture.store.conversationGeneration

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(fixture.store.conversation.isFromCache)
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        #expect(fixture.store.conversationGeneration == generation)

        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.set(Self.agent(session: Self.first))
        if viaSnapshot { fixture.store.agentDidChange(Self.agent(session: Self.first)) }
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func aSnapshotWithoutSessionStopsReadingTheOldFileUntilAnExplicitBinding() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        let generation = fixture.store.conversationGeneration
        fixture.store.agentDidChange(Self.agent(session: nil))
        await fixture.server.set(Self.agent(session: nil))
        await fixture.files.clearRecords()
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        #expect(fixture.store.conversationGeneration == generation)

        fixture.store.agentDidChange(Self.agent(session: Self.second))
        #expect(fixture.store.conversation.transcript.entries.isEmpty)
        #expect(fixture.store.conversationGeneration == generation + 1)
        await fixture.files.write(NumberedChatReducer.lines(10..<12), at: Self.path(Self.second))
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
    }

    @Test(arguments: ["terminal", "workspace", "tab", "kind", "pane"], [false, true])
    func aReplacementAgentWithoutSessionDoesNotInheritThePreviousCache(
        changed: String, queried: Bool
    ) async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        let replacement = Agent(
            terminalID: changed == "terminal" ? "term-2" : "term-1",
            kind: changed == "kind" ? "codex" : "claude", title: "", status: .idle,
            workspaceID: changed == "workspace" ? "w2" : "w1",
            tabID: changed == "tab" ? "t2" : "t1",
            paneID: changed == "pane" ? "w1:p2" : "w1:p1", cwd: Self.cwd, revision: 2)
        await fixture.server.set(replacement)
        if queried {
            fixture.store.retry()
            await fixture.store.step()
        } else {
            fixture.store.agentDidChange(replacement)
        }

        #expect(fixture.store.conversation.transcript.entries.isEmpty)
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
    }

    @Test func aSessionQueryCannotOverwriteANewerConsoleSession() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        let generation = fixture.store.conversationGeneration
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func cancellingAWaitingRefreshKeepsTheCacheAndSkipsRemoteFileReads() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }
        let generation = fixture.store.conversationGeneration
        step.cancel()
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversationGeneration == generation)
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test func sessionQueryRecoveryDoesNotHideATranscriptFailure() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        fixture.store.retry()
        await fixture.store.step()
        await fixture.server.fail(with: nil)
        await fixture.files.failNext(.status, with: TransportError.hostFileTimedOut)
        fixture.store.retry()

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == .hostFileTimedOut)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
    }

    @Test func aCancelledSessionQueryDoesNotShowAReadFailure() async throws {
        let fixture = Fixture(session: nil)
        await fixture.server.fail(with: .cancelled)

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == nil)
    }

    @Test func aSessionThatIsNotAnIDIsExplained() async throws {
        let fixture = Fixture(session: "my-thread-name")

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .unavailable(.unidentifiedSession(.claude)))
    }

    /// OpenCode is never resumed by name: its explanation says what herdr
    /// reported instead, and the other programs keep theirs.
    @Test func aSessionThatIsNotAnOpenCodeIDIsExplainedInItsTerms() async throws {
        let fixture = Fixture(session: "ses_ABC", program: .opencode)

        await fixture.store.step()

        let reason = ChatUnavailableReason.unidentifiedSession(.opencode)
        #expect(fixture.store.conversation.phase == .unavailable(reason))
        #expect(reason.title == "Conversation Not Identified")
        #expect(
            reason.explanation
                == "herdr reports a session name that isn't an OpenCode session id, so Chat can't tell which conversation is this Agent's."
        )
        #expect(!reason.offersRetry)
        for program in [ChatProgram.claude, .codex, .pi, .omp] {
            #expect(
                ChatUnavailableReason.unidentifiedSession(program).explanation
                    == "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own."
            )
        }
    }

    @Test func aStatusChangeAsksHerdrAgainAndFollowsANewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        await fixture.store.step()

        // `/clear` starts a new session; no event says so.
        await fixture.server.set(Self.agent(session: Self.second, status: .working))
        fixture.store.agentDidChange(Self.agent(session: Self.first, status: .working))
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
        #expect(await fixture.server.reads == 2)
    }

    /// Shows Chat without its loop, so the test drives every turn.
    private static func showWithoutLoop(_ store: AgentChatStore) {
        store.show()
        store.suspend()
    }

    // MARK: Launch

    /// What `pane.process_info` answers, and how often it was asked.
    private actor Processes {
        var arguments: [String]
        var failure: TransportError?
        private(set) var reads = 0

        init(_ arguments: [String]) {
            self.arguments = arguments
        }

        func read() throws -> PaneProcessInfo {
            reads += 1
            if let failure { throw failure }
            return PaneProcessInfo(
                paneID: "w1:p1",
                foregroundProcesses: [PaneProcessInfoProcess(name: "codex", pid: 4_242, argv: arguments)])
        }

        func set(_ arguments: [String]) {
            self.arguments = arguments
        }

        func fail(with failure: TransportError?) {
            self.failure = failure
        }

        private var shouldSuspend = false
        private var suspended: CheckedContinuation<Void, Never>?
        private var suspensionWaiter: CheckedContinuation<Void, Never>?

        func suspendNextRead() {
            shouldSuspend = true
        }

        func waitForSuspendedRead() async {
            if suspended != nil { return }
            await withCheckedContinuation { suspensionWaiter = $0 }
        }

        func resumeSuspendedRead() {
            suspended?.resume()
            suspended = nil
        }

        func readSuspending() async throws -> PaneProcessInfo {
            if shouldSuspend {
                shouldSuspend = false
                await withCheckedContinuation { continuation in
                    suspended = continuation
                    suspensionWaiter?.resume()
                    suspensionWaiter = nil
                }
            }
            return try read()
        }
    }

    private static let controlSocket = "/home/dev/.codex/app-server-control/app-server-control.sock"

    private static func launched(
        _ arguments: [String], session: String? = nil, program: ChatProgram = .codex, serverRuns: Bool = true
    ) async -> (fixture: Fixture, processes: Processes) {
        let processes = Processes(arguments)
        let fixture = Fixture(
            session: session, program: program, processInfo: { try await processes.readSuspending() })
        if serverRuns { await fixture.files.write("", at: controlSocket) }
        return (fixture, processes)
    }

    @Test func aCodexOnTheSharedServerExplainsTheWaitInsteadOfAskingForAPrompt() async {
        let (fixture, processes) = await Self.launched(["codex"])
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()

        #expect(await processes.reads == 1)
        #expect(fixture.store.launchNotice == .codexSharedServer)
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.codex)))
        let reason = ChatUnavailableReason.noSession(.codex)
        #expect(reason.explanation(launchNotice: .codexSharedServer).contains("codex \(ChatLaunchNotice.unbrokenNoDaemon) resume"))
        // The placeholder says it, so no banner repeats it.
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: fixture.store.conversation, hasPendingEchoes: false,
            launchNotice: fixture.store.launchNotice)
        #expect(lines.isEmpty)
    }

    /// Waiting for Conversation asks for a prompt, which won't help on the
    /// shared server, so a waiting Codex keeps looking until its launch is
    /// read, whatever the read finds.
    @Test(arguments: [["codex"], ["codex", "--no-daemon"]])
    func aWaitingCodexKeepsLookingUntilItsLaunchIsRead(arguments: [String]) async {
        let (fixture, processes) = await Self.launched(arguments)
        await processes.suspendNextRead()
        Self.showWithoutLoop(fixture.store)
        let step = Task { await fixture.store.step() }
        await processes.waitForSuspendedRead()

        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.codex)))
        #expect(fixture.store.isCheckingLaunch)
        #expect(Self.presentation(fixture.store) == .locating)

        await processes.resumeSuspendedRead()
        await step.value
        #expect(!fixture.store.isCheckingLaunch)
        #expect(Self.presentation(fixture.store) == .unavailable(.noSession(.codex)))
    }

    @Test func aFailedLaunchReadStopsTheLookingToo() async {
        let (fixture, processes) = await Self.launched(["codex"])
        await processes.fail(with: .timedOut)
        Self.showWithoutLoop(fixture.store)
        #expect(Self.presentation(fixture.store) == .locating)
        await fixture.store.step()

        #expect(!fixture.store.isCheckingLaunch)
        #expect(Self.presentation(fixture.store) == .unavailable(.noSession(.codex)))
    }

    @Test func onlyACodexWaitWaitsForTheLaunch() async {
        let (claude, _) = await Self.launched(["claude"], program: .claude)
        #expect(!claude.store.isCheckingLaunch)
        let waiting = Self.snapshot(.unavailable(.noSession(.claude)))
        #expect(
            ChatSurfacePresentation(
                conversation: waiting, hasPendingEchoes: false, isHostConnected: true, checkingLaunch: true)
                == .unavailable(.noSession(.claude)))
    }

    private static func presentation(_ store: AgentChatStore) -> ChatSurfacePresentation {
        ChatSurfacePresentation(
            conversation: store.conversation, hasPendingEchoes: false, isHostConnected: true,
            checkingLaunch: store.isCheckingLaunch)
    }

    @Test func aBoundCodexOnTheSharedServerWarnsOverItsConversation() async {
        let session = "01a10f87-e025-7fb1-8974-8dd09937767a"
        let transcript = "/home/dev/.codex/sessions/2026/10/06/rollout-2026-10-06T12-45-25-\(session).jsonl"
        let (fixture, _) = await Self.launched(["codex", "-m", "gpt-5", "resume", session], session: session)
        await fixture.files.write(
            #"{"type":"session_meta","payload":{"id":"\#(session)"}}"# + "\n" + NumberedChatReducer.lines(0..<2),
            at: transcript)
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: transcript))
        #expect(fixture.store.launchNotice == .codexSharedServer)
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: fixture.store.conversation, hasPendingEchoes: false,
            launchNotice: fixture.store.launchNotice)
        #expect(lines == [.launch(.codexSharedServer)])
        #expect(lines.first?.text == "This may be another terminal's conversation.")
    }

    @Test(arguments: [
        ["codex", "--no-daemon"], ["codex", "--no-daemon", "resume"], ["codex", "-c", "model=\"o3\""],
        ["codex", "--profile=work"], ["codex", "-pwork"], ["codex", "--remote", "ws://127.0.0.1:4500"],
    ])
    func aCodexOffTheSharedServerShowsNoNotice(arguments: [String]) async {
        let (fixture, processes) = await Self.launched(arguments)
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()

        #expect(await processes.reads == 1)
        #expect(fixture.store.launchNotice == nil)
    }

    /// Codex before the shared server took no `--no-daemon` either; only a
    /// running server says the launch is on one.
    @Test func noRunningServerMeansNoNotice() async {
        let (fixture, _) = await Self.launched(["codex"], serverRuns: false)
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()

        #expect(fixture.store.launchNotice == nil)
    }

    @Test func onlyAShownCodexChatReadsTheLaunch() async {
        let (hidden, hiddenProcesses) = await Self.launched(["codex"])
        await hidden.store.step()
        #expect(await hiddenProcesses.reads == 0)

        let (claude, claudeProcesses) = await Self.launched(["claude"], program: .claude)
        Self.showWithoutLoop(claude.store)
        await claude.store.step()
        #expect(await claudeProcesses.reads == 0)
        #expect(claude.store.launchNotice == nil)
    }

    @Test func theNoticeClearsOnceCodexIsStartedAgainWithTheFlag() async {
        let (fixture, processes) = await Self.launched(["codex"])
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        #expect(fixture.store.launchNotice == .codexSharedServer)

        await processes.set(["codex", "--no-daemon", "resume"])
        fixture.advance(4)
        await fixture.store.step()
        #expect(await processes.reads == 1)
        fixture.advance(1)
        await fixture.store.step()
        #expect(await processes.reads == 2)
        #expect(fixture.store.launchNotice == nil)

        // Without a notice, only a sign of a new launch asks again.
        fixture.advance(30)
        await fixture.store.step()
        #expect(await processes.reads == 2)
        fixture.store.retry()
        await fixture.store.step()
        #expect(await processes.reads == 3)
    }

    @Test func aFailedReadKeepsTheNoticeAndATransportWithoutProcessesStopsAsking() async {
        let (fixture, processes) = await Self.launched(["codex"])
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        #expect(fixture.store.launchNotice == .codexSharedServer)

        await processes.fail(with: .timedOut)
        fixture.store.retry()
        await fixture.store.step()
        #expect(await processes.reads == 2)
        #expect(fixture.store.launchNotice == .codexSharedServer)
        #expect(fixture.store.conversation.readFailure == nil)

        // A notice that can't be checked any more doesn't stay up.
        await processes.fail(with: .hostFeatureUnavailable(feature: "Chat"))
        fixture.store.retry()
        await fixture.store.step()
        #expect(await processes.reads == 3)
        #expect(fixture.store.launchNotice == nil)
        fixture.store.retry()
        fixture.advance(30)
        await fixture.store.step()
        #expect(await processes.reads == 3)
    }

    @Test func aFailedFirstReadIsTriedAgainWithTheSessionRecheck() async {
        let (fixture, processes) = await Self.launched(["codex"])
        await processes.fail(with: .timedOut)
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        #expect(await processes.reads == 1)
        #expect(fixture.store.launchNotice == nil)

        await processes.fail(with: nil)
        fixture.advance(5)
        await fixture.store.step()
        #expect(await processes.reads == 2)
        #expect(fixture.store.launchNotice == .codexSharedServer)
    }

    @Test func aStatusChangeReadsTheLaunchAgain() async {
        let (fixture, processes) = await Self.launched(["codex", "--no-daemon"])
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        #expect(fixture.store.launchNotice == nil)

        await processes.set(["codex"])
        fixture.store.agentDidChange(Self.agent(session: nil, status: .working, program: .codex))
        await fixture.store.step()
        #expect(await processes.reads == 2)
        #expect(fixture.store.launchNotice == .codexSharedServer)
    }

    /// A placeholder saying why there is no conversation shows none to warn
    /// about; the search for one, and a timeline, carry the banner.
    @Test func theLaunchBannerShowsOnlyOverAConversationOrItsSearch() {
        var missing = ChatConversationSnapshot()
        missing.phase = .unavailable(.notFound(searchedAll: true))
        #expect(
            ChatBannerLine.lines(
                hostStatus: .connected, conversation: missing, hasPendingEchoes: false,
                launchNotice: .codexSharedServer
            ).isEmpty)
        #expect(
            ChatBannerLine.lines(
                hostStatus: .connected, conversation: missing, hasPendingEchoes: true,
                launchNotice: .codexSharedServer
            ) == [.unavailable(.notFound(searchedAll: true), showingSavedMessages: false), .launch(.codexSharedServer)])
        #expect(
            ChatBannerLine.lines(
                hostStatus: .connected, conversation: ChatConversationSnapshot(), hasPendingEchoes: false,
                launchNotice: .codexSharedServer
            ) == [.launch(.codexSharedServer)])
    }

    /// `/clear` typed in the terminal moves an Agent that stays idle to a
    /// new session, and no status change asks herdr about it.
    @Test func aShownIdleAgentIsAskedAgainAndFollowsANewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        let generation = fixture.store.conversationGeneration
        await fixture.server.set(Self.agent(session: Self.second))

        fixture.advance(4)
        await fixture.store.step()
        #expect(await fixture.server.reads == 1)

        fixture.advance(1)
        await fixture.store.step()

        #expect(await fixture.server.reads == 2)
        #expect(fixture.store.conversationGeneration == generation + 1)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
    }

    /// A working Agent's session changes with a status change, which asks
    /// anyway, and a hidden Chat never polls herdr.
    @Test(arguments: [true, false])
    func aWorkingOrHiddenAgentIsNotAskedAgainWithoutAReason(shown: Bool) async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        if shown {
            Self.showWithoutLoop(fixture.store)
            fixture.store.agentDidChange(Self.agent(session: Self.first, status: .working))
        }
        await fixture.store.step()
        #expect(await fixture.server.reads == 1)

        fixture.advance(5)
        await fixture.store.step()
        fixture.advance(30)
        await fixture.store.step()

        #expect(await fixture.server.reads == 1)
    }

    @Test func aSnapshotsNewSessionIsFollowedWithoutAsking() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        await fixture.store.step()

        fixture.store.agentDidChange(Self.agent(session: Self.second))

        #expect(fixture.store.conversation.phase == .locating)
        #expect(fixture.store.conversation.transcript.entries.isEmpty)

        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
    }

    @Test func aContinuedInLinkFollowsTheNewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + #"{"continued":"\#(Self.second)"}"# + "\n",
            at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(5..<6), at: Self.path(Self.second))

        await fixture.store.step()
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(5..<6))
    }

    /// A link is checked like the session herdr reports: a value that is not
    /// the program's session id never becomes a path to follow.
    @Test func aContinuedInLinkThatIsNotASessionIDIsIgnored() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + #"{"continued":"my-thread-name"}"# + "\n",
            at: Self.path(Self.first))

        await fixture.store.step()
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<2))
    }

    @Test func olderPagesLoadOnRequest() async throws {
        let fixture = Fixture(
            session: Self.first,
            limits: TranscriptFollower.Limits(
                tailWindow: 64, readChunk: 16, pollBudget: 1_024, olderPage: 32,
                maximumOlderPage: 128, lineStartSearch: 1_024, anchorLength: 8, headLength: 32,
                lineCap: 4_096, prefixCap: 16))
        await fixture.files.write(NumberedChatReducer.lines(0..<30), at: Self.path(Self.first))
        await fixture.store.step()
        let shown = Self.ids(fixture.store).count
        #expect(fixture.store.conversation.older == .available)

        fixture.store.loadOlder()

        #expect(fixture.store.conversation.older == .loading)

        await fixture.store.step()

        #expect(Self.ids(fixture.store).count > shown)
        #expect(Self.ids(fixture.store).last == "n-29")
    }

    /// The list's own request reads a failed page again, as Retry does,
    /// unless the program bounds what the list loads by itself, as Grok
    /// Build's does: then only Retry reads it again.
    @Test func theListRetriesAFailedPageUnlessItsProgramBoundsWhatItLoads() async throws {
        let claude = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let programs = [
            (claude.limits.automaticOlderSearch, true), (ChatTranscriptAdapter.grok.limits.automaticOlderSearch, false),
        ]
        for (bound, retries) in programs {
            var limits = TranscriptFollower.Limits(
                tailWindow: 64, readChunk: 16, pollBudget: 1_024, olderPage: 32,
                maximumOlderPage: 128, lineStartSearch: 1_024, anchorLength: 8, headLength: 32,
                lineCap: 4_096, prefixCap: 16)
            limits.automaticOlderSearch = bound
            let fixture = Fixture(session: Self.first, limits: limits)
            await fixture.files.write(NumberedChatReducer.lines(0..<30), at: Self.path(Self.first))
            await fixture.store.step()
            let shown = Self.ids(fixture.store).count
            await fixture.files.failNext(.read, path: Self.path(Self.first), with: TransportError.hostFileTimedOut)
            fixture.store.loadOlder()
            await fixture.store.step()
            guard case .failed = fixture.store.conversation.older else {
                Issue.record("expected a failed page, got \(fixture.store.conversation.older)")
                continue
            }

            fixture.store.loadOlder(automatic: true)
            await fixture.store.step()

            #expect((Self.ids(fixture.store).count > shown) == retries)
        }
    }

    @Test func aMissingTranscriptIsLookedForAgainWithBackoff() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.notFound(searchedAll: true)))
        let looked = await fixture.files.statuses.count

        await fixture.store.step()

        #expect(await fixture.files.statuses.count == looked)

        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        fixture.advance(2)
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
    }

    @Test func openingChatLooksForAMissingTranscriptAtOnceAfterPrefetchesBackedOff() async throws {
        let fixture = Fixture(session: Self.first)
        // Background prefetches found nothing and backed off to 8 s.
        for delay in [0.0, 2, 4] {
            fixture.advance(delay)
            await fixture.store.step()
        }
        #expect(fixture.store.conversation.phase == .unavailable(.notFound(searchedAll: true)))
        let looked = await fixture.files.statuses.count

        fixture.store.show()
        fixture.store.hide()
        await fixture.store.step()
        let opened = await fixture.files.statuses.count
        #expect(opened > looked)

        // Then 2 s, not the prefetches' 8.
        fixture.advance(2)
        await fixture.store.step()
        #expect(await fixture.files.statuses.count > opened)
    }

    @Test func sendingLooksForTheTranscriptAtOnce() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.store.step()
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))

        fixture.store.noteSent()
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
    }

    @Test func prefetchSavesWithoutOpeningChatOrContinuingToPoll() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)

        await fixture.store.prefetch()

        #expect(!fixture.store.isVisible)
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<3))
        let reads = await fixture.files.reads.count
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.files.reads.count == reads)

        // Another fresh snapshot must persist its update even within the
        // normal visible loop's save interval.
        await fixture.store.prefetch()
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.isVisible)
    }

    @Test func showingChatDuringPrefetchContinuesTheSameSerializedReader() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let prefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        fixture.store.show()
        await fixture.store.prefetch()
        #expect(await fixture.server.reads == 1)
        await fixture.server.releaseRead()
        _ = await prefetch.value
        try await Self.waitUntil { Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3) }
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Self.waitUntil { Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4) }
        fixture.store.hide()
    }

    @Test func cancellingPrefetchStopsBeforeFilesAndAllowsTheNextSnapshot() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let prefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        prefetch.cancel()
        await fixture.server.releaseRead()
        _ = await prefetch.value

        #expect(await fixture.files.reads.isEmpty)
        #expect(!fixture.store.isVisible)
        await fixture.store.prefetch()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.server.reads == 2)
    }

    @Test func reconnectRetriesAfterACancelledPrefetchStillOwnsTheReader() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        #expect(await fixture.store.prefetch())
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let oldPrefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 2 }

        // Disconnect cancels the caller, but the old remote request has
        // not returned yet. A fast reconnect must not accept its stale,
        // previously successful snapshot as a newly completed prefetch.
        oldPrefetch.cancel()
        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(!(await fixture.store.prefetch()))
        #expect(await fixture.server.reads == 2)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))

        await fixture.server.releaseRead()
        #expect(!(await oldPrefetch.value))
        #expect(await fixture.store.prefetch())
        #expect(await fixture.server.reads == 3)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
    }

    @Test func leavingChatSavesWhatShowed() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)

        fixture.store.show()
        try await Self.waitUntil { fixture.store.conversation.transcript.entries.count == 3 }
        // Saves while following are spaced out; the clock stands still.
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Self.waitUntil { fixture.store.conversation.transcript.entries.count == 4 }
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<3))

        fixture.store.hide()
        try await Self.waitUntil {
            await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<4)
        }

        #expect(!fixture.store.isVisible)
    }

    @Test func anotherWindowsChatKeepsFollowingWhenOneLeaves() async throws {
        let fixture = Fixture(session: Self.first)
        let left = UUID()
        let right = UUID()

        fixture.store.show(left)
        fixture.store.show(right)
        fixture.store.hide(left)

        #expect(fixture.store.isVisible)

        fixture.store.hide(right)

        #expect(!fixture.store.isVisible)
    }

    // MARK: Sent prompts

    private static func sent(_ id: UUID, _ text: String, delivered: Bool = true) -> AgentChatStore.SentMessage {
        AgentChatStore.SentMessage(id: id, text: text, isDelivered: delivered)
    }

    @Test func aSentPromptIsRecordedOnceTheTranscriptHasIt() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        #expect(fixture.store.sendStatuses[id] == .awaiting)
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.files.append(NumberedChatReducer.prompt("hello"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func onlyAPromptRecordedAfterTheSendCounts() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.prompt("hello"), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .awaiting)

        fixture.advance(10)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .overdue)

        await fixture.files.append(NumberedChatReducer.prompt("hello"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func aSentImagePathIsRecordedByThePlaceholderThatNamesIt() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let quoted = UUID()
        let other = UUID()
        let third = UUID()
        let sends = [
            Self.sent(quoted, "'/tmp/a shot.png' "), Self.sent(other, "/tmp/b.png "), Self.sent(third, "/tmp/c.png "),
        ]
        fixture.store.updateSends(sends.map { Self.sent($0.id, $0.text, delivered: false) })
        fixture.store.updateSends(sends)

        // The program names the file it read: only the send of that path
        // matches. A placeholder that names none (a Claude Code enqueue)
        // matches any one path.
        await fixture.files.append(
            NumberedChatReducer.prompt("[Image #1]", images: ["/tmp/a shot.png"]), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[quoted] == .recorded)
        #expect(fixture.store.sendStatuses[other] == .awaiting)
        #expect(fixture.store.sendStatuses[third] == .awaiting)

        await fixture.files.append(NumberedChatReducer.prompt("[Image #1]", images: []), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[other] == .recorded)
        #expect(fixture.store.sendStatuses[third] == .awaiting)
    }

    @Test func aCodexUndoIsFollowedOnAStatusChangeAndOnAnOverdueSend() async throws {
        let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
        let directory = "/home/dev/.codex/sessions/2026/10/06"
        let base = "\(directory)/rollout-2026-10-06T12-45-25-\(thread).jsonl"
        func segment(_ n: Int) -> String {
            "\(directory)/rollout-2026-10-06T13-0\(n)-00-\(thread)_01a10f9a-0000-7000-8000-00000000000\(n).jsonl"
        }
        let meta = #"{"type":"session_meta","payload":{"id":"\#(thread)"}}"# + "\n"
        let fixture = Fixture(session: thread, program: .codex)
        await fixture.files.write(meta + NumberedChatReducer.lines(0..<2), at: base)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: base))

        // An undo continues in a sibling and leaves the base file as it
        // was. The first search after the turn ends fails and is tried again.
        await fixture.files.write(meta + NumberedChatReducer.lines(40..<42), at: segment(1))
        await fixture.files.failNext(.list, with: TransportError.channelFailed(detail: "list"))
        fixture.store.agentDidChange(Self.agent(session: thread, status: .working, program: .codex))
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: base))
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: segment(1)))
        #expect(Self.ids(fixture.store).suffix(2) == ["n-40", "n-41"])

        // A send recorded only in a newer sibling is found once overdue.
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.files.write(meta + NumberedChatReducer.prompt("hello"), at: segment(2))
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .awaiting)
        fixture.advance(10)
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .overdue)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: segment(2)))
        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func twoIdenticalSendsNeedTwoRecordedCopies() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let first = UUID()
        let second = UUID()
        fixture.store.updateSends([Self.sent(first, "go ", delivered: false), Self.sent(second, "go ", delivered: false)])
        fixture.store.updateSends([Self.sent(first, "go "), Self.sent(second, "go ")])

        await fixture.files.append(NumberedChatReducer.prompt("go"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[first] == .recorded)
        #expect(fixture.store.sendStatuses[second] == .awaiting)

        await fixture.files.append(NumberedChatReducer.prompt("go"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[second] == .recorded)
    }

    @Test func aSentCompactIsRecordedByTheCompaction() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "/compact ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "/compact ")])

        await fixture.files.append(NumberedChatReducer.compaction, to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func aSendIntoAnEarlierConversationMatchesAnywhereInTheNext() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<20), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.prompt("fork me"), at: Self.path(Self.second))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "fork me ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "fork me ")])

        // The prompt landed at the start of a session herdr reports next,
        // far before where the first file had been read to.
        await fixture.server.set(Self.agent(session: Self.second))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func anUnrecordedSendFromAnEarlierConversationStopsShowing() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(5..<6), at: Self.path(Self.second))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "lost ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "lost ")])

        await fixture.server.set(Self.agent(session: Self.second))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        fixture.advance(10)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .abandoned)
    }

    @Test func aMessageFirstSeenDeliveredGetsNoEcho() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "earlier ")])

        #expect(fixture.store.sendStatuses[id] == .abandoned)
    }

    @Test func aMessageTheComposerDroppedIsForgotten() async throws {
        let fixture = Fixture(session: Self.first)
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "refused ", delivered: false)])

        fixture.store.updateSends([])

        #expect(fixture.store.sendStatuses.isEmpty)
    }

    // MARK: Pi and Oh My Pi skills

    private static let piSession = "01a14046-b00d-75aa-98ce-6267745b012d"
    private static let piHeader = #"{"type":"session","version":3,"id":"\#(piSession)","cwd":"\#(cwd)"}"#

    /// A store following a Pi or Oh My Pi session through the production
    /// adapter, and the text Chat sends for `/probe from chat`.
    private static func piPath(_ program: ChatProgram) -> String {
        let directory = program == .pi ? ".pi" : ".omp"
        return "/home/dev/\(directory)/agent/sessions/--home-dev-proj--/2026-10-15_\(piSession).jsonl"
    }

    private static func piAgent(_ program: ChatProgram, status: AgentStatus = .idle) -> Agent {
        Agent(
            terminalID: "term-1", kind: program.rawValue, title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: AgentSessionInfo(
                agent: program.rawValue, kind: .path, source: "herdr:\(program.rawValue)", value: piPath(program)))
    }

    private static func skillStore(
        _ program: ChatProgram, clock: Clock = Clock(), cache: VolatileChatTranscriptCache = VolatileChatTranscriptCache(),
        screen: BlockedScreenIO = .unavailable, server: Server? = nil
    ) throws -> (
        files: VirtualHostFiles, store: AgentChatStore, path: String, sent: String
    ) {
        let path = piPath(program)
        let agent = piAgent(program)
        let files = VirtualHostFiles()
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host, paneID: agent.paneID), agent: agent, program: program,
            source: AgentChatSource(
                hostID: host, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { try await server?.read() ?? agent },
                cache: cache,
                adapter: try #require(ChatTranscriptAdapter.standard(for: program)), screen: screen),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
            now: { clock.now })
        let rules = ChatSendRules(
            program: program,
            commands: [
                ChatCommand(
                    name: "probe", summary: nil, kind: .skill(prefix: ChatCommandMenu.skillCommandPrefix),
                    isEnabled: true)
            ])
        return (files, store, path, rules.outgoingText("/probe from chat"))
    }

    @Test func ompSkillSendIsRecorded() async throws {
        let (files, store, path, sent) = try Self.skillStore(.omp)
        await files.write(Self.piHeader + "\n", at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, sent, delivered: false)])
        store.updateSends([Self.sent(id, sent)])

        await files.append(
            #"{"type":"custom_message","customType":"skill-prompt","content":"SKILL BODY","display":true,"details":{"name":"probe","args":"from chat","prompt":"/skill:probe from chat","lineCount":1},"attribution":"user","id":"s1","parentId":null}"#
                + "\n", to: path)
        await store.step()

        #expect(sent == "/skill:probe from chat ")
        #expect(store.sendStatuses[id] == .recorded)
    }

    @Test func piSkillSendIsRecorded() async throws {
        let (files, store, path, sent) = try Self.skillStore(.pi)
        await files.write(Self.piHeader + "\n", at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, sent, delivered: false)])
        store.updateSends([Self.sent(id, sent)])

        await files.append(
            #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"<skill name=\"probe\" location=\"/home/dev/.pi/agent/skills/probe/SKILL.md\">\nSKILL BODY\n</skill>\n\nfrom chat"}]}}"#
                + "\n", to: path)
        await store.step()

        #expect(sent == "/skill:probe from chat ")
        #expect(store.sendStatuses[id] == .recorded)
    }

    // MARK: Pi steers Esc put back

    /// The Agent's pane as Chat reads it, and how often it was read.
    private actor Pane {
        var screen: ANSIScreen
        private(set) var reads = 0

        init(_ screen: ANSIScreen) {
            self.screen = screen
        }

        func read() -> ANSIScreen {
            reads += 1
            return screen
        }

        func show(_ screen: ANSIScreen) {
            self.screen = screen
        }

        nonisolated var io: BlockedScreenIO {
            BlockedScreenIO(
                readScreen: { await self.read() }, sendKeys: { _ in }, paste: { _ in })
        }
    }

    /// Pi's idle editor (pi-36) holding `lines`, or empty.
    private static func piEditor(_ lines: String...) throws -> ANSIScreen {
        let text = try ScreenFixture.text("pi-36-steer-back-in-editor")
        return ANSIScreenDecoder.decode(
            text.replacingOccurrences(of: "Queued steer: say MANGO.", with: lines.joined(separator: "\r\n")))
    }

    /// Steers sent while Pi works, then Esc before the turn takes them: Pi
    /// puts the text back in its editor (pi-36) and never records it.
    private static func stoppedSteers(
        _ program: ChatProgram, texts: [String], screen: ANSIScreen? = nil, server: Server? = nil
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, ids: [UUID]) {
        let clock = Clock()
        let pane = Pane(try screen ?? ScreenFixture.screen("pi-36-steer-back-in-editor"))
        let (files, store, path, _) = try Self.skillStore(program, clock: clock, screen: pane.io, server: server)
        await files.write(Self.piHeader + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "go"), at: path)
        await store.step()
        store.agentDidChange(Self.piAgent(program, status: .working))
        let messages = texts.map { (id: UUID(), text: $0) }
        store.updateSends(messages.map { Self.sent($0.id, $0.text, delivered: false) })
        store.updateSends(messages.map { Self.sent($0.id, $0.text) })
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        for message in messages {
            #expect(store.sendStatuses[message.id] == .overdue)
        }
        store.agentDidChange(Self.piAgent(program, status: .idle))
        return (files, store, pane, clock, messages.map(\.id))
    }

    private static func stoppedSteer(
        _ program: ChatProgram, text: String, screen: ANSIScreen? = nil, server: Server? = nil
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, id: UUID) {
        let (files, store, pane, clock, ids) = try await stoppedSteers(
            program, texts: [text], screen: screen, server: server)
        return (files, store, pane, clock, try #require(ids.first))
    }

    /// One idle spell passes and herdr reports the next turn ending.
    private static func nextIdleSpell(_ store: AgentChatStore, _ program: ChatProgram, clock: Clock) async {
        store.agentDidChange(Self.piAgent(program, status: .working))
        await store.step()
        store.agentDidChange(Self.piAgent(program, status: .idle))
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
    }

    @Test func aSteerStopPutBackInTheEditorIsReturnedUntilRecorded() async throws {
        let (files, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")

        // Pi may still be moving the steer back.
        await store.step()
        #expect(await pane.reads == 0)
        #expect(store.sendStatuses[id] == .overdue)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .returned)

        // Sent from the terminal after all, the transcript has it.
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// The box must hold the send and nothing else: a short send found
    /// inside an unrelated draft is not the steer Esc put back.
    @Test func aShortSendInsideALongerDraftStaysOverdue() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "say ")

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// Pi puts every queued steer back at once, a blank line between each.
    @Test func severalSteersStopPutBackTogetherAreAllReturned() async throws {
        let (_, store, pane, clock, ids) = try await Self.stoppedSteers(
            .pi, texts: ["say KIWI ", "say MANGO. ", "say LIME "],
            screen: try Self.piEditor("say KIWI", "", "say LIME"))

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(ids.map { store.sendStatuses[$0] } == [.returned, .overdue, .returned])
    }

    /// Esc puts back only the steers of the turn it stops. A send overdue
    /// from an earlier turn is not looked for again, whatever the box
    /// shows later.
    @Test func anOverdueSendFromAnEarlierTurnIsNotLookedForAgain() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(
            .pi, text: "Queued steer: say MANGO. ", screen: try Self.piEditor())
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)

        await pane.show(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        await Self.nextIdleSpell(store, .pi, clock: clock)

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// A returned send is an observation: once the user clears the box in
    /// the terminal, the next idle spell's read finds it discarded, which
    /// it stays. It was never delivered, so it is not overdue.
    @Test func aReturnedSendTheBoxNoLongerHoldsIsDiscarded() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        // Still there a spell later.
        await Self.nextIdleSpell(store, .pi, clock: clock)
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try Self.piEditor())
        await Self.nextIdleSpell(store, .pi, clock: clock)

        #expect(await pane.reads == 3)
        #expect(store.sendStatuses[id] == .discarded)

        // The box is not looked at for it again.
        await pane.show(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        await Self.nextIdleSpell(store, .pi, clock: clock)
        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(await pane.reads == 3)
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// The read before a send also shows whether the box still holds a
    /// returned send, without a read of its own.
    @Test func aReadBeforeASendDiscardsAReturnedSendTheBoxNoLongerHolds() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor("a draft of my own"))
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// Text the user added to a returned steer in the terminal hides where
    /// the steer ends, but the steer is still in the box: neither the read
    /// before a send nor an idle spell's read discards it.
    @Test func aReturnedSendTheUserAddedToInTheBoxStaysReturned() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        let edited = try Self.piEditor("Queued steer: say MANGO. and check X")
        store.inputBoxWasRead(edited)
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(edited)
        await Self.nextIdleSpell(store, .pi, clock: clock)
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .returned)

        // Cleared at last.
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// The steer the user added to and then sent from the terminal is in
    /// the prompt the transcript records, so that prompt settles it.
    @Test func aReturnedSendTheUserAddedToAndSentIsRecorded() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor("Queued steer: say MANGO. and check X"))
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor())
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO. and check X"),
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Pi 0.85.1 at the phone's 62 columns: Stop 2 s after a steer puts it
    /// back while its echo is still inside the timeout, then the user adds
    /// to it, a Chat send is held, and Enter in the terminal sends it all.
    /// The steer is found returned at once, so the prompt settles it.
    @Test func aSendMadeWhileIdleIsNotLookedForInTheBoxBeforeItIsOverdue() async throws {
        let capture = try ScreenFixture.text("pi-40-phone-extended-steer")
        let range = try #require(capture.range(of: "say FIG and also say PEAR", options: .backwards))
        let clock = Clock()
        // The editor still shows the text herdr just typed.
        let pane = Pane(ANSIScreenDecoder.decode(capture.replacingCharacters(in: range, with: "say FIG")))
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n", at: path)
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await store.step()
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(5)

        let id = UUID()
        store.updateSends([Self.sent(id, "say FIG", delivered: false)])
        store.updateSends([Self.sent(id, "say FIG")])
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 0)
        #expect(store.sendStatuses[id] == .awaiting)
    }

    @Test func aReturnedSteerExtendedOnThePhoneIsRecorded() async throws {
        let records = [
            ##"{"type":"message","id":"dcfb765c","parentId":null,"timestamp":"2026-10-17T03:58:00.714Z","message":{"role":"user","content":[{"type":"text","text":"run sleep 40 with bash, then reply: ok"}],"timestamp":1792209480714}}"##,
            ##"{"type":"message","id":"6a04c408","parentId":"dcfb765c","timestamp":"2026-10-17T03:58:02.924Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Running sleep 40 via bash, then replying ok.","thinkingSignature":"{\"id\":\"rs_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37\",\"summary\":[{\"text\":\"Running sleep 40 via bash, then replying ok.\",\"type\":\"summary_text\"}],\"type\":\"reasoning\",\"status\":\"completed\",\"encrypted_content\":\"qxkzShyrpNcpoBRidtN3Sq0oayhAJnohMakiye+6HSrMARqPLSOvjoqQFwAfbkR8gZ+dQITPLbgNExuyPPsBKhGf6DsCwxx8cegQtL+IYnPv7uhC4+K1lgNihAdHvxaXF9ribah+cZtiMy6ZHW553QKhWQZx7rYhZz7/a2XqZb6wBCcari4d8vtlNtsizIH3ywBCKaGKWozw/yxB0qD4nBWpRYB8dPv/yq6k5loNtPs9ZwHqC2Crc2E+JOe0mp9zxdDFoKiF2AI\"}"},{"type":"toolCall","id":"call-f4bfa82d-4cb3-4a0b-a7d8-3f55e366b25a-3|fc_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37_0","name":"bash","arguments":{"command":"sleep 40","timeout":60}}],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":94,"output":54,"cacheRead":7168,"cacheWrite":0,"reasoning":39,"totalTokens":7316,"cost":{"input":0.000188,"output":0.000324,"cacheRead":0.0021504,"cacheWrite":0,"total":0.0026623999999999997}},"stopReason":"toolUse","timestamp":1792209480715,"responseId":"7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37","rawStopReason":"completed"}}"##,
            ##"{"type":"message","id":"41d0569e","parentId":"6a04c408","timestamp":"2026-10-17T03:58:13.068Z","message":{"role":"toolResult","toolCallId":"call-f4bfa82d-4cb3-4a0b-a7d8-3f55e366b25a-3|fc_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37_0","toolName":"bash","content":[{"type":"text","text":"Command aborted"}],"details":{},"isError":true,"timestamp":1792209493068}}"##,
            ##"{"type":"message","id":"230cb2fa","parentId":"41d0569e","timestamp":"2026-10-17T03:58:13.069Z","message":{"role":"assistant","content":[],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","errorMessage":"This operation was aborted","timestamp":1792209493069}}"##,
            ##"{"type":"message","id":"929aa8c6","parentId":"230cb2fa","timestamp":"2026-10-17T03:58:37.242Z","message":{"role":"user","content":[{"type":"text","text":"say FIG and also say PEAR"}],"timestamp":1792209517241}}"##,
            ##"{"type":"message","id":"5ecb20e9","parentId":"929aa8c6","timestamp":"2026-10-17T03:58:39.432Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"{\"id\":\"rs_20af3db3-28ae-9efc-93b2-58737484644f\",\"summary\":[],\"type\":\"reasoning\",\"status\":\"completed\",\"encrypted_content\":\"EY3OTsyOVY7cG1jjBLa5vX/QCTg/mibrpKUS2S9RW1I3Zo94/Jb+VNFnTEPiq75LGvR4+VAQ7HzqfJVWdbXPJTrs\"}"},{"type":"text","text":"FIG\nPEAR","textSignature":"{\"v\":1,\"id\":\"msg_20af3db3-28ae-9efc-93b2-58737484644f\"}"}],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":168,"output":15,"cacheRead":7168,"cacheWrite":0,"reasoning":11,"totalTokens":7351,"cost":{"input":0.000336,"output":9e-05,"cacheRead":0.0021504,"cacheWrite":0,"total":0.0025764}},"stopReason":"stop","timestamp":1792209517242,"responseId":"20af3db3-28ae-9efc-93b2-58737484644f","rawStopReason":"completed"}}"##,
        ]
        let capture = try ScreenFixture.text("pi-40-phone-extended-steer")
        func editor(_ text: String) throws -> ANSIScreen {
            let range = try #require(capture.range(of: "say FIG and also say PEAR", options: .backwards))
            return ANSIScreenDecoder.decode(capture.replacingCharacters(in: range, with: text))
        }
        let clock = Clock()
        let pane = Pane(try editor("say FIG"))
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n" + records[0] + "\n" + records[1] + "\n", at: path)
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, "say FIG", delivered: false)])
        store.updateSends([Self.sent(id, "say FIG")])
        await store.step()
        await files.append(records[2] + "\n" + records[3] + "\n", to: path)
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try editor("say FIG and also say PEAR"))
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        store.inputBoxWasRead(try editor("say FIG and also say PEAR"))
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try editor(""))
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await files.append(records[4] + "\n", to: path)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
        await files.append(records[5] + "\n", to: path)
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Only a send seen among more text takes a prompt that merely contains
    /// it: a cleared one is not recorded when a longer prompt mentions it,
    /// only no longer shown.
    @Test func aClearedSendIsNotSettledByALongerPrompt() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO. and check X"),
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// A cleared send shows while it is Chat's latest message, until the
    /// transcript records a prompt after it, such as one the terminal
    /// sent: under that newer turn it would read out of order.
    @Test func aClearedSendStopsShowingOnceALaterPromptIsRecorded() async throws {
        let text = "Queued steer: say MANGO. "
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: text)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        await store.step()
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// Pi delivers one steer per turn boundary, so an earlier steer can be
    /// recorded after a later one was sent. That record is not a message
    /// after the later steer: cleared, it still shows as not delivered.
    @Test func aClearedSteerIsNotOvertakenByAnEarlierSteerRecordedLate() async throws {
        let (files, store, _, clock, ids) = try await Self.stoppedSteers(
            .pi, texts: ["Queued steer: say KIWI. ", "Queued steer: say MANGO. "])
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say KIWI."), to: Self.piPath(.pi))
        await store.step()
        #expect(store.sendStatuses[ids[0]] == .recorded)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[ids[1]] == .returned)
        store.inputBoxWasRead(try Self.piEditor())
        await store.step()

        #expect(store.sendStatuses[ids[1]] == .discarded)
    }

    /// Sent from the terminal after all: the box empties before the
    /// transcript has it, and the recorded copy still settles the send.
    @Test func aDiscardedSendTheTranscriptRecordsLaterIsRecorded() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Sent again from Chat once cleared: the new send takes the recorded
    /// copy instead of leaving it unconfirmed, and the cleared one, with a
    /// prompt recorded after it, no longer shows.
    @Test func aSendAgainFromChatTakesTheRecordedCopyBeforeADiscardedOne() async throws {
        let text = "Queued steer: say MANGO. "
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: text)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        let again = UUID()
        store.updateSends([Self.sent(id, text), Self.sent(again, text, delivered: false)])
        store.updateSends([Self.sent(id, text), Self.sent(again, text)])
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[again] == .recorded)
        #expect(store.sendStatuses[id] == .abandoned)
    }

    @Test func anOverdueSendTheEditorDoesNotHoldStaysOverdue() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "say KIWI ")

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// Only Pi's and Oh My Pi's Esc is known to hand steers back: a send
    /// Claude Code or Codex left overdue when its turn ended is never looked
    /// for on the screen, where the same steps read Pi's once
    /// (`aSteerStopPutBackInTheEditorIsReturnedUntilRecorded()`).
    @Test(arguments: [ChatProgram.claude, .codex])
    func aSendLeftOverdueAfterStopIsNotLookedForOnTheScreen(program: ChatProgram) async throws {
        let pane = Pane(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        let (fixture, session, _) = await Self.followed(program, screen: pane.io)
        fixture.store.agentDidChange(Self.agent(session: session, status: .working, program: program))
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])
        fixture.advance(10)
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .overdue)

        fixture.store.agentDidChange(Self.agent(session: session, status: .idle, program: program))
        fixture.advance(1)
        await fixture.store.step()
        await fixture.store.step()

        #expect(await pane.reads == 0)
        #expect(fixture.store.sendStatuses[id] == .overdue)
    }

    // MARK: Refused compactions

    /// A Pi or Oh My Pi store holding one recorded prompt, with `/compact`
    /// sent from Chat while the Agent stays idle.
    private static func sentCompact(
        _ program: ChatProgram, screen: ANSIScreen
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, id: UUID) {
        let clock = Clock()
        let pane = Pane(screen)
        let (files, store, path, _) = try Self.skillStore(program, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "go"), at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, "/compact", delivered: false)])
        store.updateSends([Self.sent(id, "/compact")])
        await store.step()
        return (files, store, pane, clock, id)
    }

    /// Pi 0.85.1 (pi-41) and Oh My Pi 18.11.1 print the same refusal for
    /// a `/compact` with nothing to compact, record nothing and stay idle.
    /// One read once the echo is overdue says so instead; a prompt
    /// recorded later retires it rather than leave it under that turn.
    @Test(arguments: [ChatProgram.pi, .omp])
    func aCompactWithNothingToCompactIsRefusedAfterOneRead(program: ChatProgram) async throws {
        let (files, store, pane, clock, id) = try await Self.sentCompact(
            program, screen: try ScreenFixture.screen("pi-41-compact-nothing"))
        #expect(await pane.reads == 0)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .refused("\(program.chatName) had nothing to compact."))

        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(program))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// At the phone's 62 columns the refusal wraps `small)` onto a second
    /// row, and Oh My Pi draws its session title between it and the status
    /// band (pi-42, omp-35); neither is conversation below the refusal.
    @Test(arguments: [
        (ChatProgram.pi, "pi-42-compact-nothing-62"), (ChatProgram.omp, "omp-35-compact-nothing-62"),
    ])
    func aWrappedRefusalAtThePhoneWidthIsRefused(program: ChatProgram, stem: String) async throws {
        let (_, store, pane, clock, id) = try await Self.sentCompact(program, screen: try ScreenFixture.screen(stem))

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .refused("\(program.chatName) had nothing to compact."))
    }

    /// The screen is read once for each overdue `/compact`: one that
    /// showed no refusal stays overdue, whatever the screen shows later,
    /// until a prompt recorded after it with no compaction retires it.
    @Test func anOverdueCompactIsLookedForOnce() async throws {
        let (files, store, pane, clock, id) = try await Self.sentCompact(.pi, screen: try Self.piEditor())

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)

        await pane.show(try ScreenFixture.screen("pi-41-compact-nothing"))
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)

        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// herdr stays idle while Pi compacts: a read that finds the spinner
    /// keeps the echo awaiting and waits for the next step, and a failure
    /// row with conversation below it is an earlier attempt's, not this
    /// one's refusal. Once the spinner is gone the echo waits the echo
    /// timeout from the last read that saw it.
    @Test func aCompactionStillRunningOrAnEarlierFailureIsNoRefusal() async throws {
        let (_, store, pane, clock, id) = try await Self.sentCompact(
            .pi, screen: try ScreenFixture.screen("pi-39-compacting-empty"))

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .awaiting)

        let capture = try ScreenFixture.text("pi-39-compacting-empty")
        await pane.show(
            ANSIScreenDecoder.decode(
                capture.replacingOccurrences(of: "Compacting context... (escape to cancel)", with: "")))
        await store.step()
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .awaiting)

        await store.step()
        #expect(await pane.reads == 2)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// Pi 0.85.1 retries a failed summarization call after a countdown
    /// that takes the spinner's row for about 2 s: the compaction still
    /// runs, so a read that lands on the countdown keeps the echo awaiting.
    @Test func aCompactionRetryCountdownKeepsItsEchoAwaiting() async throws {
        let capture = try ScreenFixture.text("pi-39-compacting-empty")
        let retrying = capture.replacingOccurrences(
            of: "Compacting context... (escape to cancel)", with: "Retrying (1/3) in 2s... (escape to cancel)")
        #expect(retrying != capture)
        let (_, store, pane, clock, id) = try await Self.sentCompact(.pi, screen: ANSIScreenDecoder.decode(retrying))

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .awaiting)

        await store.step()
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .awaiting)
    }

    /// A real Pi compaction runs 10 to 18 s while herdr reports the Agent
    /// idle (V3 PI-03): the echo stays awaiting, never "hasn't appeared",
    /// while the screen shows "Compacting context...", and the compaction's
    /// record settles it.
    @Test(arguments: [ChatProgram.pi, .omp])
    func aRunningCompactionKeepsItsEchoAwaiting(program: ChatProgram) async throws {
        let (files, store, pane, clock, id) = try await Self.sentCompact(
            program, screen: try ScreenFixture.screen("pi-39-compacting-empty"))

        for _ in 0..<4 {
            clock.now = clock.now.addingTimeInterval(5)
            await store.step()
            #expect(store.sendStatuses[id] == .awaiting)
        }
        // From +10 s on, one read each step.
        #expect(await pane.reads == 3)

        await files.append(
            #"{"type":"compaction","id":"c1","parentId":"u1","summary":"summary","firstKeptEntryId":"u1"}"# + "\n",
            to: Self.piPath(program))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Any other compaction failure is refused too, and a compaction the
    /// transcript records after all still settles the send.
    @Test func anotherCompactionFailureIsRefusedUntilACompactionIsRecorded() async throws {
        let capture = try ScreenFixture.text("pi-41-compact-nothing")
        let screen = ANSIScreenDecoder.decode(
            capture.replacingOccurrences(
                of: "Nothing to compact (session too small)", with: "Summarization request failed"))
        let (files, store, _, clock, id) = try await Self.sentCompact(.pi, screen: screen)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(store.sendStatuses[id] == .refused("Pi couldn't compact."))

        await files.append(
            #"{"type":"compaction","id":"c1","parentId":"u1","summary":"summary","firstKeptEntryId":"u1"}"# + "\n",
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// The Composer still holds an earlier `/compact` Pi refused, retired
    /// by the prompt recorded after it. A compaction recorded after that
    /// prompt is the next `/compact`'s, not the earlier one's.
    @Test func aLaterCompactionSettlesTheLaterCompact() async throws {
        let (files, store, _, clock, first) = try await Self.sentCompact(
            .pi, screen: try ScreenFixture.screen("pi-41-compact-nothing"))
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(.pi))
        await store.step()
        #expect(store.sendStatuses[first] == .abandoned)

        let second = UUID()
        store.updateSends([Self.sent(first, "/compact"), Self.sent(second, "/compact", delivered: false)])
        store.updateSends([Self.sent(first, "/compact"), Self.sent(second, "/compact")])
        await files.append(
            #"{"type":"compaction","id":"c1","parentId":"u2","summary":"summary","firstKeptEntryId":"u2"}"# + "\n",
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[second] == .recorded)
        #expect(store.sendStatuses[first] == .abandoned)
    }

    /// Only Pi, Oh My Pi and Grok Build are known to refuse on screen:
    /// Claude Code's and Codex's overdue `/compact` stays overdue without
    /// a read.
    @Test(arguments: [ChatProgram.claude, .codex])
    func anOverdueCompactIsNotLookedForOnTheScreen(program: ChatProgram) async throws {
        let pane = Pane(try ScreenFixture.screen("pi-41-compact-nothing"))
        let (fixture, _, _) = await Self.followed(program, screen: pane.io)
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "/compact", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "/compact")])

        fixture.advance(10)
        await fixture.store.step()
        await fixture.store.step()

        #expect(await pane.reads == 0)
        #expect(fixture.store.sendStatuses[id] == .overdue)
    }

    /// Only Pi and Oh My Pi are known to record a compaction before the
    /// next prompt: a Claude Code or Codex `/compact` that a later prompt
    /// overtook with no compaction stays overdue, where Pi's is abandoned
    /// (`anOverdueCompactIsLookedForOnce()`).
    @Test(arguments: [ChatProgram.claude, .codex])
    func anOvertakenCompactWithoutACompactionStaysOverdue(program: ChatProgram) async throws {
        let (fixture, _, path) = await Self.followed(program, screen: .unavailable)
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "/compact", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "/compact")])
        fixture.advance(10)
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .overdue)

        await fixture.files.append(NumberedChatReducer.prompt("say PLUM"), to: path)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .overdue)
    }

    // MARK: Oh My Pi rewrites

    private static func ompMessage(_ id: String, parent: String?, role: String, _ text: String) -> String {
        let parent = parent.map { #""\#($0)""# } ?? "null"
        let content =
            role == "user" ? #""\#(text)""# : #"[{"type":"text","text":"\#(text)"}],"stopReason":"stop""#
        return #"{"type":"message","id":"\#(id)","parentId":\#(parent),"message":{"role":"\#(role)","content":\#(content)}}"#
            + "\n"
    }

    /// The device saved the conversation read further than the file now
    /// reaches: Oh My Pi rewrote it smaller since. The send's floor from the
    /// saved document no longer locates its prompt; the entries it showed
    /// still rule themselves out.
    @Test func restoredFloorSurvivesRewrite() async throws {
        let cache = VolatileChatTranscriptCache()
        let (files, store, path, _) = try Self.skillStore(.omp, cache: cache)
        await cache.save(
            ChatCacheDocument(
                key: ChatCacheKey(
                    hostID: Self.host, socketLocation: .defaultSession,
                    reference: ConversationReference(program: .omp, sessionID: path)),
                adapterRevision: PiTranscriptReducer.revision, transcriptPath: path,
                head: Data((Self.piHeader + "\n").utf8), coverageStart: 0, coverageEnd: 1 << 20,
                reachedStart: true, title: nil,
                entries: [
                    ChatEntry(
                        id: ChatEntryID("pi:u1"), sourceOffset: 100, content: .user(ChatUserMessage(text: "again")))
                ], savedAt: Self.start))
        await store.step()
        #expect(store.conversation.isFromCache)
        #expect(store.conversation.readOffset == 1 << 20)
        let id = UUID()
        store.updateSends([Self.sent(id, "again ", delivered: false)])
        store.updateSends([Self.sent(id, "again ")])

        let titled = Self.piHeader.replacingOccurrences(of: "}", with: #","title":"Again","titleSource":"auto"}"#)
        await files.write(
            titled + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "again")
                + Self.ompMessage("a1", parent: "u1", role: "assistant", "done"), at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
        #expect(store.sendStatuses[id] == .awaiting)

        await files.append(Self.ompMessage("u2", parent: "a1", role: "user", "again"), to: path)
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// One recorded copy answers one send even after Oh My Pi rewrites the
    /// file and every prompt moves.
    @Test func claimSurvivesRewrite() async throws {
        let (files, store, path, _) = try Self.skillStore(.omp)
        let long = Self.ompMessage("f0", parent: nil, role: "assistant", String(repeating: "x", count: 2_000))
        await files.write(Self.piHeader + "\n" + long, at: path)
        await store.step()
        let first = UUID()
        let second = UUID()
        store.updateSends([Self.sent(first, "go ", delivered: false), Self.sent(second, "go ", delivered: false)])
        store.updateSends([Self.sent(first, "go "), Self.sent(second, "go ")])

        let prompt = Self.ompMessage("u1", parent: "f0", role: "user", "go")
        await files.append(prompt, to: path)
        await store.step()

        #expect(store.sendStatuses[first] == .recorded)
        #expect(store.sendStatuses[second] == .awaiting)

        // The rewrite prunes the long reply: the prompt moves up the file.
        let generation = store.conversation.layoutGeneration
        await files.write(
            Self.piHeader + "\n" + Self.ompMessage("f0", parent: nil, role: "assistant", "x") + prompt, at: path)
        await store.step()

        #expect(store.conversation.layoutGeneration == generation + 1)
        #expect(store.sendStatuses[second] == .awaiting)

        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "go"), to: path)
        await store.step()

        #expect(store.sendStatuses[second] == .recorded)
    }

    // MARK: A new Claude Code conversation

    private static let sessionEnvironment = "/home/dev/.claude/session-env/\(first)"

    /// Claude Code writes a new session's transcript with its first message:
    /// Chat looks under the Agent's directory on every pass, without backing
    /// off or searching every project directory again.
    @Test func aNewClaudeConversationIsFollowedOnceItsFileAppears() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.makeDirectory(Self.sessionEnvironment)
        await fixture.files.makeDirectory("/home/dev/.claude/projects/-p0")
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)))

        await fixture.files.clearRecords()
        await fixture.store.step()
        await fixture.store.step()

        #expect(await fixture.files.statuses == [Self.path(Self.first), Self.path(Self.first)])
        #expect(await fixture.files.listings.isEmpty)

        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
    }

    /// Claude Code records a message as it takes it, so one sent while the
    /// conversation is new still times out, unlike one sent to Pi, and a
    /// session that never records it saves nothing: it is not found.
    @Test func aMessageANewClaudeConversationNeverRecordsEndsIt() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.makeDirectory(Self.sessionEnvironment)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)))
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])

        fixture.advance(60)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .overdue)

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .unavailable(.notFound(searchedAll: true)))

        // Recorded late after all: still followed.
        await fixture.files.write(NumberedChatReducer.prompt("hello"), at: Self.path(Self.first))
        fixture.advance(2)
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    /// Claude Code saves a new conversation with its first message, Pi and
    /// Oh My Pi with the first reply.
    @Test(arguments: [ChatProgram.claude, .pi, .omp])
    func aNewConversationSaysWhenItsProgramSavesIt(program: ChatProgram) {
        let reason = ChatUnavailableReason.awaitingFirstMessage(program)
        let banner = reason.bannerText(showingSavedMessages: false)
        #expect(reason.title == "No Messages Yet")
        #expect(reason.explanation.hasPrefix("\(program.chatName) saves this conversation "))
        for text in [reason.explanation, banner] {
            #expect(text.contains("first message") == (program == .claude))
            #expect(text.contains("first reply") == (program != .claude))
        }
    }

    // MARK: A new Pi or Oh My Pi conversation

    /// Pi and Oh My Pi write a new conversation's file with the first reply;
    /// until then the Agent is in a conversation with nothing to show.
    @Test(arguments: [ChatProgram.pi, .omp])
    func sendWhileAwaitingFirstMessageIsNotOverdue(program: ChatProgram) async throws {
        let clock = Clock()
        let (files, store, path, _) = try Self.skillStore(program, clock: clock)
        await store.step()
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(program)))
        let id = UUID()
        store.updateSends([Self.sent(id, "hello ", delivered: false)])
        store.updateSends([Self.sent(id, "hello ")])

        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(store.sendStatuses[id] == .awaiting)

        await files.write(
            Self.piHeader + "\n"
                + #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"#
                + "\n", at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// A steer Stop put back, kept or cleared, belongs to the conversation
    /// it was sent into; a new one that is still unwritten does not wait
    /// for it, only for what is sent into it.
    @Test(arguments: [false, true])
    func anEarlierConversationsReturnedSteerDoesNotWaitInTheNext(cleared: Bool) async throws {
        let server = Server(Self.piAgent(.pi))
        let (_, store, pane, clock, old) = try await Self.stoppedSteer(
            .pi, text: "Queued steer: say MANGO. ", server: server)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[old] == .returned)
        if cleared {
            await pane.show(try Self.piEditor())
            await Self.nextIdleSpell(store, .pi, clock: clock)
            #expect(store.sendStatuses[old] == .discarded)
        }

        // `/new` in the pane: herdr reports a session whose file Pi writes
        // with the first reply.
        let next = Agent(
            terminalID: "term-1", kind: "pi", title: "", status: .idle, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: Self.cwd, revision: 2,
            agentSession: AgentSessionInfo(
                agent: "pi", kind: .path, source: "herdr:pi",
                value: "/home/dev/.pi/agent/sessions/--home-dev-proj--/2026-10-15_01a14046-b00d-75aa-98ce-000000000002.jsonl"))
        await server.set(next)
        store.agentDidChange(next)
        await store.step()
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(.pi)))
        let sent = UUID()
        store.updateSends([Self.sent(old, "Queued steer: say MANGO. "), Self.sent(sent, "hello ", delivered: false)])
        store.updateSends([Self.sent(old, "Queued steer: say MANGO. "), Self.sent(sent, "hello ")])
        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(store.sendStatuses[old] == .abandoned)
        #expect(store.sendStatuses[sent] == .awaiting)
    }

    @Test func fileAppearingAfterFirstTurnIsFollowed() async throws {
        let clock = Clock()
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock)
        await store.step()
        await store.step()
        await store.step()

        // Looked for on every pass, without backing off.
        #expect(await files.statuses.filter { $0 == path }.count == 3)
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(.pi)))

        await files.write(Self.piHeader + "\n", at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
    }

    // MARK: Grok Build's echo clock

    /// The session in `grok/core-turns.jsonl`.
    private static let grokSession = "01900000-0000-7000-8000-000000000004"
    private static let grokPath = "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/\(grokSession)/updates.jsonl"

    private static func grokAgent(_ status: AgentStatus) -> Agent {
        agent(session: grokSession, status: status, program: .grok)
    }

    /// Lines `range` of a `grok/` fixture (1-based, inclusive), as written.
    private static func grokLines(_ fixture: String, _ range: ClosedRange<Int>) throws -> String {
        let rows = try ChatFixture.text("grok/\(fixture)").split(separator: "\n", omittingEmptySubsequences: false)
        return rows[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n") + "\n"
    }

    /// A store following lines 1 to `line` of `grok/core-turns.jsonl`
    /// through Grok Build's own adapter, while herdr reports `status`. A
    /// gate holds stats of the folder's prompt history.
    private static func grokStore(
        through line: Int, status: AgentStatus, server: Server? = nil, gate: HistoryGate? = nil,
        cache: VolatileChatTranscriptCache = VolatileChatTranscriptCache(), screen: BlockedScreenIO = .unavailable,
        timing: AgentChatStore.Timing = AgentChatStore.Timing(
            activeInterval: .milliseconds(5), idleInterval: .milliseconds(5))
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, clock: Clock) {
        let clock = Clock()
        let files = VirtualHostFiles()
        let agent = Self.grokAgent(status)
        await files.write(try grokLines("core-turns.jsonl", 1...line), at: grokPath)
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host, paneID: agent.paneID), agent: agent, program: .grok,
            source: AgentChatSource(
                hostID: host, socketLocation: .defaultSession,
                files: gate?.files(files, holding: grokHistory) ?? files.hostFiles(),
                agentInfo: { try await server?.read() ?? agent }, cache: cache, adapter: .grok, screen: screen),
            timing: timing, now: { clock.now })
        await store.step()
        #expect(store.conversation.phase == .following(path: grokPath))
        return (files, store, clock)
    }

    /// Grok Build writes a prompt sent while it works only once the turn
    /// ahead of it ends and its own starts (27 s later in one capture),
    /// and herdr reports it Working throughout, so its echo waits that out.
    @Test func aGrokSendQueuedBehindATurnWaitsForItToStart() async throws {
        // The terminal's second prompt is running.
        let (files, store, clock) = try await Self.grokStore(through: 5, status: .working)
        let id = UUID()
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ", delivered: false)])
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ")])

        clock.now = clock.now.addingTimeInterval(20)
        await files.append(try Self.grokLines("core-turns.jsonl", 6...7), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        clock.now = clock.now.addingTimeInterval(7)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        await files.append(try Self.grokLines("core-turns.jsonl", 8...8), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// `/compact` keeps herdr reporting Grok Build Working until the
    /// compaction is written: about 8 s in a small session, longer in a
    /// real one.
    @Test func aGrokCompactionLongerThanTheTimeoutStaysAwaiting() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let id = UUID()
        store.updateSends([Self.sent(id, "/compact ", delivered: false)])
        store.updateSends([Self.sent(id, "/compact ")])
        clock.now = clock.now.addingTimeInterval(1)
        store.agentDidChange(Self.grokAgent(.working))

        clock.now = clock.now.addingTimeInterval(30)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        await files.append(try Self.grokLines("compaction.jsonl", 5...6), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Grok Build 1.0.62 writes nothing for a `/compact` that Stop
    /// cancelled, only `Compaction cancelled.` on screen (grok-45, the
    /// scrollbar's thumb between it and the box). Once the Agent is idle
    /// and the echo overdue, one read says so instead of "hasn't appeared".
    @Test func aCancelledGrokCompactionIsSettledAfterOneRead() async throws {
        let pane = Pane(try ScreenFixture.screen("grok-45-compaction-cancelled-62"))
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle, screen: pane.io)
        let id = UUID()
        store.updateSends([Self.sent(id, "/compact ", delivered: false)])
        store.updateSends([Self.sent(id, "/compact ")])
        clock.now = clock.now.addingTimeInterval(1)
        store.agentDidChange(Self.grokAgent(.working))
        clock.now = clock.now.addingTimeInterval(5)
        store.agentDidChange(Self.grokAgent(.idle))
        await store.step()
        #expect(await pane.reads == 0)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .refused("The compaction was cancelled."))

        await files.append(try Self.grokLines("core-turns.jsonl", 5...5), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// A read that finds Grok Build's spinner row (`⠼ Compacting…`,
    /// grok-27) while herdr reports it idle keeps the echo awaiting: the
    /// `Compacting conversation…` row above it stays after a cancel, so
    /// only the spinner says the compaction still runs.
    @Test func aRunningGrokCompactionKeepsItsEchoAwaiting() async throws {
        let pane = Pane(try ScreenFixture.screen("grok-27-compacting"))
        let (_, store, clock) = try await Self.grokStore(through: 4, status: .idle, screen: pane.io)
        let id = UUID()
        store.updateSends([Self.sent(id, "/compact ", delivered: false)])
        store.updateSends([Self.sent(id, "/compact ")])

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .awaiting)

        await store.step()
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .awaiting)
    }

    /// herdr reports Grok Build idle for up to half a second after a
    /// prompt goes in. A send in that moment queues behind that prompt's
    /// turn, and its echo waits for its own like one sent while Grok works.
    @Test func aSendRightAfterASubmitWaitsForItsQueuedTurn() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let id = UUID()
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ", delivered: false)])
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ")])
        clock.now = clock.now.addingTimeInterval(1)
        store.agentDidChange(Self.grokAgent(.working))
        await store.step()

        // The prompt typed in the terminal runs first.
        clock.now = clock.now.addingTimeInterval(25)
        await files.append(try Self.grokLines("core-turns.jsonl", 5...7), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        await files.append(try Self.grokLines("core-turns.jsonl", 8...8), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// The echo clock runs whenever herdr reports Grok Build neither
    /// Working nor Blocked: ten such seconds without a record make a send
    /// overdue, whatever turns and cards came between them.
    @Test func aGrokSendUnrecordedForTenIdleSecondsIsOverdue() async throws {
        let (_, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let id = UUID()
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ", delivered: false)])
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ")])

        clock.now = clock.now.addingTimeInterval(6)
        store.agentDidChange(Self.grokAgent(.working))
        clock.now = clock.now.addingTimeInterval(20)
        store.agentDidChange(Self.grokAgent(.blocked))
        clock.now = clock.now.addingTimeInterval(15)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        // Polls after the card still leave the busy seconds out.
        store.agentDidChange(Self.grokAgent(.idle))
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// `agent.get` can report a new terminal in the pane before a snapshot
    /// does. Its status replaces the old one on the echo clock too: a send
    /// the old terminal queued runs out once the new one has idled ten
    /// seconds, rather than waiting on a turn that ended with that terminal.
    @Test func theEchoClockFollowsAnAgentReplacedByAQuery() async throws {
        let server = Server(Self.grokAgent(.working))
        let (_, store, clock) = try await Self.grokStore(through: 5, status: .working, server: server)
        let id = UUID()
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ", delivered: false)])
        store.updateSends([Self.sent(id, "Reply with exactly the word ping. ")])

        await server.set(
            Agent(
                terminalID: "term-2", kind: "grok", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
                paneID: "w1:p1", cwd: Self.cwd, revision: 2,
                agentSession: AgentSessionInfo(
                    agent: "grok", kind: .id, source: "herdr:grok", value: Self.grokSession)))
        await store.step()
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// A store following `program`'s transcript while herdr reports the
    /// Agent idle, and that Agent with another status: Claude Code's and
    /// Codex's through the numbered stand-in, Pi's and Oh My Pi's through
    /// their own adapter.
    private static func idleStore(
        _ program: ChatProgram
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, clock: Clock, agent: (AgentStatus) -> Agent) {
        switch program {
        case .pi, .omp:
            let clock = Clock()
            let (files, store, path, _) = try skillStore(program, clock: clock)
            await files.write(piHeader + "\n" + ompMessage("u1", parent: nil, role: "user", "go"), at: path)
            await store.step()
            #expect(store.conversation.phase == .following(path: path))
            return (files, store, clock, { piAgent(program, status: $0) })
        default:
            let (fixture, session, _) = await followed(program, screen: .unavailable)
            return (
                fixture.files, fixture.store, fixture.clock, { agent(session: session, status: $0, program: program) }
            )
        }
    }

    /// Only Grok Build's echo clock stops while it works: every other
    /// program's send still goes overdue 10 s after delivery while herdr
    /// reports the Agent Working.
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func otherProgramsTimeOutBusySendsAsBefore(program: ChatProgram) async throws {
        #expect(ChatTranscriptAdapter.standard(for: program)?.echoClockStopsWhileWorking == false)
        let (_, store, clock, agent) = try await Self.idleStore(program)
        store.agentDidChange(agent(.working))
        let id = UUID()
        store.updateSends([Self.sent(id, "hello ", delivered: false)])
        store.updateSends([Self.sent(id, "hello ")])

        clock.now = clock.now.addingTimeInterval(9)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .overdue)
    }

    // MARK: Grok Build's stale identity

    /// The prompt history in `grokPath`'s folder, and another session of
    /// that folder.
    private static let grokHistory = "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/prompt_history.jsonl"
    private static let otherGrokSession = "01900000-0000-7000-8000-000000000054"
    private static let misdirectedReason =
        "Your last message went to another Grok Build session. Switch back to this conversation in the terminal, so its newest message shows there, or send from the terminal; then send again here."

    /// Grok Build idle with no message on screen, which the session check
    /// says nothing about, and with `core-turns.jsonl`'s first prompt at
    /// the bottom, which it reads as this session.
    private static var quietGrokScreen: ANSIScreen { GrokScreenBuilder(scrollback: []).screen }
    private static var pongScreen: ANSIScreen {
        GrokScreenBuilder(
            scrollback: ["❯ Reply with exactly the word pong.", "", "pong", "", "Worked for 3.4s"]
        ).screen
    }

    /// One line of Grok Build's prompt history, as its serde writes it.
    private static func historyLine(_ prompt: String, session: String = grokSession) throws -> String {
        let record: [String: Any] = [
            "timestamp": "2026-10-20T03:00:00.000Z", "session_id": session, "prompt": prompt, "is_bash": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Holds stats of one path while closed, as a slow Host would.
    private actor HistoryGate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var held = 0
        /// Whether each held stat's task was cancelled once it went on.
        private(set) var cancelledOnRelease: [Bool] = []

        func pass() async {
            guard !isOpen else { return }
            held += 1
            await withCheckedContinuation { waiting.append($0) }
            cancelledOnRelease.append(Task.isCancelled)
        }

        func open() {
            isOpen = true
            for waiter in waiting { waiter.resume() }
            waiting = []
        }

        func close() {
            isOpen = false
        }

        nonisolated func files(_ files: VirtualHostFiles, holding path: String) -> ChatHostFiles {
            let base = files.hostFiles()
            return ChatHostFiles(
                status: { requested in
                    if requested == path { await self.pass() }
                    return try await base.status(requested)
                },
                list: base.list, read: base.read, home: base.home)
        }
    }

    /// A send of `text` whose mark landed before the check that let it go.
    private static func witnessedGrokSend(_ text: String, store: AgentChatStore) async -> UUID {
        let id = UUID()
        store.updateSends([Self.sent(id, text, delivered: false)])
        await store.witnessMarksSettled()
        #expect(store.sendConcern(for: text, after: Self.quietGrokScreen) == nil)
        store.updateSends([Self.sent(id, text)])
        return id
    }

    /// A send of `text` the prompt history says another session took,
    /// read 2 s after it went while Grok Build was idle.
    private static func misdirectedGrokSend(
        _ text: String
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, clock: Clock, id: UUID) {
        let (files, store, clock) = try await grokStore(through: 4, status: .idle)
        await files.write(try historyLine("Reply with exactly the word pong."), at: grokHistory)
        let id = await witnessedGrokSend(text, store: store)
        await files.append(
            try historyLine(GrokTranscriptReducer.echoKey(text), session: otherGrokSession), to: grokHistory)
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        #expect(store.sendStatuses[id] == .misdirected)
        #expect(store.sessionConcern?.reason == misdirectedReason)
        return (files, store, clock, id)
    }

    /// A send's mark is the history's size when the send first shows,
    /// taken once: what was written after it, the send's own line among
    /// it, is what the witness reads.
    @Test func theWitnessMarkFollowsItsSend() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let earlier = try Self.historyLine("Reply with exactly the word pong.")
        await files.write(earlier, at: Self.grokHistory)
        await files.clearRecords()
        let id = UUID()
        let text = "Reply with the word kiwi. "
        store.updateSends([Self.sent(id, text, delivered: false)])
        store.updateSends([Self.sent(id, text, delivered: false)])
        await store.witnessMarksSettled()
        #expect(await files.statuses == [Self.grokHistory])

        // Another session takes a prompt while the check runs.
        await files.append(
            try Self.historyLine("Summarize the README", session: Self.otherGrokSession), to: Self.grokHistory)
        #expect(store.sendConcern(for: text, after: Self.quietGrokScreen) == nil)
        store.updateSends([Self.sent(id, text)])
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()

        let read = try #require(await files.reads.first { $0.path == Self.grokHistory })
        #expect(read.offset == UInt64(earlier.utf8.count) - 1)
        #expect(store.sendStatuses[id] == .misdirected)
    }

    /// A mark landing after the check could postdate the paste.
    @Test func aMarkStillOnItsWayAtTheConcernCheckIsDropped() async throws {
        let gate = HistoryGate()
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle, gate: gate)
        let id = UUID()
        let text = "Reply with the word kiwi. "
        store.updateSends([Self.sent(id, text, delivered: false)])
        try await Self.waitUntil { await gate.held == 1 }

        #expect(store.sendConcern(for: text, after: Self.quietGrokScreen) == nil)
        await gate.open()
        await store.witnessMarksSettled()
        store.updateSends([Self.sent(id, text)])
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        clock.now = clock.now.addingTimeInterval(8)
        await store.step()

        #expect(store.sendStatuses[id] == .overdue)
        #expect(await files.reads.contains { $0.path == Self.grokHistory } == false)
    }

    /// The send never waits for its mark: one the Host is slow to give
    /// goes without a witness.
    @Test func aSlowWitnessMarkNeverHoldsTheSend() async throws {
        let gate = HistoryGate()
        var timing = AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5))
        timing.witnessMarkTimeout = .milliseconds(20)
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle, gate: gate, timing: timing)
        let screen = Self.quietGrokScreen
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(
                rules: ChatSendRules(program: .grok, commands: []), activity: { .idle }, readScreen: { screen },
                sendConcern: { store.sendConcern(for: $0, after: $1) }
            ).preflight)
        let id = UUID()
        let text = "Reply with the word kiwi. "
        store.updateSends([Self.sent(id, text, delivered: false)])
        try await Self.waitUntil { await gate.held == 1 }

        #expect(await preflight("Reply with the word kiwi.") == nil)
        await store.witnessMarksSettled()
        store.updateSends([Self.sent(id, text)])
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        await gate.open()

        #expect(store.sendStatuses[id] == .overdue)
        #expect(await files.reads.contains { $0.path == Self.grokHistory } == false)
    }

    /// A cancelled SFTP request can leave its reply for the next request on
    /// the channel, so the witness never cancels a Host read: a mark or a
    /// read that outlives its deadline runs on, and its answer is dropped.
    @Test func theWitnessNeverCancelsAHostRead() async throws {
        let gate = HistoryGate()
        var timing = AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5))
        timing.witnessMarkTimeout = .milliseconds(20)
        timing.witnessReadTimeout = .milliseconds(20)
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle, gate: gate, timing: timing)

        store.updateSends([Self.sent(UUID(), "Reply with the word kiwi. ", delivered: false)])
        try await Self.waitUntil { await gate.held == 1 }
        await store.witnessMarksSettled()
        await gate.open()
        try await Self.waitUntil { await gate.cancelledOnRelease.count == 1 }

        let id = await Self.witnessedGrokSend("Reply with the word lime. ", store: store)
        await files.append(
            try Self.historyLine("Reply with the word lime.", session: Self.otherGrokSession), to: Self.grokHistory)
        await gate.close()
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        #expect(await gate.held == 2)
        #expect(store.sendStatuses[id] == .awaiting)
        await gate.open()
        try await Self.waitUntil { await gate.cancelledOnRelease.count == 2 }

        #expect(await gate.cancelledOnRelease == [false, false])
    }

    /// Hiding Chat or suspending the app cancels a step mid-read: the read
    /// it cut short is the next step's to take.
    @Test func aWitnessReadACancelledStepCutShortIsTakenAgain() async throws {
        let gate = HistoryGate()
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle, gate: gate)
        await gate.open()
        let id = await Self.witnessedGrokSend("Reply with the word kiwi. ", store: store)
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        await gate.close()
        clock.now = clock.now.addingTimeInterval(2)

        let step = Task { await store.step() }
        try await Self.waitUntil { await gate.held == 1 }
        step.cancel()
        await step.value
        #expect(store.sendStatuses[id] == .awaiting)
        await gate.open()
        await store.step()

        #expect(store.sendStatuses[id] == .misdirected)
        #expect(store.sessionConcern?.raisedBy == id)
    }

    /// Chat registers a send as its check starts, as the Chat surface
    /// does: the mark is on its way during the screen read, lands before
    /// the check keeps it, and the send is witnessed.
    @Test func aSendRegisteredBeforeItsScreenReadIsWitnessed() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        await files.write(try Self.historyLine("Reply with exactly the word pong."), at: Self.grokHistory)
        let id = UUID()
        let text = "Reply with the word kiwi. "
        let screen = Self.quietGrokScreen
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(
                rules: ChatSendRules(program: .grok, commands: []), activity: { .idle },
                readScreen: {
                    // `agent.read` takes longer than the mark's stat.
                    await store.witnessMarksSettled()
                    return screen
                },
                sendConcern: { store.sendConcern(for: $0, after: $1) },
                willReadScreen: { store.updateSends([Self.sent(id, text, delivered: false)]) }
            ).preflight)

        #expect(await preflight("Reply with the word kiwi.") == nil)
        store.updateSends([Self.sent(id, text)])
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()

        #expect(store.sendStatuses[id] == .misdirected)
    }

    /// Grok Build's prompt history names another session for the send:
    /// its echo says so, and every later send is held, whatever the screen
    /// shows of the session it went to.
    @Test func aGrokSendRecordedElsewhereIsMisdirectedAndHoldsLaterSends() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        await files.write(try Self.historyLine("Reply with exactly the word pong."), at: Self.grokHistory)
        let text = "Reply with the word kiwi. "
        let id = await Self.witnessedGrokSend(text, store: store)
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)
        #expect(await files.reads.contains { $0.path == Self.grokHistory } == false)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .misdirected)
        #expect(store.sessionConcern?.reason == Self.misdirectedReason)

        let later = UUID()
        store.updateSends([Self.sent(id, text), Self.sent(later, "Reply with the word lime. ", delivered: false)])
        let elsewhere = GrokScreenBuilder(scrollback: ["❯ Reply with the word kiwi.", "", "kiwi"]).screen
        #expect(store.sendConcern(for: "Reply with the word lime. ", after: elsewhere) == Self.misdirectedReason)
        #expect(
            store.sendConcern(for: "Reply with the word lime. ", after: Self.quietGrokScreen) == Self.misdirectedReason)

        // Its echo clock running out reads nothing more.
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(store.sendStatuses[id] == .misdirected)
        #expect(await files.reads.filter { $0.path == Self.grokHistory }.count == 1)
    }

    /// A send made while Grok Build works waits in its queue, and its line
    /// is written only when its turn starts: the history is read once the
    /// echo clock runs out, not 2 s after delivery.
    @Test func aQueuedSendIsWitnessedOnlyAfterItsTurnRan() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 5, status: .working)
        await files.write(try Self.historyLine("Answer with just the word ok."), at: Self.grokHistory)
        let id = await Self.witnessedGrokSend("Reply with the word kiwi. ", store: store)
        clock.now = clock.now.addingTimeInterval(5)
        await store.step()
        #expect(await files.reads.contains { $0.path == Self.grokHistory } == false)

        // The running turn ends, and the queued message runs in the
        // session the screen shows.
        await files.append(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), to: Self.grokHistory)
        clock.now = clock.now.addingTimeInterval(20)
        await store.step()
        store.agentDidChange(Self.grokAgent(.idle))
        clock.now = clock.now.addingTimeInterval(9)
        await store.step()
        #expect(store.sendStatuses[id] == .awaiting)
        #expect(await files.reads.contains { $0.path == Self.grokHistory } == false)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .misdirected)
        #expect(await files.reads.filter { $0.path == Self.grokHistory }.count == 1)
    }

    /// The history said elsewhere, and the transcript records the send
    /// after all: the transcript wins.
    @Test func aRecordedEchoClearsMisdirectedAndTheConcern() async throws {
        let (files, store, _, id) = try await Self.misdirectedGrokSend("Reply with exactly the word ping. ")

        await files.append(try Self.grokLines("core-turns.jsonl", 8...8), to: Self.grokPath)
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
        #expect(store.sessionConcern == nil)
    }

    /// The misdirected text sent again from Chat once the terminal is back
    /// in this conversation: the copy recorded here is the resend's, which
    /// leaves no echo waiting, and the misdirected echo leaves as it would
    /// for any later prompt.
    @Test func aResendOfAMisdirectedMessageIsTheOneRecorded() async throws {
        let text = "Reply with exactly the word ping. "
        let (files, store, clock, id) = try await Self.misdirectedGrokSend(text)
        clock.now = clock.now.addingTimeInterval(60)
        let resend = UUID()
        store.updateSends([Self.sent(id, text), Self.sent(resend, text, delivered: false)])
        await store.witnessMarksSettled()
        #expect(store.sendConcern(for: text, after: Self.pongScreen) == nil)
        store.updateSends([Self.sent(id, text), Self.sent(resend, text)])
        #expect(store.sendStatuses[id] == .misdirected)

        await files.append(try Self.grokLines("core-turns.jsonl", 8...8), to: Self.grokPath)
        await store.step()

        #expect(store.sendStatuses[resend] == .recorded)
        #expect(store.sendStatuses[id] == .abandoned)
        #expect(store.sessionConcern == nil)
    }

    /// herdr reports another session: Chat follows the one the Agent is
    /// in now.
    @Test func aNewSessionReportClearsTheConcern() async throws {
        let (_, store, _, id) = try await Self.misdirectedGrokSend("Reply with the word kiwi. ")

        store.agentDidChange(Self.agent(session: Self.otherGrokSession, status: .idle, program: .grok))
        await store.step()

        #expect(store.sessionConcern == nil)
        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// A prompt the transcript records since, such as one typed in the
    /// terminal, shows the terminal is back in this conversation. The
    /// misdirected echo has said where its send went by then, and leaves
    /// with the concern rather than stay below the turns after it.
    @Test func aPromptRecordedHereClearsTheConcernAndTheEcho() async throws {
        let (files, store, _, id) = try await Self.misdirectedGrokSend("Reply with the word kiwi. ")
        await store.step()
        #expect(store.sessionConcern != nil)
        #expect(store.sendStatuses[id] == .misdirected)

        await files.append(try Self.grokLines("core-turns.jsonl", 5...5), to: Self.grokPath)
        await store.step()

        #expect(store.sessionConcern == nil)
        #expect(store.sendStatuses[id] == .abandoned)
    }

    @Test func theScreenShowingThisSessionClearsTheConcern() async throws {
        let (_, store, _, _) = try await Self.misdirectedGrokSend("Reply with the word kiwi. ")

        #expect(
            store.sendConcern(for: "Reply with the word lime. ", after: Self.quietGrokScreen) == Self.misdirectedReason)
        #expect(store.sendConcern(for: "Reply with the word lime. ", after: Self.pongScreen) == nil)
        #expect(store.sessionConcern == nil)
    }

    /// The other session's screen keeps the misdirected copy, however
    /// old: where it reads the same as this conversation's newest message,
    /// it never clears the concern.
    @Test func aMisdirectedCopyLikeTheNewestMessageKeepsTheConcern() async throws {
        let (_, store, clock, id) = try await Self.misdirectedGrokSend("Reply with exactly the word pong. ")

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()

        #expect(store.sendStatuses[id] == .misdirected)
        #expect(
            store.sendConcern(for: "Reply with the word lime. ", after: Self.pongScreen) == Self.misdirectedReason)
        #expect(store.sessionConcern?.raisedBy == id)
    }

    /// The conversation as the device saved it records no prompts until
    /// a live read: the Welcome screen holds it all the same.
    @Test func theWelcomeScreenHoldsARestoredConversation() async throws {
        let cache = VolatileChatTranscriptCache()
        _ = try await Self.grokStore(through: 4, status: .idle, cache: cache)
        // The same Agent on a device that can't reach the Host yet.
        let agent = Self.grokAgent(.idle)
        let server = Server(agent)
        await server.fail(with: .channelFailed(detail: "agent.get failed"))
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: agent.paneID), agent: agent, program: .grok,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: VirtualHostFiles().hostFiles(),
                agentInfo: { try await server.read() }, cache: cache, adapter: .grok),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)))
        await store.step()

        #expect(store.conversation.isFromCache)
        #expect(store.conversation.transcript.recordedPrompts.isEmpty)
        #expect(!store.conversation.transcript.needsOlderHistory)
        #expect(
            store.sendConcern(for: "Reply with the word lime. ", after: try ScreenFixture.screen("grok-20-welcome"))
                == GrokSessionCheck.welcomeReason)
    }

    /// The newest message on screen counts only once a transcript read
    /// that started after herdr last reported Grok Build idle has landed:
    /// a prompt typed in the terminal shows before Chat reads it.
    @Test func theNewestMessageCountsOnlyAfterAReadSinceIdle() async throws {
        let server = Server(Self.grokAgent(.working))
        let (_, store, clock) = try await Self.grokStore(through: 4, status: .working, server: server)
        let lime = GrokScreenBuilder(scrollback: ["❯ Reply with the word lime.", "", "lime"]).screen

        clock.now = clock.now.addingTimeInterval(1)
        await server.set(Self.grokAgent(.idle))
        store.agentDidChange(Self.grokAgent(.idle))
        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: lime) == nil)

        await store.step()
        #expect(
            store.sendConcern(for: "Reply with the word kiwi. ", after: lime) == GrokSessionCheck.unknownPromptReason)
    }

    /// Chat's own send shows on screen before the transcript records it.
    /// Once delivered, it says nothing about the session for the echo
    /// timeout; recorded, it is this conversation's newest message.
    @Test func aSendOnItsWayIsNoSignOfAnotherSession() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let ping = GrokScreenBuilder(scrollback: ["❯ Reply with exactly the word ping.", "", "ping"]).screen
        let id = UUID()
        let text = "Reply with exactly the word ping. "
        let lime = "Reply with the word lime. "

        store.updateSends([Self.sent(id, text, delivered: false)])
        #expect(store.sendConcern(for: lime, after: ping) == GrokSessionCheck.unknownPromptReason)
        store.updateSends([Self.sent(id, text)])
        #expect(store.sendConcern(for: lime, after: ping) == nil)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(store.sendStatuses[id] == .overdue)
        #expect(store.sendConcern(for: lime, after: ping) == GrokSessionCheck.unknownPromptReason)

        await files.append(try Self.grokLines("core-turns.jsonl", 8...9), to: Self.grokPath)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
        #expect(store.sendConcern(for: lime, after: ping) == nil)
    }

    /// herdr follows `/new` within its idle recheck: a send held for the
    /// Session line asks herdr at once, and the next one goes.
    @Test func aSessionLineHoldRefreshesTheAgentAndTheNextSendPasses() async throws {
        let server = Server(Self.grokAgent(.idle))
        let (_, store, _) = try await Self.grokStore(through: 4, status: .idle, server: server)
        let screen = try ScreenFixture.screen("grok-17-session-new")
        let reads = await server.reads

        #expect(
            store.sendConcern(for: "Reply with the word kiwi. ", after: screen) == GrokSessionCheck.sessionLineReason)
        await server.set(Self.agent(session: "01900000-0000-7000-8000-000000000001", status: .idle, program: .grok))
        await store.step()

        #expect(await server.reads == reads + 1)
        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: screen) == nil)
    }

    /// herdr reports a new session 60 to 110 ms after its first record, and
    /// Grok Build wrote the first prompt of a session it started from its
    /// Welcome screen 84 ms after that record (live, 2026-10-20). A read of
    /// the session in between finds no message, so the one on screen holds
    /// a send until a read finds it recorded.
    @Test func anEmptyConversationHoldsUntilAReadFindsTheMessageOnScreen() async throws {
        let (files, store, _) = try await Self.grokStore(through: 1, status: .idle)
        #expect(store.conversation.transcript.turns.isEmpty)

        #expect(
            store.sendConcern(for: "Reply with the word kiwi. ", after: Self.pongScreen)
                == GrokSessionCheck.unknownPromptReason)
        await files.append(try Self.grokLines("core-turns.jsonl", 2...4), to: Self.grokPath)
        await store.step()

        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: Self.pongScreen) == nil)
        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: Self.quietGrokScreen) == nil)
    }

    /// The dashboard's view of an agent, as grok-40 to grok-42 draw it at
    /// the phone's 62 columns, its newest message `rows`' last.
    private static func grokAgentView(_ rows: [String]) -> ANSIScreen {
        GrokScreenBuilder(
            columns: 62, scrollback: rows, hints: ["Ctrl+\\:dashboard", "Ctrl+[/]:prev/next agent", "Ctrl+x:stop"],
            header: "Se… │ main /p/t/hcl/pr… 21K / 256K │ ‹ 2/3 › │ [Dashboard]"
        ).screen
    }

    /// Once the dashboard opened an agent, Grok Build keeps that view, also
    /// after `/resume` back to this conversation (1.0.62, live). A send from
    /// Chat goes there only when the newest message is this conversation's.
    @Test func theDashboardsViewOfAnAgentTakesASendOnlyForThisConversation() async throws {
        let (_, store, _) = try await Self.grokStore(through: 4, status: .idle)
        func preflight(_ screen: ANSIScreen) async throws -> ComposerRefusal? {
            let check = try #require(
                ComposerDeliveryPolicy.chat(
                    rules: ChatSendRules(program: .grok, commands: []), activity: { .idle }, readScreen: { screen },
                    sendConcern: { store.sendConcern(for: $0, after: $1) }
                ).preflight)
            return await check("Reply with the word kiwi.")
        }

        #expect(try await preflight(Self.grokAgentView(["❯ Reply with exactly the word pong.", "", "pong"])) == nil)
        #expect(
            try await preflight(try ScreenFixture.screen("grok-40-agent-view-other-62"))
                == .inputNotReady(GrokSessionCheck.agentViewReason))
        #expect(
            try await preflight(Self.grokAgentView(["❯ Reply with exactly the word pong.", "", "❯ /compact"]))
                == .inputNotReady(GrokSessionCheck.agentViewReason))
    }

    /// While herdr reports no session, Chat can't tell whose agent the
    /// dashboard's view shows; the conversation's own view says nothing.
    @Test func theDashboardsViewOfAnAgentHoldsWhileChatFollowsNoSession() async throws {
        let agent = Self.agent(session: nil, status: .idle, program: .grok)
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: agent.paneID), agent: agent, program: .grok,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: VirtualHostFiles().hostFiles(),
                agentInfo: { agent }, cache: VolatileChatTranscriptCache(), adapter: .grok),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)))
        await store.step()
        #expect(store.conversation.phase == .unavailable(.noSession(.grok)))
        let agentView = try ScreenFixture.screen("grok-41-agent-view-this-62")

        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: agentView) == GrokSessionCheck.agentViewReason)
        #expect(store.sendConcern(for: "Reply with the word kiwi. ", after: Self.pongScreen) == nil)
    }

    /// Grok Build may rewrite its history through a rename when a session
    /// starts: a log shorter than the mark says nothing.
    @Test func aRewrittenHistoryFileSaysNothing() async throws {
        let (files, store, clock) = try await Self.grokStore(through: 4, status: .idle)
        let earlier = try (1...3).map { try Self.historyLine("Earlier prompt \($0)") }.joined()
        await files.write(earlier, at: Self.grokHistory)
        let id = await Self.witnessedGrokSend("Reply with the word kiwi. ", store: store)
        await files.write(
            try Self.historyLine("Reply with the word kiwi.", session: Self.otherGrokSession), at: Self.grokHistory)

        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        clock.now = clock.now.addingTimeInterval(8)
        await store.step()

        #expect(store.sendStatuses[id] == .overdue)
        #expect(store.sessionConcern == nil)
    }

    /// Only Grok Build reads its screen for another session and logs its
    /// prompts: other programs' sends take no mark and are never held.
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func otherProgramsTakeNoWitnessMark(program: ChatProgram) async throws {
        let adapter = try #require(ChatTranscriptAdapter.standard(for: program))
        #expect(adapter.sendWitness == nil)
        #expect(adapter.sessionCheck == nil)
        let (files, store, _, _) = try await Self.idleStore(program)
        await files.clearRecords()
        store.updateSends([Self.sent(UUID(), "hello ", delivered: false)])
        await store.witnessMarksSettled()

        #expect(store.sendConcern(for: "hello ", after: try ScreenFixture.screen("grok-17-session-new")) == nil)
        #expect(await files.statuses.isEmpty)
    }

    // MARK: Tool output

    @Test func anExpandedToolRowReadsItsOutputOnce() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built\nok"),
            at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.files.clearRecords()

        fixture.store.loadOutput(id)
        #expect(fixture.store.outputs.loads[id]?.state == .loading)
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()

        #expect(fixture.store.outputs.loads[id]?.state == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built\nok", isTruncated: false))))
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()
        #expect(await fixture.files.reads.count == 1)
    }

    @Test func aRowExpandedWhileTheHostIsOfflineIsReadOnceItConnects() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built"), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.files.clearRecords()

        // The saved conversation still follows, but the Host is gone.
        fixture.store.hostConnectionChanged(false)
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()
        #expect(fixture.store.outputs.loads[id] == nil)
        #expect(await fixture.files.reads.isEmpty)

        fixture.store.hostConnectionChanged(true)
        await fixture.store.outputReadsSettled()
        #expect(
            fixture.store.outputs.loads[id]?.state
                == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built", isTruncated: false))))
    }

    @Test func aRowExpandedWhileTheTranscriptIsMissingIsReadOnceItIsBack() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        let path = Self.path(Self.first)
        let contents = NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built")
        await fixture.files.write(contents, at: path)
        await fixture.store.step()
        // Gone for now: Chat keeps showing what it read.
        await fixture.files.remove(path)
        await fixture.store.step()
        guard case .unavailable = fixture.store.conversation.phase else {
            Issue.record("Expected the transcript to be unavailable, got \(fixture.store.conversation.phase)")
            return
        }
        #expect(Self.ids(fixture.store).contains("t-5"))

        fixture.store.loadOutput(id)
        #expect(fixture.store.outputs.isEmpty)

        await fixture.files.write(contents, at: path)
        fixture.store.retry()
        await fixture.store.step()
        await fixture.store.outputReadsSettled()
        #expect(fixture.store.outputs.loads[id]?.state == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built", isTruncated: false))))
    }

    @Test func aReadForAnEarlierConversationIsDropped() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.tool(5, output: "first"), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.tool(5, output: "second"), at: Self.path(Self.second))
        await fixture.store.step()

        fixture.store.loadOutput(ChatEntryID("t-5"))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        await fixture.store.outputReadsSettled()

        #expect(fixture.store.outputs.isEmpty)
    }

    private static func savedIDs(_ cache: VolatileChatTranscriptCache, _ key: ChatCacheKey) async -> [String] {
        guard case .hit(let document) = await cache.load(key) else { return [] }
        return document.entries.map(\.id.rawValue)
    }

    private static func waitUntil(
        _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting")
    }
}

@MainActor
@Suite("Chat stage exit")
struct ChatStageExitTests {
    @Test func aDisappearOffStageHidesAtOnce() async {
        var hides = 0
        let watch = ChatStageExit.watch(isOnStage: { false }, interval: .milliseconds(5)) { hides += 1 }
        await watch.value
        #expect(hides == 1)
    }

    /// The disappear SwiftUI sends while Chat still shows may be the only
    /// one: the real departure then comes with none.
    @Test func aDisappearOnStageHidesOnceChatLeaves() async throws {
        var onStage = true
        var hides = 0
        let watch = ChatStageExit.watch(isOnStage: { onStage }, interval: .milliseconds(5)) { hides += 1 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(hides == 0)
        onStage = false
        await watch.value
        #expect(hides == 1)
    }

    @Test func appearingAgainCancelsTheWait() async throws {
        var onStage = true
        var hides = 0
        let watch = ChatStageExit.watch(isOnStage: { onStage }, interval: .milliseconds(5)) { hides += 1 }
        try await Task.sleep(for: .milliseconds(20))
        watch.cancel()
        await watch.value
        onStage = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(hides == 0)
    }
}
