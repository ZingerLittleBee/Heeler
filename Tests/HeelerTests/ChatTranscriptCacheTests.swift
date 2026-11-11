import Foundation
import Testing

@testable import Heeler

extension ChatTranscriptCache {
    /// Saves entries without a Workspace structure, as most tests need.
    func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async {
        await saveAgentDirectory(ChatAgentDirectory.Contents(agents: agents), for: host)
    }
}

@Suite("Chat transcript cache")
struct ChatTranscriptCacheTests {
    private static let hostA = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    private static let hostB = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000B")!

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    private struct Fixture {
        let root: URL
        let clock = Clock()
        let knownHosts = InMemoryKnownHostsStore()
        let cache: FileChatTranscriptCache

        init(policy: ChatCachePolicy = ChatCachePolicy()) {
            root = FileManager.default.temporaryDirectory
                .appending(path: "ChatCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let clock = clock
            cache = FileChatTranscriptCache(
                root: root, policy: policy, now: { clock.now }, knownHosts: knownHosts)
        }

        func fileURL(_ key: ChatCacheKey) -> URL {
            root.appending(path: "v1/\(key.hostID.uuidString.lowercased())/\(key.storageName).json")
        }

        func setModified(_ key: ChatCacheKey, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL(key).path)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func key(_ host: UUID = hostA, _ id: String = "e951205e-24af-4a5e-baa7-3ccbebd2de2c")
        -> ChatCacheKey
    {
        ChatCacheKey(hostID: host, herdrSession: "", program: .claude, conversationID: id)
    }

    private static func document(
        _ key: ChatCacheKey, entries count: Int = 3, text: String = "hello"
    ) -> ChatCacheDocument {
        ChatCacheDocument(
            key: key, adapterRevision: 1, transcriptPath: "/home/dev/.claude/projects/-k/s.jsonl",
            head: Data(#"{"type":"mode"}"#.utf8), coverageStart: 0,
            coverageEnd: UInt64(count * 100), reachedStart: true,
            title: "Fix the build",
            entries: (0..<count).map { index in
                ChatEntry(
                    id: ChatEntryID("e\(index)"), sourceOffset: UInt64(index * 100),
                    content: .assistant(ChatAssistantMessage(text: "\(text) \(index)")))
            },
            savedAt: Date(timeIntervalSince1970: 1_791_266_400))
    }

    @Test func savedDocumentsLoadBackWhole() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var document = Self.document(Self.key())
        document.turns = [
            ChatTurn(
                firstEntryID: ChatEntryID("e0"), startedAt: Date(timeIntervalSince1970: 1_791_266_142.5),
                endedAt: Date(timeIntervalSince1970: 1_791_266_155), ending: .interrupted),
            ChatTurn(firstEntryID: ChatEntryID("e2")),
        ]

        #expect(await fixture.cache.load(Self.key()) == .miss)
        await fixture.cache.save(document)

        #expect(await fixture.cache.load(Self.key()) == .hit(document))
        // File protection is requested on write; the Simulator does not
        // report it back, so it is checked on a device only.
    }

    @Test func subagentActivitySurvivesTheDiskCache() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var document = Self.document(Self.key())
        document.entries = [ChatEntry(
            id: ChatEntryID("subagent"), sourceOffset: 100,
            content: .tool(ChatToolActivity(
                kind: .agent, name: "SubAgentActivity", title: "Subagent: task", status: .noResult,
                subagentActivity: ChatSubagentActivity(agentPath: "/root/task", events: ["started", "interacted"]))))]
        await fixture.cache.save(document)
        #expect(await fixture.cache.load(Self.key()) == .hit(document))
    }

    @Test func imageHostPathsSurviveTheDiskCache() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var document = Self.document(Self.key())
        document.entries = [ChatEntry(
            id: ChatEntryID("image"), sourceOffset: 100,
            content: .tool(ChatToolActivity(
                kind: .image, name: "ImageView", title: "shot.png", status: .succeeded,
                imagePath: "/work/shot.png")))]
        await fixture.cache.save(document)
        #expect(await fixture.cache.load(Self.key()) == .hit(document))
    }

    /// Only Antigravity CLI marks a question skipped. A question cached
    /// before the mark existed still decodes, as not skipped, so no
    /// program's cached document is dropped for it.
    @Test func skippedQuestionsSurviveTheDiskCache() async throws {
        let json = #"{"text":"Which size?","options":[{"label":"small"}],"isMultiSelect":false,"answer":"small"}"#
        let older = try JSONDecoder().decode(ChatQuestion.self, from: Data(json.utf8))
        #expect(older.answer == "small")
        #expect(!older.isSkipped)

        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var document = Self.document(Self.key())
        document.entries = [ChatEntry(
            id: ChatEntryID("ask"), sourceOffset: 100,
            content: .tool(ChatToolActivity(
                kind: .question, name: "ask_question", title: "Which color? · Which size?", status: .succeeded,
                questions: [
                    ChatQuestion(text: "Which color?", options: ["red", "green"], answer: "green"),
                    ChatQuestion(text: "Which size?", options: ["small", "large"], isSkipped: true),
                ])))]
        await fixture.cache.save(document)
        #expect(await fixture.cache.load(Self.key()) == .hit(document))
    }

    @Test func documentsSavedBeforeChatRecordedALanguageLoadAsEnglish() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var document = Self.document(Self.key())
        document.localization = "ja"
        await fixture.cache.save(document)
        #expect(await fixture.cache.load(Self.key()) == .hit(document))

        // The file as an earlier version wrote it, with no localization.
        let url = fixture.fileURL(Self.key())
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["localization"] as? String == "ja")
        json["localization"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        guard case .hit(let loaded) = await fixture.cache.load(Self.key()) else {
            Issue.record("A document without a localization should still load")
            return
        }
        #expect(loaded.localization == nil)
        #expect(loaded.entries == document.entries)
        #expect(loaded.isWorded(in: "en"))
        #expect(!loaded.isWorded(in: "ja"))
    }

    @Test func olderCachedToolsDecodeWithoutSubagentMetadata() throws {
        let json = #"{"kind":"agent","name":"Agent","title":"Task","status":"succeeded","questions":[]}"#
        let tool = try JSONDecoder().decode(ChatToolActivity.self, from: Data(json.utf8))
        #expect(tool.subagentActivity == nil)
        #expect(tool.imagePath == nil)
    }

    @Test func olderCachedUserMessagesDecodeWithoutImagePaths() throws {
        let json = #"{"text":"[Image #1]look","imageCount":1,"attachmentLabels":[],"wasQueued":false}"#
        let message = try JSONDecoder().decode(ChatUserMessage.self, from: Data(json.utf8))
        #expect(message == ChatUserMessage(text: "[Image #1]look", imageCount: 1))
    }

    @Test func fileNamesRevealNoIdentifiers() {
        let key = ChatCacheKey(
            hostID: Self.hostA, socketLocation: .namedSession("work"),
            reference: ConversationReference(program: .codex, sessionID: "01a10f87-e025-7fb1-8974-8dd09937767a"))
        #expect(key.herdrSession == "name:work")
        #expect(key.storageName.count == 64)
        #expect(!key.storageName.contains("01a10f87"))
        #expect(key.storageName != Self.key().storageName)
    }

    @Test func undecodableAndMismatchedDocumentsAreDropped() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        try Data("not json".utf8).write(to: fixture.fileURL(Self.key()))

        #expect(await fixture.cache.load(Self.key()) == .miss)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL(Self.key()).path))

        // A document filed under another key's name is not that key's.
        let other = Self.key(Self.hostA, "01a10f87-e025-7fb1-8974-8dd09937767a")
        await fixture.cache.save(Self.document(Self.key()))
        try FileManager.default.moveItem(at: fixture.fileURL(Self.key()), to: fixture.fileURL(other))
        #expect(await fixture.cache.load(other) == .miss)
    }

    @Test func removingAHostDeletesItsDocumentsAndRefusesLateSaves() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key(Self.hostA)))
        await fixture.cache.save(Self.document(Self.key(Self.hostB)))

        await fixture.cache.retainHosts([Self.hostB])
        // A save that raced the removal cannot bring the Host's cache back.
        await fixture.cache.save(Self.document(Self.key(Self.hostA)))

        #expect(await fixture.cache.load(Self.key(Self.hostA)) == .miss)
        #expect(await fixture.cache.load(Self.key(Self.hostB)) != .miss)
        let hosts = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "v1").path)
        #expect(hosts == [Self.hostB.uuidString.lowercased()])
    }

    @Test func clearingRemovesEverything() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        #expect(await fixture.cache.diskUsage() > 0)

        await fixture.cache.removeAll()

        #expect(await fixture.cache.diskUsage() == 0)
        #expect(await fixture.cache.load(Self.key()) == .miss)
    }

    @Test func documentsExpireAfterThirtyDays() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        try fixture.setModified(Self.key(), fixture.clock.now)

        fixture.clock.now = fixture.clock.now.addingTimeInterval(29 * 86_400)
        await fixture.cache.prune()
        #expect(await fixture.cache.load(Self.key()) != .miss)

        // Loading refreshed the date; thirty days on from that, it expires.
        fixture.clock.now = fixture.clock.now.addingTimeInterval(31 * 86_400)
        await fixture.cache.prune()
        #expect(await fixture.cache.load(Self.key()) == .miss)
    }

    @Test func overBudgetEvictsTheLeastRecentlyUsed() async throws {
        let size = try JSONEncoder().encode(Self.document(Self.key())).count
        let fixture = Fixture(
            policy: ChatCachePolicy(
                totalBudget: Int64(size * 3 + size / 2), lowWater: Int64(size * 2 + size / 2)))
        defer { fixture.cleanUp() }
        let keys = (0..<4).map { Self.key(Self.hostA, "0000000\($0)-0000-4000-8000-000000000000") }
        for (index, key) in keys.prefix(3).enumerated() {
            await fixture.cache.save(Self.document(key))
            try fixture.setModified(key, fixture.clock.now.addingTimeInterval(Double(index - 10)))
        }
        // The oldest is read, so the second oldest becomes least recent.
        _ = await fixture.cache.load(keys[0])

        await fixture.cache.save(Self.document(keys[3]))

        #expect(await fixture.cache.load(keys[1]) == .miss)
        #expect(await fixture.cache.load(keys[0]) != .miss)
        #expect(await fixture.cache.load(keys[3]) != .miss)
    }

    @Test func anOversizedDocumentKeepsItsNewestEntries() async throws {
        let full = Self.document(Self.key(), entries: 200, text: String(repeating: "w", count: 200))
        let fullSize = try JSONEncoder().encode(full).count
        let fixture = Fixture(policy: ChatCachePolicy(maxDocumentBytes: fullSize / 2))
        defer { fixture.cleanUp() }

        await fixture.cache.save(full)

        guard case .hit(let saved) = await fixture.cache.load(Self.key()) else {
            Issue.record("expected the trimmed document")
            return
        }
        #expect(saved.entries.count < 200)
        #expect(saved.entries.last == full.entries.last)
        #expect(!saved.reachedStart)
        #expect(saved.coverageStart == saved.entries.first?.sourceOffset)
    }

    @Test func leftoversOutsideTheCurrentVersionArePruned() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stale = fixture.root.appending(path: "v0/old.json")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stale)
        let junk = fixture.root.appending(path: "v1/not-a-host/x.json")
        try FileManager.default.createDirectory(
            at: junk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: junk)

        await fixture.cache.prune()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func theVolatileCacheFollowsTheSameHostRule() async {
        let cache = VolatileChatTranscriptCache()
        await cache.save(Self.document(Self.key(Self.hostA)))
        await cache.retainHosts([Self.hostB])
        await cache.save(Self.document(Self.key(Self.hostA)))

        #expect(await cache.load(Self.key(Self.hostA)) == .miss)
        await cache.save(Self.document(Self.key(Self.hostB)))
        #expect(await cache.load(Self.key(Self.hostB)) == .hit(Self.document(Self.key(Self.hostB))))
    }

    private static func cachedAgent(
        for host: Host, sessionID: String = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    ) -> ChatCachedAgent {
        ChatCachedAgent(ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "terminal-1", kind: "codex", title: "Implement caching",
                status: .working, workspaceID: "workspace-1", tabID: "tab-1",
                paneID: "pane-1", cwd: "/home/dev/project", revision: 42, name: "Worker",
                paneTitle: "Chat", agentSession: AgentSessionInfo(
                    agent: "codex", kind: .id, source: "herdr:codex", value: sessionID),
                tokens: ["context": "1000"], stateLabels: ["working": "Busy"], stateChangeSeq: 42,
                foregroundCwd: "/home/dev/project/src"),
            workspaceLabel: "Project", repositoryCheckout: nil, hostUsername: host.username,
            tabLabel: "Work", tabPosition: 2, workspaceTabCount: 3, snapshotOrder: 1,
            paneLabel: "Worker pane"))
    }

    @Test func agentDirectorySurvivesRelaunchWithoutRestoringLiveStatus() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let cached = Self.cachedAgent(for: host)
        await fixture.cache.saveAgentDirectory([cached], for: host)

        let reopened = FileChatTranscriptCache(root: fixture.root, knownHosts: fixture.knownHosts)
        let entries = await reopened.loadAgentDirectory(for: host).agents
        #expect(entries == [cached])
        let restored = try #require(entries.first).consoleAgent(for: host)
        #expect(restored.id == ConsoleAgent.ID(hostID: host.id, paneID: "pane-1"))
        #expect(restored.agent.agentSession == cached.agentSession)
        #expect(restored.agent.status == .unknown)
        #expect(restored.agent.tokens.isEmpty)
        #expect(restored.agent.stateLabels.isEmpty)
        #expect(restored.agent.stateChangeSeq == nil)
        #expect(restored.agent.name == "Worker")
        #expect(restored.agent.title == "Implement caching")
        #expect(restored.directory == "/home/dev/project/src")
        #expect(restored.workspaceLabel == "Project")
        #expect(restored.tabLabel == "Work")
        #expect(restored.paneLabel == "Worker pane")
        #expect(restored.tabPosition == 2)
    }

    @Test func agentDirectoryKeepsItsWorkspaceStructureAndReadsOneSavedWithout() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let cached = Self.cachedAgent(for: host)
        let structure = [
            ChatCachedWorkspace(
                id: "workspace-1", label: "Project",
                checkout: RepositoryCheckout(
                    repoKey: "/home/dev/project/.git", repoName: "project", repoRoot: "/home/dev/project",
                    checkoutPath: "/home/dev/project-wt", isLinkedWorktree: true)),
        ]
        await fixture.cache.saveAgentDirectory(.init(agents: [cached], workspaces: structure), for: host)

        let reopened = FileChatTranscriptCache(root: fixture.root, knownHosts: fixture.knownHosts)
        #expect(await reopened.loadAgentDirectory(for: host) == .init(agents: [cached], workspaces: structure))
        // A structure, with its branches, outlives the last saved entry.
        var branched = structure
        branched[0].branch = .named("worktree/nest")
        await fixture.cache.saveAgentDirectory(.init(agents: [], workspaces: branched), for: host)
        #expect(await reopened.loadAgentDirectory(for: host) == .init(workspaces: branched))
        await fixture.cache.saveAgentDirectory(.init(agents: [cached], workspaces: structure), for: host)

        let url = fixture.root.appending(path: "v1/\(host.id.uuidString.lowercased())/agents.json")
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved.removeValue(forKey: "workspaces") != nil)
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        #expect(await reopened.loadAgentDirectory(for: host) == .init(agents: [cached]))
    }

    /// A Host the device holds no key for yet compares the primary route,
    /// as every directory did before Routes.
    @Test(arguments: [false, true])
    func agentDirectoryWithoutAHostKeyRejectsAChangedPrimaryRoute(volatile: Bool) async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache = volatile ? VolatileChatTranscriptCache() : fixture.cache
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let cached = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([cached], for: host)

        var changed = host
        changed.routes[0].address = "other.example"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.sessionName = "other"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.routes[0].port = 2222
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.username = "other"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.routes[0].jumpAddress = "jump.example"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.routes[0].jumpPort = 2222
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.routes[0].jumpUsername = "jump-user"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = host
        changed.name = "Renamed Host"
        let renamed = await cache.loadAgentDirectory(for: changed).agents
        #expect(renamed == [cached])
        #expect(renamed.first?.consoleAgent(for: changed).hostName == "Renamed Host")
    }

    /// An endpoint's socket names the herdr server; its launcher only runs
    /// herdr for it, so replacing the launcher keeps the bindings.
    @Test(arguments: [false, true])
    func agentDirectoryFollowsTheHerdrEndpointSocket(volatile: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache = volatile ? VolatileChatTranscriptCache() : fixture.cache
        var host = Host(id: Self.hostA, address: "host.example", username: "dev")
        host.herdrEndpoint = try #require(HerdrEndpoint(
            socketPath: "/opt/app/herdr/herdr.sock", executablePath: "/opt/app/bin/herdr"))
        let cached = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([cached], for: host)

        var relaunched = host
        relaunched.herdrEndpoint = HerdrEndpoint(
            socketPath: "/opt/app/herdr/herdr.sock", executablePath: "/opt/app2/bin/herdr")
        #expect(await cache.loadAgentDirectory(for: relaunched).agents == [cached])
        var moved = host
        moved.herdrEndpoint = HerdrEndpoint(
            socketPath: "/opt/other/herdr/herdr.sock", executablePath: "/opt/app/bin/herdr")
        #expect(await cache.loadAgentDirectory(for: moved).agents.isEmpty)
        var plain = host
        plain.herdrEndpoint = nil
        #expect(await cache.loadAgentDirectory(for: plain).agents.isEmpty)
    }

    private static func trust(
        _ byte: UInt8, algorithm: String = "ssh-ed25519", for hostID: UUID,
        in knownHosts: InMemoryKnownHostsStore
    ) async {
        let key = HostKeyTrust.hostKey(hostID)
        await knownHosts.setFingerprint(
            HostKeyFingerprint(digest: Data(repeating: byte, count: 32), algorithm: algorithm),
            host: key.host, port: key.port)
    }

    @Test(arguments: [false, true])
    func agentDirectoryFollowsTheHostKeyRatherThanItsRoutes(volatile: Bool) async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache =
            volatile ? VolatileChatTranscriptCache(knownHosts: fixture.knownHosts) : fixture.cache
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        await Self.trust(1, for: host.id, in: fixture.knownHosts)
        let cached = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([cached], for: host)

        // The same machine on other routes: a new primary, then edited ones.
        var rerouted = host
        rerouted.routes.insert(HostRoute(address: "10.0.0.2"), at: 0)
        #expect(await cache.loadAgentDirectory(for: rerouted).agents == [cached])
        rerouted.routes[0].jumpAddress = "jump.example"
        rerouted.routes[1].address = "elsewhere.example"
        #expect(await cache.loadAgentDirectory(for: rerouted).agents == [cached])
        // The herdr session and account still name other bindings.
        var changed = rerouted
        changed.sessionName = "other"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        changed = rerouted
        changed.username = "other"
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        // So does a Herdr Endpoint's socket, which is another herdr server.
        changed = rerouted
        changed.herdrEndpoint = HerdrEndpoint(
            socketPath: "/opt/app/herdr/herdr.sock", executablePath: "/opt/app/bin/herdr")
        #expect(changed.herdrEndpoint != nil)
        #expect(await cache.loadAgentDirectory(for: changed).agents.isEmpty)
        // Trusting the machine's key for another algorithm keeps them.
        await Self.trust(2, algorithm: "rsa-sha2-512", for: host.id, in: fixture.knownHosts)
        #expect(await cache.loadAgentDirectory(for: rerouted).agents == [cached])
        #expect(await cache.agentDirectoryBelongs(to: rerouted))

        // A replaced key is another machine, whatever the routes say.
        await Self.trust(3, for: host.id, in: fixture.knownHosts)
        #expect(await cache.loadAgentDirectory(for: host).agents.isEmpty)
        #expect(!(await cache.agentDirectoryBelongs(to: host)))
        #expect(await cache.agentDirectoryBelongs(to: Host(id: Self.hostB, address: "b", username: "dev")))
    }

    /// Directories saved before Routes, or before the Host's key was copied
    /// to it on its first connection, still compare the primary route until
    /// the next save records the key.
    @Test(arguments: [false, true])
    func agentDirectoryWithoutAKeyMigratesOnItsPrimaryRoute(volatile: Bool) async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache =
            volatile ? VolatileChatTranscriptCache(knownHosts: fixture.knownHosts) : fixture.cache
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let cached = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([cached], for: host)
        await Self.trust(1, for: host.id, in: fixture.knownHosts)
        var rerouted = host
        rerouted.routes[0].address = "other.example"

        #expect(await cache.loadAgentDirectory(for: host).agents == [cached])
        #expect(await cache.loadAgentDirectory(for: rerouted).agents.isEmpty)
        #expect(!(await cache.agentDirectoryBelongs(to: rerouted)))

        await cache.saveAgentDirectory([cached], for: host)
        #expect(await cache.loadAgentDirectory(for: rerouted).agents == [cached])
    }

    @Test(arguments: [false, true])
    func clearingAndRemovingHostsAlsoRemovesAgentDirectories(volatile: Bool) async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache = volatile ? VolatileChatTranscriptCache() : fixture.cache
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let cached = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([cached], for: host)
        await cache.removeAll()
        #expect(await cache.loadAgentDirectory(for: host).agents.isEmpty)
        await cache.saveAgentDirectory([cached], for: host)
        #expect(await cache.loadAgentDirectory(for: host).agents == [cached])
        await cache.retainHosts([Self.hostB])
        #expect(await cache.loadAgentDirectory(for: host).agents.isEmpty)
        await cache.saveAgentDirectory([cached], for: host)
        #expect(await cache.loadAgentDirectory(for: host).agents.isEmpty)
    }

    @Test(arguments: [false, true])
    func agentDirectoryRejectsUnboundAndForeignAgents(volatile: Bool) async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let cache: any ChatTranscriptCache = volatile ? VolatileChatTranscriptCache() : fixture.cache
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        let other = Host(id: Self.hostB, address: "other.example", username: "dev")
        let valid = Self.cachedAgent(for: host)
        await cache.saveAgentDirectory([
            valid, Self.cachedAgent(for: host, sessionID: "../invalid"), Self.cachedAgent(for: other),
        ], for: host)
        #expect(await cache.loadAgentDirectory(for: host).agents == [valid])
        await cache.saveAgentDirectory([], for: host)
        #expect(await cache.loadAgentDirectory(for: host).agents.isEmpty)
    }

    @Test func agentDirectoriesCountTowardUsageAndExpire() async throws {
        let fixture = Fixture(policy: ChatCachePolicy(maxAge: 60))
        defer { fixture.cleanUp() }
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        await fixture.cache.saveAgentDirectory([Self.cachedAgent(for: host)], for: host)
        #expect(await fixture.cache.diskUsage() > 0)
        let directoryURL = fixture.root.appending(path: "v1/\(host.id.uuidString.lowercased())/agents.json")
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.clock.now], ofItemAtPath: directoryURL.path)
        fixture.clock.now.addTimeInterval(120)
        await fixture.cache.prune()
        #expect(await fixture.cache.loadAgentDirectory(for: host).agents.isEmpty)
        #expect(await fixture.cache.diskUsage() == 0)
    }

    @Test func agentDirectoriesRespectTheTotalBudget() async {
        let fixture = Fixture(policy: ChatCachePolicy(totalBudget: 1, lowWater: 0))
        defer { fixture.cleanUp() }
        let host = Host(id: Self.hostA, address: "host.example", username: "dev")
        await fixture.cache.saveAgentDirectory([Self.cachedAgent(for: host)], for: host)
        #expect(await fixture.cache.diskUsage() == 0)
        #expect(await fixture.cache.loadAgentDirectory(for: host).agents.isEmpty)
    }
}
