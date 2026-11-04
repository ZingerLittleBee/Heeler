import Foundation
import Testing

@testable import Heeler

/// After `/new` leaves a conversation for OpenCode's home screen, herdr
/// keeps reporting it (ADR 0025). Its Chat watches for that screen, and
/// checks herdr's record and the terminal's title before each send. The
/// check narrows, but cannot close, the gap until herdr pastes: a
/// conversation the terminal switches to within it still receives the
/// message. Right after `/new`, until the watch finds the home screen,
/// the screen read before each send holds a message instead.
@MainActor
@Suite("OpenCode Chat store")
struct OpenCodeChatStoreTests {
    private static let host = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000B")!
    /// `store-two-sessions.json`'s conversations.
    private static let apple = "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9"
    private static let other = "ses_0a1b2c3d4e6aW3nT9cXq2LmB8v"
    /// The terminal titles OpenCode writes for them.
    private static let appleTitle = "OC | Apple"
    private static let otherTitle = "OC | Other secret title"
    /// The title OpenCode gives a conversation until it names it.
    private static let fallbackTitle = "New session - 2026-10-20T08:15:30.123Z"
    private static let longTitle = "Summarize the directory listing and its largest files"
    private static let sessionScreen = "opencode-02-session-empty-180"
    private static let homeScreen = "opencode-18-home-after-new-180"

    private static func agent(
        session: String?, title: String?, status: AgentStatus = .idle, program: ChatProgram = .opencode
    ) -> Agent {
        Agent(
            terminalID: "term-1", kind: program.rawValue, title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: "/home/dev/proj", revision: 1, terminalTitle: title,
            terminalTitleStripped: title,
            agentSession: session.map {
                AgentSessionInfo(
                    agent: program.rawValue, kind: .id, source: "herdr:\(program.rawValue)", value: $0)
            })
    }

    /// What `agent.get` answers, and how often it was asked.
    private actor Server {
        private(set) var agent: Agent
        private(set) var reads = 0
        private var failure: TransportError?

        init(_ agent: Agent) {
            self.agent = agent
        }

        func read() throws -> Agent {
            reads += 1
            if let failure { throw failure }
            return agent
        }

        func set(_ agent: Agent) {
            self.agent = agent
        }

        func fail(with failure: TransportError?) {
            self.failure = failure
        }
    }

    /// The Agent's pane as Chat reads it, and how often it was read.
    private actor Pane {
        private var screen: ANSIScreen
        private(set) var reads = 0

        init(_ stem: String) throws {
            screen = try ScreenFixture.screen(stem)
        }

        func read() -> ANSIScreen {
            reads += 1
            return screen
        }

        func show(_ stem: String) throws {
            screen = try ScreenFixture.screen(stem)
        }

        nonisolated var io: BlockedScreenIO {
            BlockedScreenIO(readScreen: { await self.read() }, sendKeys: { _ in }, paste: { _ in })
        }
    }

    /// A scratch OpenCode store holding both conversations, queried the way
    /// a Host's is, and how often it was.
    private actor Database {
        private let harness: OpenCodeSQLiteHarness
        private(set) var queries = 0

        /// `title` replaces the title of the conversation `session`.
        init(title: String, of session: String) throws {
            let harness = try OpenCodeSQLiteHarness(scenario: "two-sessions")
            let quoted = title.replacingOccurrences(of: "'", with: "''")
            try harness.execute("UPDATE session_v2 SET title = '\(quoted)' WHERE id = '\(session)';")
            self.harness = harness
        }

        func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
            queries += 1
            return try harness.response(query)
        }

        /// Only queries reach the store: there are no files to read.
        nonisolated var files: ChatHostFiles {
            let none = TransportError.hostFeatureUnavailable(feature: "Files")
            return ChatHostFiles(
                status: { _ in throw none }, list: { _ in throw none }, read: { _ in throw none },
                home: { throw none }, queryOpenCode: { try await self.response($0) })
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    /// Chat on an idle OpenCode Agent that herdr says is in Apple, shown
    /// without its loop so the test drives every turn.
    @MainActor
    private final class Fixture {
        let database: Database
        let server: Server
        let pane: Pane
        let clock: Clock
        let store: AgentChatStore

        init(
            appleTitle: String = "Apple", terminalTitle: String? = OpenCodeChatStoreTests.appleTitle,
            screen: String = OpenCodeChatStoreTests.sessionScreen
        ) throws {
            let database = try Database(title: appleTitle, of: OpenCodeChatStoreTests.apple)
            let agent = OpenCodeChatStoreTests.agent(session: OpenCodeChatStoreTests.apple, title: terminalTitle)
            let server = Server(agent)
            let pane = try Pane(screen)
            let clock = Clock()
            store = AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: OpenCodeChatStoreTests.host, paneID: agent.paneID), agent: agent,
                program: .opencode,
                source: AgentChatSource(
                    hostID: OpenCodeChatStoreTests.host, socketLocation: .defaultSession, files: database.files,
                    agentInfo: { try await server.read() }, cache: VolatileChatTranscriptCache(), adapter: .openCode,
                    screen: pane.io),
                now: { clock.now })
            self.database = database
            self.server = server
            self.pane = pane
            self.clock = clock
            store.show()
            store.suspend()
        }

        var phase: ChatConversationSnapshot.Phase { store.conversation.phase }

        /// The next turn once the Agent's record is due again.
        func recheck() async {
            clock.now = clock.now.addingTimeInterval(5)
            await store.step()
        }

        /// What herdr answers from now on.
        func report(_ session: String, title: String?, status: AgentStatus = .idle) async {
            await server.set(OpenCodeChatStoreTests.agent(session: session, title: title, status: status))
        }

        /// `/new` in the terminal: OpenCode's home screen and title, while
        /// herdr keeps `session` and Done; then the next record read.
        func leaveForHome(from session: String = OpenCodeChatStoreTests.apple) async throws {
            try await pane.show(OpenCodeChatStoreTests.homeScreen)
            await report(session, title: "OpenCode", status: .done)
            await recheck()
        }
    }

    private static func following(_ session: String) -> ChatConversationSnapshot.Phase {
        .following(path: "opencode:\(session)")
    }

    private static let startScreen = ChatConversationSnapshot.Phase.unavailable(.startScreen(.opencode))

    // MARK: Before a send

    /// herdr reported another conversation since Chat last asked, such as
    /// one picked in the terminal: the send waits while Chat switches.
    @Test func aSendIsRefusedWhenHerdrNowReportsAnotherSession() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.apple))

        await fixture.report(Self.other, title: Self.otherTitle)

        #expect(
            await fixture.store.confirmSessionBeforeSend()
                == "herdr now reports another OpenCode conversation for this Agent. Chat is switching to it; check it, then send again."
        )
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.other))
        #expect(fixture.store.conversation.transcript.title == "Other secret title")
        #expect(await fixture.store.confirmSessionBeforeSend() == nil)
    }

    @Test func aSendIsRefusedWhenTheTerminalTitleNamesAnotherConversation() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        await fixture.report(Self.apple, title: Self.otherTitle)

        #expect(
            await fixture.store.confirmSessionBeforeSend()
                == "OpenCode's terminal shows another conversation (Other secret title). Open this one in the terminal, then send again."
        )
        #expect(fixture.phase == Self.following(Self.apple))
    }

    /// The conversation's own title, cut as OpenCode cuts it, or a title
    /// that says nothing (home, an untitled conversation, the setting off).
    @Test(arguments: ["OC | Fresh", "OpenCode", nil, "OC | Summarize the directory listing and i…"] as [String?])
    func aSendGoesWhenTheTitleMatchesOrSaysNothing(title: String?) async throws {
        let sessionTitle = title?.hasSuffix("…") == true ? Self.longTitle : "Fresh"
        let fixture = try Fixture(appleTitle: sessionTitle, terminalTitle: title)
        await fixture.store.step()
        #expect(fixture.store.conversation.transcript.title == sessionTitle)
        let reads = await fixture.server.reads
        let screenReads = await fixture.pane.reads

        #expect(await fixture.store.confirmSessionBeforeSend() == nil)
        #expect(await fixture.server.reads == reads + 1)
        #expect(await fixture.pane.reads == screenReads)
    }

    /// Without herdr's record, or without a Chat to ask (the view's case),
    /// nothing says which conversation the message would go into.
    @Test func aSendIsRefusedWhenTheRecordCannotBeRead() async throws {
        let refusal = "Heeler couldn't check which conversation OpenCode shows, so it sent nothing. Try again."
        let fixture = try Fixture()
        await fixture.store.step()
        await fixture.server.fail(with: .channelFailed(detail: "closed"))

        #expect(await fixture.store.confirmSessionBeforeSend() == refusal)
        #expect(AgentChatStore.uncheckedSessionReason(.opencode) == refusal)
        #expect(fixture.phase == Self.following(Self.apple))
    }

    // MARK: The start-screen watch

    @Test func theHomeScreenMarksTheReportedSessionStale() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.apple))
        let generation = fixture.store.conversationGeneration

        try await fixture.leaveForHome()

        #expect(fixture.phase == Self.startScreen)
        #expect(!fixture.store.conversation.transcript.entries.isEmpty)
        #expect(fixture.store.conversationGeneration == generation)
        // The conversation herdr still names is no longer read.
        let queries = await fixture.database.queries
        await fixture.recheck()
        await fixture.recheck()
        #expect(await fixture.database.queries == queries)
        #expect(
            await fixture.store.confirmSessionBeforeSend()
                == "OpenCode is on its home screen, so this conversation isn't open there. Open it in the terminal first.")
    }

    /// No banner and no rows: the explanation takes the conversation's
    /// place, whatever Chat keeps of it.
    @Test func theStartScreenHidesTheConversation() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        try await fixture.leaveForHome()
        let conversation = fixture.store.conversation

        #expect(!conversation.transcript.entries.isEmpty)
        for hasPendingEchoes in [false, true] {
            #expect(
                ChatSurfacePresentation(
                    conversation: conversation, hasPendingEchoes: hasPendingEchoes, isHostConnected: true)
                    == .unavailable(.startScreen(.opencode)))
            #expect(
                ChatBannerLine.lines(
                    hostStatus: .connected, conversation: conversation, hasPendingEchoes: hasPendingEchoes
                ).isEmpty)
        }
        let reason = ChatUnavailableReason.startScreen(.opencode)
        #expect(reason.hidesConversation)
        #expect(reason.offersRetry)
        #expect(!reason.isWaiting)
        #expect(reason.title == "Not in This Conversation")
        #expect(!ChatUnavailableReason.noSession(.opencode).hidesConversation)
    }

    /// herdr keeps the old id and Done after `/new`, through each record
    /// read and each Console update; the home screen's title is not the
    /// conversation's, so the screen is not read again.
    @Test func aStaleSessionStaysStaleWhileHerdrRepeatsIt() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        try await fixture.leaveForHome()
        let screenReads = await fixture.pane.reads

        await fixture.recheck()
        fixture.store.agentDidChange(Self.agent(session: Self.apple, title: "OpenCode", status: .done))
        await fixture.store.step()
        await fixture.recheck()

        #expect(fixture.phase == Self.startScreen)
        #expect(await fixture.pane.reads == screenReads)
    }

    /// A first message on the home screen, or a conversation picked there,
    /// makes herdr report it: Chat follows it, through a record read or a
    /// Console update.
    @Test func aNewReportedSessionClearsTheStaleMark() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        try await fixture.leaveForHome()
        try await fixture.pane.show(Self.sessionScreen)
        await fixture.report(Self.other, title: Self.otherTitle)

        await fixture.recheck()

        #expect(fixture.phase == Self.following(Self.other))
        #expect(fixture.store.conversation.transcript.title == "Other secret title")

        try await fixture.leaveForHome(from: Self.other)
        // Done's snapshot brings the Console's record up to herdr's.
        fixture.store.agentDidChange(Self.agent(session: Self.other, title: "OpenCode", status: .done))
        #expect(fixture.phase == Self.startScreen)
        try await fixture.pane.show(Self.sessionScreen)
        await fixture.report(Self.apple, title: Self.appleTitle)
        fixture.store.agentDidChange(Self.agent(session: Self.apple, title: Self.appleTitle))
        // The changed record alone moves Chat, before any record read.
        #expect(fixture.phase == .locating)
        await fixture.store.step()

        #expect(fixture.phase == Self.following(Self.apple))
    }

    /// A conversation picked in the terminal changes no status, so the
    /// Console's record still names the one before it. The Console hands
    /// that older record over again on any update, such as the title the
    /// next pick writes: no report of a conversation, so Chat keeps the
    /// start screen until the screen shows the stale one again.
    @Test func anOlderConsoleRecordKeepsTheStartScreen() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        await fixture.report(Self.other, title: Self.otherTitle)
        await fixture.recheck()
        #expect(fixture.phase == Self.following(Self.other))
        let generation = fixture.store.conversationGeneration
        try await fixture.leaveForHome(from: Self.other)
        #expect(fixture.phase == Self.startScreen)

        try await fixture.pane.show(Self.sessionScreen)
        await fixture.report(Self.other, title: Self.otherTitle)
        fixture.store.agentDidChange(Self.agent(session: Self.apple, title: Self.otherTitle))
        await fixture.store.step()

        #expect(fixture.phase == Self.startScreen)
        #expect(fixture.store.conversationGeneration == generation)

        await fixture.recheck()

        #expect(fixture.phase == Self.following(Self.other))
        #expect(fixture.store.conversationGeneration == generation)
    }

    /// Picking the conversation again shows its own title, which the home
    /// screen never has: Chat resumes it where it was.
    @Test func returningToTheSameTitledConversationClearsTheStaleMark() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        let generation = fixture.store.conversationGeneration
        try await fixture.leaveForHome()
        let screenReads = await fixture.pane.reads
        await fixture.recheck()
        #expect(await fixture.pane.reads == screenReads)

        try await fixture.pane.show(Self.sessionScreen)
        await fixture.report(Self.apple, title: Self.appleTitle)
        await fixture.recheck()

        #expect(fixture.phase == Self.following(Self.apple))
        #expect(fixture.store.conversationGeneration == generation)
        #expect(await fixture.pane.reads == screenReads + 1)
    }

    /// An untitled conversation has the home screen's title, so only herdr
    /// reporting another conversation, or Retry with a conversation on
    /// screen, clears its mark.
    @Test func anUntitledStaleSessionClearsOnlyByReportOrRetry() async throws {
        let fixture = try Fixture(appleTitle: Self.fallbackTitle, terminalTitle: "OpenCode")
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.apple))
        #expect(fixture.store.conversation.transcript.title == nil)
        try await fixture.leaveForHome()
        #expect(fixture.phase == Self.startScreen)

        try await fixture.pane.show(Self.sessionScreen)
        let screenReads = await fixture.pane.reads
        await fixture.recheck()
        await fixture.recheck()
        #expect(fixture.phase == Self.startScreen)
        #expect(await fixture.pane.reads == screenReads)

        fixture.store.retry()
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.apple))

        try await fixture.leaveForHome()
        #expect(fixture.phase == Self.startScreen)
        try await fixture.pane.show(Self.sessionScreen)
        await fixture.report(Self.other, title: Self.otherTitle)
        await fixture.recheck()
        #expect(fixture.phase == Self.following(Self.other))
    }

    /// With OpenCode's title setting off the pane keeps the home screen's
    /// title. Retry reads the screen whatever the title, and only a
    /// conversation there clears the mark.
    @Test func retryOnASessionScreenClearsTheStaleMark() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        try await fixture.leaveForHome()
        let screenReads = await fixture.pane.reads

        fixture.store.retry()
        await fixture.store.step()
        #expect(fixture.phase == Self.startScreen)
        #expect(await fixture.pane.reads == screenReads + 1)

        try await fixture.pane.show(Self.sessionScreen)
        await fixture.recheck()
        #expect(fixture.phase == Self.startScreen)
        #expect(await fixture.pane.reads == screenReads + 1)

        fixture.store.retry()
        await fixture.store.step()
        #expect(fixture.phase == Self.following(Self.apple))
        #expect(await fixture.pane.reads == screenReads + 2)
    }

    /// Once the conversation's title is known, its exact title says
    /// OpenCode shows it, Retry or not. The first turn reads the screen:
    /// the title is unknown until the conversation is read.
    @Test func anExactTitleSkipsTheScreenRead() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        #expect(await fixture.pane.reads == 1)

        for _ in 0..<3 {
            await fixture.recheck()
        }
        fixture.store.retry()
        await fixture.store.step()

        #expect(await fixture.server.reads == 5)
        #expect(await fixture.pane.reads == 1)
        #expect(fixture.phase == Self.following(Self.apple))
    }

    /// Another `OC | ` title, such as a plugin's route or a stale title,
    /// may hide the home screen, so each record read still reads it.
    @Test func aPrefixOnlyTitleStillReadsTheScreen() async throws {
        let fixture = try Fixture()
        await fixture.store.step()
        #expect(await fixture.pane.reads == 1)

        await fixture.report(Self.apple, title: "OC | Appl")
        await fixture.recheck()
        await fixture.report(Self.apple, title: "OC | Settings")
        await fixture.recheck()

        #expect(await fixture.pane.reads == 3)
        #expect(fixture.phase == Self.following(Self.apple))
    }

    // MARK: Programs that report every session

    /// Claude Code, Codex, Pi and Oh My Pi report each conversation they
    /// move to, so their Chat never reads the screen for a home screen,
    /// even one that OpenCode's reader would take for its own, and checks
    /// nothing before a send.
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func programsThatReportEverySessionNeverLookForTheStartScreen(program: ChatProgram) async throws {
        let session = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
        let records = InMemoryRecordSource.Store()
        await records.write(NumberedChatReducer.lines(0..<2))
        let clock = Clock()
        let agent = Self.agent(session: session, title: "OpenCode", program: program)
        let server = Server(agent)
        let pane = try Pane(Self.homeScreen)
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: agent.paneID), agent: agent, program: program,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: VirtualHostFiles().hostFiles(),
                agentInfo: { try await server.read() }, cache: VolatileChatTranscriptCache(),
                adapter: InMemoryRecordSource.adapter(records, sessionID: session), screen: pane.io),
            now: { clock.now })
        store.show()
        store.suspend()

        await store.step()
        for _ in 0..<3 {
            clock.now = clock.now.addingTimeInterval(5)
            await store.step()
        }
        store.retry()
        await store.step()
        store.agentDidChange(Self.agent(session: session, title: "OpenCode", status: .done, program: program))
        await store.step()

        #expect(await server.reads == 6)
        #expect(await pane.reads == 0)
        #expect(store.conversation.phase == .following(path: "memory:\(session)"))
        #expect(!program.leavesSessionWithoutReport)
        #expect(!program.confirmsSessionBeforeSend)
        #expect(await store.confirmSessionBeforeSend() == nil)
        #expect(await server.reads == 6)
    }

    // MARK: Terminal titles

    @Test func titlesTruncateLikeOpenCode() {
        let forty = String(repeating: "a", count: 40)
        let fortyOne = String(repeating: "b", count: 41)
        // The emoji takes UTF-16 units 36 and 37: the cut after 37 splits it.
        let emoji = "abcdefghijklmnopqrstuvwxyz0123456789\u{1F600}tail"

        #expect(OpenCodeTerminalTitle.expected(sessionTitle: "Apple") == "OC | Apple")
        #expect(OpenCodeTerminalTitle.expected(sessionTitle: forty) == "OC | \(forty)")
        #expect(OpenCodeTerminalTitle.expected(sessionTitle: fortyOne) == "OC | \(fortyOne.prefix(37))…")
        #expect(
            OpenCodeTerminalTitle.expected(sessionTitle: Self.longTitle)
                == "OC | Summarize the directory listing and i…")
        #expect(
            OpenCodeTerminalTitle.expected(sessionTitle: emoji)
                == "OC | abcdefghijklmnopqrstuvwxyz0123456789\u{FFFD}…")
        for untitled in [nil, "", Self.fallbackTitle, "Child session - 2026-10-20T08:15:30.123Z"] {
            #expect(OpenCodeTerminalTitle.expected(sessionTitle: untitled) == "OpenCode")
        }
        #expect(OpenCodeTerminalTitle.expected(sessionTitle: "New session - today") == "OC | New session - today")

        #expect(OpenCodeTerminalTitle.verdict(terminalTitle: "OC | Apple", sessionTitle: "Apple") == .matches)
        #expect(
            OpenCodeTerminalTitle.verdict(
                terminalTitle: "OC | Summarize the directory listing and i…", sessionTitle: Self.longTitle)
                == .matches)
        #expect(OpenCodeTerminalTitle.verdict(terminalTitle: "OC | Other", sessionTitle: "Apple") == .differs("Other"))
        #expect(OpenCodeTerminalTitle.verdict(terminalTitle: "OC | Apple", sessionTitle: nil) == .differs("Apple"))
        // The home screen writes `OpenCode` too, so it never matches.
        for title in ["OpenCode", nil, "zsh", "OC |"] as [String?] {
            #expect(OpenCodeTerminalTitle.verdict(terminalTitle: title, sessionTitle: nil) == .saysNothing)
            #expect(OpenCodeTerminalTitle.verdict(terminalTitle: title, sessionTitle: "Apple") == .saysNothing)
        }
    }
}
