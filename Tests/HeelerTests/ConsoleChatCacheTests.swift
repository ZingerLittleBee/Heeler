import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console cached Chat entry points")
struct ConsoleChatCacheTests {
    private static let sessionA = "12345678-1234-4234-8234-123456789abc"
    private static let sessionB = "22345678-1234-4234-8234-123456789abc"

    @Test func coldOfflineConsoleOpensSavedChatWithoutPublishingLiveInventory() async throws {
        let host = Host(address: "offline.invalid", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let agent = Self.agent(host: host, session: Self.sessionA)
        await cache.saveAgentDirectory([ChatCachedAgent(agent)], for: host)
        let reference = try #require(Self.reference(agent))
        let entry = ChatEntry(id: ChatEntryID("saved"), sourceOffset: 10,
                              content: .assistant(ChatAssistantMessage(text: "Saved before disconnect.")))
        await cache.save(ChatCacheDocument(
            key: ChatCacheKey(hostID: host.id, socketLocation: host.socketLocation, reference: reference),
            adapterRevision: CodexRolloutReducer.revision, transcriptPath: "/tmp/transcript.jsonl", head: Data(),
            coverageStart: 0, coverageEnd: 20, reachedStart: true, title: nil, entries: [entry], savedAt: Date()))
        let console = ConsoleStore(chatCache: cache)
        console.setHosts([host])
        await console.cachedChats.settled()
        #expect(console.agents.isEmpty)
        let displayed = try #require(console.chatDisplayAgents.first)
        #expect(displayed.id == agent.id)
        #expect(displayed.agent.status == .unknown)
        #expect(console.chatProgram(for: displayed) == .codex)
        let chat = try #require(console.chatStore(for: displayed, program: .codex))
        await chat.step()
        #expect(chat.conversation.transcript.entries == [entry])
        #expect(console.agents.isEmpty)
        console.setHosts([])
    }

    @Test func liveAgentWithoutSessionOpensItsExactSavedConversation() async throws {
        let host = Host(address: "offline.invalid", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let saved = Self.agent(host: host, session: Self.sessionA)
        await cache.saveAgentDirectory([ChatCachedAgent(saved)], for: host)
        let entry = try await Self.saveTranscript(for: saved, on: host, in: cache)
        let console = ConsoleStore(chatCache: cache)
        console.setHosts([host])
        await console.cachedChats.settled()
        let live = Self.agent(host: host, session: nil)
        console.cachedChats.observe([live], on: host)
        let chat = try #require(console.chatStore(for: live, program: .codex))

        await chat.step()

        #expect(chat.conversation.transcript.entries == [entry])
        #expect(chat.conversation.isFromCache)
        #expect(chat.conversation.phase == .unavailable(.noSession(.codex)))
        #expect(console.agents.isEmpty)
        console.setHosts([])
    }

    @Test func liveMissingBindingWaitsForTheColdDirectoryInsteadOfErasingIt() async throws {
        let host = Host(address: "offline.invalid", username: "reader")
        let cache = DirectoryGateCache()
        let saved = Self.agent(host: host, session: Self.sessionA)
        await cache.saveAgentDirectory([ChatCachedAgent(saved)], for: host)
        let entry = try await Self.saveTranscript(for: saved, on: host, in: cache)
        let console = ConsoleStore(chatCache: cache)
        console.setHosts([host])
        try await Self.waitUntil { await cache.isWaiting }
        let live = Self.agent(host: host, session: nil)
        console.cachedChats.observe([live], on: host)
        console.cachedChats.confirm(live.agent, for: live, on: host)
        let chat = try #require(console.chatStore(for: live, program: .codex))
        let step = Task { await chat.step() }

        await cache.release()
        await step.value
        await console.cachedChats.settled()

        #expect(chat.conversation.transcript.entries == [entry])
        #expect(chat.conversation.phase == .unavailable(.noSession(.codex)))
        #expect(chat.conversation.isFromCache)
        #expect(await cache.loadAgentDirectory(for: host).first?.agentSession?.value == Self.sessionA)
        console.setHosts([])
    }

    @Test func anExplicitLiveSessionWinsOverTheSavedBinding() async throws {
        let host = Host(address: "offline.invalid", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let saved = Self.agent(host: host, session: Self.sessionA)
        let live = Self.agent(host: host, session: Self.sessionB)
        await cache.saveAgentDirectory([ChatCachedAgent(saved)], for: host)
        _ = try await Self.saveTranscript(for: saved, on: host, in: cache)
        let expected = try await Self.saveTranscript(for: live, on: host, in: cache)
        let console = ConsoleStore(chatCache: cache)
        console.setHosts([host])
        let chat = try #require(console.chatStore(for: live, program: .codex))

        await chat.step()

        #expect(chat.conversation.transcript.entries == [expected])
        console.setHosts([])
    }

    @Test(arguments: ["terminal", "workspace", "tab", "kind", "pane", "host"])
    func aNewChatNeverUsesAnotherAgentIdentitysBinding(changed: String) async throws {
        let host = Host(address: "offline.invalid", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let saved = Self.agent(host: host, session: Self.sessionA)
        await cache.saveAgentDirectory([ChatCachedAgent(saved)], for: host)
        _ = try await Self.saveTranscript(for: saved, on: host, in: cache)
        var activeHost = host
        if changed == "host" { activeHost.address = "replacement.invalid" }
        let live = Self.agent(
            host: activeHost, session: nil, terminalID: changed == "terminal" ? "t2" : "t1",
            workspaceID: changed == "workspace" ? "w2" : "w1",
            tabID: changed == "tab" ? "tab2" : "tab1",
            kind: changed == "kind" ? "claude" : "codex", paneID: changed == "pane" ? "w1:p2" : "w1:p1")
        let console = ConsoleStore(chatCache: cache)
        console.setHosts([activeHost])
        let program = try #require(ChatProgram(rawValue: live.agent.kind))
        let chat = try #require(console.chatStore(for: live, program: program))

        await chat.step()

        #expect(chat.conversation.transcript.entries.isEmpty)
        #expect(chat.conversation.phase == .unavailable(.noSession(program)))
        console.setHosts([])
    }

    @Test(arguments: ["empty", "replacement", "explicit"])
    func newerLiveDirectoryUpdatesWinEvenWhenTheDiskLoadIsDelayed(update: String) async throws {
        let host = Host(address: "host", username: "reader")
        let cache = DirectoryGateCache()
        await cache.saveAgentDirectory([ChatCachedAgent(Self.agent(host: host, session: Self.sessionA))], for: host)
        let directory = ConsoleChatCache(cache: cache)
        directory.setHosts([host])
        try await Self.waitUntil { await cache.isWaiting }
        let live = Self.agent(host: host, session: update == "explicit" ? Self.sessionB : nil,
                              terminalID: update == "replacement" ? "t2" : "t1")
        directory.observe(update == "empty" ? [] : [live], on: host)

        await cache.release()
        await directory.settled()

        if update == "explicit" {
            #expect(directory.agents(on: host).first?.agent.agentSession?.value == Self.sessionB)
            #expect(await cache.loadAgentDirectory(for: host).first?.agentSession?.value == Self.sessionB)
        } else {
            #expect(directory.agents(on: host).isEmpty)
            #expect(await cache.loadAgentDirectory(for: host).isEmpty)
        }
    }

    @Test func newerQueriedSessionSurvivesUnchangedSnapshotAndRelaunch() async throws {
        let host = Host(address: "host", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let directory = ConsoleChatCache(cache: cache)
        directory.setHosts([host])
        await directory.settled()
        let old = Self.agent(host: host, session: Self.sessionA)
        directory.observe([old], on: host)
        directory.confirm(Self.agent(host: host, session: Self.sessionB).agent, for: old, on: host)
        directory.observe([old], on: host)
        await directory.settled()
        let reopened = ConsoleChatCache(cache: cache)
        reopened.setHosts([host])
        await reopened.settled()
        #expect(reopened.agents(on: host).first?.agent.agentSession?.value == Self.sessionB)
        // A missing field during reconnect retains the last confirmed binding.
        directory.observe([Self.agent(host: host, session: nil)], on: host)
        await directory.settled()
        #expect(directory.agents(on: host).first?.agent.agentSession?.value == Self.sessionB)
        directory.confirm(Self.agent(host: host, session: nil).agent,
                          for: Self.agent(host: host, session: nil), on: host)
        await directory.settled()
        #expect(await cache.loadAgentDirectory(for: host).first?.agentSession?.value == Self.sessionB)
        // An explicit new binding supersedes the saved one.
        reopened.observe([Self.agent(host: host, session: Self.sessionA)], on: host)
        await reopened.settled()
        #expect(reopened.agents(on: host).first?.agent.agentSession?.value == Self.sessionA)
    }

    @Test func completedEmptySnapshotWinsOverColdRestore() async {
        let host = Host(address: "host", username: "reader")
        let cache = VolatileChatTranscriptCache()
        await cache.saveAgentDirectory([ChatCachedAgent(Self.agent(host: host, session: Self.sessionA))], for: host)
        let directory = ConsoleChatCache(cache: cache)
        directory.setHosts([host])
        directory.observe([], on: host)
        await directory.settled()
        #expect(directory.agents(on: host).isEmpty)
        #expect(await cache.loadAgentDirectory(for: host).isEmpty)
    }

    @Test func editingHostCannotRestoreAnotherServersEntryPoints() async {
        var host = Host(address: "first", username: "reader")
        let cache = VolatileChatTranscriptCache()
        await cache.saveAgentDirectory([ChatCachedAgent(Self.agent(host: host, session: Self.sessionA))], for: host)
        let directory = ConsoleChatCache(cache: cache)
        directory.setHosts([host])
        host.address = "second"
        directory.setHosts([host])
        await directory.settled()
        #expect(directory.agents(on: host).isEmpty)
    }

    @Test func reusedPaneDoesNotInheritThePreviousTerminalSession() async {
        let host = Host(address: "host", username: "reader")
        let cache = VolatileChatTranscriptCache()
        let directory = ConsoleChatCache(cache: cache)
        directory.setHosts([host])
        await directory.settled()
        let previous = Self.agent(host: host, session: nil)
        directory.observe([previous], on: host)
        directory.confirm(Self.agent(host: host, session: Self.sessionA).agent, for: previous, on: host)
        #expect(!directory.agents(on: host).isEmpty)
        let replacement = Self.agent(host: host, session: nil, terminalID: "replacement")
        directory.observe([replacement], on: host)
        directory.confirm(Self.agent(host: host, session: Self.sessionA).agent, for: replacement, on: host)
        await directory.settled()
        #expect(directory.agents(on: host).isEmpty)
    }

    private static func agent(
        host: Host, session: String?, terminalID: String = "t1", workspaceID: String = "w1",
        tabID: String = "tab1", kind: String = "codex", paneID: String = "w1:p1"
    ) -> ConsoleAgent {
        ConsoleAgent(hostID: host.id, hostName: host.displayName, agent: Agent(
            terminalID: terminalID, kind: kind, title: "Cached task", status: .working,
            workspaceID: workspaceID, tabID: tabID, paneID: paneID, cwd: "/project", revision: 1,
            agentSession: session.map { AgentSessionInfo(agent: kind, kind: .id, source: "herdr:\(kind)", value: $0) }),
            workspaceLabel: "Project", repositoryCheckout: nil)
    }

    private static func saveTranscript(
        for agent: ConsoleAgent, on host: Host, in cache: any ChatTranscriptCache
    ) async throws -> ChatEntry {
        let reference = try #require(reference(agent))
        let entry = ChatEntry(id: ChatEntryID(reference.sessionID), sourceOffset: 10,
                              content: .assistant(ChatAssistantMessage(text: reference.sessionID)))
        await cache.save(ChatCacheDocument(
            key: ChatCacheKey(hostID: host.id, socketLocation: host.socketLocation, reference: reference),
            adapterRevision: CodexRolloutReducer.revision, transcriptPath: "/tmp/transcript.jsonl", head: Data(),
            coverageStart: 0, coverageEnd: 20, reachedStart: true, title: nil, entries: [entry], savedAt: Date()))
        return entry
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the directory read")
    }

    /// Suspends only the initial directory load. Documents and persistence
    /// use the real in-memory cache implementation.
    private actor DirectoryGateCache: ChatTranscriptCache {
        private let backing = VolatileChatTranscriptCache()
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        var isWaiting: Bool { gate != nil }

        func release() {
            released = true
            gate?.resume()
            gate = nil
        }

        func loadAgentDirectory(for host: Host) async -> [ChatCachedAgent] {
            let saved = await backing.loadAgentDirectory(for: host)
            if !released { await withCheckedContinuation { gate = $0 } }
            return saved
        }

        func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async {
            await backing.saveAgentDirectory(agents, for: host)
        }

        func load(_ key: ChatCacheKey) async -> ChatCacheLoadResult { await backing.load(key) }
        func save(_ document: ChatCacheDocument) async { await backing.save(document) }
        func remove(_ key: ChatCacheKey) async { await backing.remove(key) }
        func retainHosts(_ hostIDs: Set<UUID>) async { await backing.retainHosts(hostIDs) }
        func removeAll() async { await backing.removeAll() }
        func diskUsage() async -> Int64 { await backing.diskUsage() }
        func prune() async { await backing.prune() }
    }

    private static func reference(_ agent: ConsoleAgent) -> ConversationReference? {
        guard case .bound(let reference) = ConversationReference.resolve(agent.agent.agentSession) else { return nil }
        return reference
    }
}
