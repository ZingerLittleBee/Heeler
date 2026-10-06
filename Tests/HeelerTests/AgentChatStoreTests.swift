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

        init(_ agent: Agent) {
            self.agent = agent
        }

        func read() -> Agent {
            reads += 1
            return agent
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

        init(session: String?, limits: TranscriptFollower.Limits = TranscriptFollower.Limits()) {
            let agent = AgentChatStoreTests.agent(session: session)
            let server = Server(agent)
            let clock = clock
            self.server = server
            store = AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: AgentChatStoreTests.host, paneID: agent.paneID),
                agent: agent, program: .claude,
                source: AgentChatSource(
                    hostID: AgentChatStoreTests.host, socketLocation: .defaultSession,
                    files: files.hostFiles(), agentInfo: { await server.read() }, cache: cache,
                    adapter: NumberedChatReducer.adapter(limits: limits)),
                timing: AgentChatStore.Timing(
                    activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
                now: { clock.now })
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }
    }

    private static func ids(_ store: AgentChatStore) -> [String] {
        store.conversation.transcript.entries.map(\.id.rawValue)
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
