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

    private static func agent(host: Host, session: String?, terminalID: String = "t1") -> ConsoleAgent {
        ConsoleAgent(hostID: host.id, hostName: host.displayName, agent: Agent(
            terminalID: terminalID, kind: "codex", title: "Cached task", status: .working,
            workspaceID: "w1", tabID: "tab1", paneID: "w1:p1", cwd: "/project", revision: 1,
            agentSession: session.map { AgentSessionInfo(agent: "codex", kind: .id, source: "herdr:codex", value: $0) }),
            workspaceLabel: "Project", repositoryCheckout: nil)
    }

    private static func reference(_ agent: ConsoleAgent) -> ConversationReference? {
        guard case .bound(let reference) = ConversationReference.resolve(agent.agent.agentSession) else { return nil }
        return reference
    }
}
