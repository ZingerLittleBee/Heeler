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

    private static func agent(session: String?, status: AgentStatus = .idle) -> Agent {
        Agent(
            terminalID: "term-1", kind: "claude", title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: session.map {
                AgentSessionInfo(agent: "claude", kind: .id, source: "herdr:claude", value: $0)
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

        init(
            session: String?, limits: TranscriptFollower.Limits = TranscriptFollower.Limits(),
            timing: AgentChatStore.Timing = AgentChatStore.Timing(
                activeInterval: .milliseconds(5), idleInterval: .milliseconds(5))
        ) {
            let agent = AgentChatStoreTests.agent(session: session)
            let server = Server(agent)
            let clock = clock
            self.server = server
            store = AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: AgentChatStoreTests.host, paneID: agent.paneID),
                agent: agent, program: .claude,
                source: AgentChatSource(
                    hostID: AgentChatStoreTests.host, socketLocation: .defaultSession,
                    files: files.hostFiles(), agentInfo: { try await server.read() }, cache: cache,
                    adapter: NumberedChatReducer.adapter(limits: limits)),
                timing: timing, now: { clock.now })
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }
    }

    private static func ids(_ store: AgentChatStore) -> [String] {
        store.conversation.transcript.entries.map(\.id.rawValue)
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

    @Test(arguments: [ChatProgram.claude, .codex])
    func missingSessionExplainsTheMissingIdentityWithoutAnInstallDiagnosis(program: ChatProgram) {
        let reason = ChatUnavailableReason.noSession(program)
        #expect(reason.title == "Waiting for Conversation")
        #expect(reason.explanation.contains("session ID"))
        #expect(!reason.explanation.lowercased().contains("install"))
        #expect(reason.offersRetry)
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

        #expect(fixture.store.conversation.phase == .unavailable(.unidentifiedSession))
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
