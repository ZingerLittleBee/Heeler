import Foundation
import Testing

@testable import Heeler

/// The virtual Host's files as a core transport's services read them.
private struct VirtualHostServices: HostServices {
    let files: VirtualHostFiles
    var heldStatus: HeldFileStatus?

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await files.readRange(range)
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        await heldStatus?.pass(path)
        return try await files.fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        try await files.listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        try await files.home()
    }
}

/// Keeps a stat of one path waiting until the test lets it answer, so an event
/// can arrive while a read is under way.
private actor HeldFileStatus {
    private let path: String
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    var isHolding: Bool { waiting != nil }

    init(path: String) {
        self.path = path
    }

    func pass(_ asked: String) async {
        guard asked == path, !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

/// Claude Code's Chat on a Linux core Host, through `ConsoleStore` and the scripted
/// core transport, with a process table and files the way the Host holds them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreChatTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let pid = 40
    private static let start = "987654321"
    private static let home = "/home/dev"
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        _ address: String = "t1", foreground: [String] = ["claude"], name: String = "claude", pid: Int = pid,
        status: String? = "idle", app: String = "claude-code", labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(Double(pid)),
            "foreground": foregroundValue(foreground, name: name, pid: pid),
            "status": status.map { .object(["state": .string($0), "app": .string(app)]) } ?? .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func foregroundValue(_ argv: [String], name: String, pid: Int) -> JSONValue {
        .object([
            "pid": .number(Double(pid)), "name": .string(name), "argv": .array(argv.map(JSONValue.string)),
            "cwd": .string("/work/app"),
        ])
    }

    private static func subscribeResult(_ terminals: [JSONValue]) -> JSONValue {
        .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
    }

    private static func event(sequence: Int, type: String, terminal: String = "t1", data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private static func statusEvent(sequence: Int, state: String) -> Data {
        event(
            sequence: sequence, type: "status",
            data: .object([
                "status": .object(["state": .string(state), "app": .string("claude-code")]),
                "records": .object([:]), "reported": .bool(true),
            ]))
    }

    private static func registryEntry(session: String = first) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"/work/app","startedAt":1780000000000,\
            "procStart":"\(start)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
    }

    /// One recorded Transcript, under the session it is named for.
    private static func transcript(session: String = first) throws -> Data {
        Data(try ChatFixture.text("claude/probe2-transcript.jsonl").replacingOccurrences(of: first, with: session).utf8)
    }

    private static func transcriptPath(root: String = "\(home)/.claude", session: String = first) -> String {
        "\(root)/projects/-work-app/\(session).jsonl"
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: HerdrCoreChatTests.home)
        let transport: ScriptedCoreTransport
        let cache = VolatileChatTranscriptCache()
        let store: ConsoleStore
        let host: Host

        init(
            host: Host, record: JSONValue = HerdrCoreChatTests.record(), coreID: String = "c1",
            heldStatus: HeldFileStatus? = nil
        ) {
            self.host = host
            transport = ScriptedCoreTransport(
                coreID: coreID, subscribeResults: [HerdrCoreChatTests.subscribeResult([record])],
                services: VirtualHostServices(files: files, heldStatus: heldStatus))
            let transport = transport
            store = ConsoleStore(
                chatCache: cache,
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) })
        }

        /// Connected to a Linux Host whose platform is known, as a detail asks.
        func start(kernel: String? = "Linux", environment: [String: String] = [:]) async throws {
            await transport.processTable.add(
                ScriptedProcessTable.Process(
                    pid: HerdrCoreChatTests.pid, name: "claude", start: HerdrCoreChatTests.start,
                    environment: ["HC_SCOPE": "scope", "HOME": HerdrCoreChatTests.home].merging(environment) { $1 }))
            if let kernel { await transport.setKernel(kernel) }
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
            await store.resolveHostPlatform(host.id)
            if let kernel {
                try await waitUntil("the kernel") { self.store.hostCoreKernels[self.host.id] == kernel }
            }
        }

        var agent: ConsoleAgent? { store.agents.first }

        func chat() throws -> AgentChatStore {
            let agent = try #require(agent)
            return try #require(store.chatStore(for: agent, program: .claude))
        }

        var checks: Int {
            get async { await transport.processTable.requests.count }
        }

        func waitUntil(
            _ what: String, _ condition: @MainActor () -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        func waitForChecks(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<500 {
                if await checks >= count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for check \(count)", sourceLocation: sourceLocation)
        }
    }

    private static func isFollowing(_ chat: AgentChatStore, session: String = first) -> Bool {
        guard case .following(let path) = chat.conversation.phase else { return false }
        return path.hasSuffix("\(session).jsonl")
    }

    // MARK: The offer

    @Test func chatIsOfferedForClaudeCodeOnLinux() async throws {
        let rig = Rig(host: host)
        try await rig.start()

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == .claude)
        #expect(rig.store.capabilities(for: host.id).chat)
        rig.store.setHosts([])
    }

    @Test(arguments: ["Darwin", "FreeBSD"])
    func chatStaysOffOnOtherKernels(_ kernel: String) async throws {
        let rig = Rig(host: host)
        try await rig.start(kernel: kernel)

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == nil)
        #expect(rig.store.chatStore(for: try #require(rig.agent), program: .claude) == nil)
        rig.store.setHosts([])
    }

    @Test func chatWaitsToKnowTheKernel() async throws {
        let rig = Rig(host: host)
        try await rig.start(kernel: nil)

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == nil)
        rig.store.setHosts([])
    }

    @Test func hostCapabilitiesOfferChatOnlyWhereItReads() {
        for platform in [HostPlatform.posix, .nativeWindows, nil] {
            #expect(HostCapabilities(serverKind: .herdrTUI, platform: platform).chat)
            #expect(HostCapabilities(serverKind: .herdrTUI, platform: platform).chatPrograms == nil)
            #expect(!HostCapabilities(serverKind: .unconfirmed, platform: platform, coreKernel: "Linux").chat)
        }
        #expect(!HostCapabilities(serverKind: .herdrCore).chat)
        #expect(!HostCapabilities(serverKind: .herdrCore, platform: .posix).chat)
        #expect(!HostCapabilities(serverKind: .herdrCore, coreKernel: "Linux").chat)
        #expect(!HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows, coreKernel: "Linux").chat)
        #expect(!HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: "Darwin").chat)
        let linux = HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: "Linux")
        #expect(linux.chat)
        for program in ChatProgram.allCases {
            #expect(linux.offersChat(for: program) == (program == .claude))
            #expect(HostCapabilities(serverKind: .herdrTUI).offersChat(for: program))
        }
    }

    @Test(arguments: [
        (["codex"], "codex", "codex"), (["opencode"], "opencode", "opencode"), (["pi"], "pi", "pi"),
        (["omp"], "omp", "omp"), (["grok"], "grok", "grok-build"),
    ])
    func otherProgramsStayOffForNow(_ argv: [String], _ name: String, _ app: String) async throws {
        let rig = Rig(host: host, record: Self.record(foreground: argv, name: name, app: app))
        try await rig.start()

        let agent = try #require(rig.agent)
        #expect(agent.agent.kind == ChatProgram(rawValue: agent.agent.kind)?.rawValue)
        #expect(rig.store.chatProgram(for: agent) == nil)
        rig.store.setHosts([])
    }

    @Test func aProgramHeelerDoesNotKnowGetsNoChat() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["mytool"], name: "mytool", app: "claude"))
        try await rig.start()

        let agent = try #require(rig.agent)
        #expect(ChatProgram(rawValue: agent.agent.kind) == nil)
        #expect(rig.store.chatProgram(for: agent) == nil)
        rig.store.setHosts([])
    }

    /// Past the wait, a Blocked Agent with no screen to read gives the store its
    /// "can't read" card, which only a Composer shows (`HerdrCoreTerminalStoreTests`).
    @Test func aBlockedAgentAsksNothingOfTheCore() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitForChecks(1)

        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "blocked"))
        try await rig.waitUntil("the Agent to read Blocked") { rig.agent?.agent.status == .blocked }
        try await rig.waitForChecks(2)
        try await rig.waitUntil("the store to stop waiting for a dialog") { chat.blocked.content == .unreadable }

        #expect(await rig.transport.mutations.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Before a Send

    @MainActor
    private final class Recorder {
        var steps: [String] = []
    }

    /// Chat's policy over a screen that clears the input box, noting what it did in
    /// order. The Composer on a core goes on to Chat's viewer, which this transport
    /// does not offer, so nothing is typed.
    private static func policy(
        confirmingWith chat: AgentChatStore, order: Recorder
    ) throws -> ComposerDeliveryPolicy {
        let screen = ANSIScreenDecoder.decode(try ScreenFixture.text("claude-01-ready"))
        return .chat(
            rules: ChatSendRules(
                program: .claude, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
            activity: { .idle },
            readScreen: {
                order.steps.append("read")
                return screen
            },
            confirmSession: {
                order.steps.append("confirm")
                return await chat.confirmSessionBeforeSend()
            })
    }

    private static func follow(_ rig: Rig) async throws -> AgentChatStore {
        let chat = try rig.chat()
        await rig.files.write(registryEntry(), at: "\(home)/.claude/sessions/\(pid).json")
        await rig.files.write(try transcript(), at: transcriptPath())
        chat.show()
        try await rig.waitUntil("the Transcript") { isFollowing(chat) }
        return chat
    }

    @Test func aCoreChatAsksTheHostAgainBeforeEachSend() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try await Self.follow(rig)
        #expect(chat.confirmsSessionBeforeSend)
        let composer = rig.store.composerStore(for: try #require(rig.agent))
        composer.open()
        let order = Recorder()
        let policy = try Self.policy(confirmingWith: chat, order: order)
        let settled = await rig.checks

        composer.replaceDraft(with: "first")
        _ = await composer.send(policy: policy)
        let afterFirst = await rig.checks
        composer.replaceDraft(with: "second")
        _ = await composer.send(policy: policy)

        #expect(afterFirst > settled)
        #expect(await rig.checks > afterFirst)
        #expect(order.steps == ["confirm", "read", "confirm", "read"])
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aMovedBindingSendsNothingAndKeepsTheDraft() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try await Self.follow(rig)
        let composer = rig.store.composerStore(for: try #require(rig.agent))
        composer.open()
        let order = Recorder()
        let policy = try Self.policy(confirmingWith: chat, order: order)
        await rig.files.write(try Self.transcript(session: Self.second), at: Self.transcriptPath(session: Self.second))
        await rig.files.write(Self.registryEntry(session: Self.second), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")

        composer.replaceDraft(with: "hello")
        guard case .refused(.inputNotReady(let reason)) = await composer.send(policy: policy) else {
            Issue.record("Expected a refusal")
            return
        }

        #expect(reason.contains("now shows another conversation"))
        #expect(composer.draft == "hello")
        #expect(order.steps == ["confirm"])
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aBindingTheHostNoLongerShowsSendsNothingAndKeepsTheDraft() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try await Self.follow(rig)
        let composer = rig.store.composerStore(for: try #require(rig.agent))
        composer.open()
        let order = Recorder()
        let policy = try Self.policy(confirmingWith: chat, order: order)
        await rig.files.remove("\(Self.home)/.claude/sessions/\(Self.pid).json")

        composer.replaceDraft(with: "hello")
        guard case .refused(.inputNotReady(let reason)) = await composer.send(policy: policy) else {
            Issue.record("Expected a refusal")
            return
        }

        #expect(reason.contains("can't tell which conversation"), "\(reason)")
        #expect(composer.draft == "hello")
        #expect(order.steps == ["confirm"])
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: When it checks

    @Test func openingChatChecksOnceAndFollowsTheConversation() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        #expect(await rig.checks == 0)

        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }

        #expect(await rig.checks == 1)
        #expect(chat.conversation.transcript.entries.isEmpty == false)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aChatNotOpenChecksNothing() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        _ = try rig.chat()

        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "working"))
        try await rig.waitUntil("the status") { rig.agent?.agent.status == .working }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await rig.checks == 0)
        rig.store.setHosts([])
    }

    /// Each of these events, and only these, says the session may have changed.
    @Test func statusTurnAndForegroundEventsEachCheckAgain() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitForChecks(1)

        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "working"))
        try await rig.waitForChecks(2)

        await rig.transport.deliver(
            Self.event(sequence: 3, type: "turn", data: .object(["turn": .number(1), "reason": .string("status")])))
        try await rig.waitForChecks(3)

        await rig.transport.deliver(
            Self.event(
                sequence: 4, type: "foreground",
                data: Self.foregroundValue(["claude"], name: "claude", pid: Self.pid)))
        try await rig.waitForChecks(4)

        await rig.transport.deliver(
            Self.event(sequence: 5, type: "title", data: .object(["title": .string("a title")])))
        try await rig.waitUntil("the title") { rig.store.agents.first?.agent.title == "a title" }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await rig.checks == 4)
        chat.end()
        rig.store.setHosts([])
    }

    /// Everything that polls runs far faster than any real timer here.
    @Test func noTimerEverChecks() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "claude", start: Self.start, environment: ["HC_SCOPE": "scope", "HOME": Self.home]))
        let files = VirtualHostFiles(home: Self.home)
        let record = try HerdrCoreSessionBinderTests.record(pid: Self.pid, foreground: Self.pid)
        let binder = HerdrCoreSessionBinder(
            processes: { try await table.read($0) }, files: files.hostFiles(), clearLabels: { _ in })
        let agent = Agent(
            terminalID: "t1", kind: "claude", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
            paneID: "t1", cwd: "/work/app", revision: 1, agentSession: nil)
        func make() -> AgentChatStore {
            AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: "t1"), agent: agent, program: .claude,
                source: AgentChatSource(
                    hostID: host.id, socketLocation: .defaultSession, files: files.hostFiles(),
                    agentInfo: {
                        Issue.record("A core Chat asked for the Agent's record")
                        return agent
                    },
                    cache: VolatileChatTranscriptCache(),
                    adapter: try! #require(ChatTranscriptAdapter.standard(for: .claude)),
                    sessionEvidence: { try await binder.check(record) }),
                timing: AgentChatStore.Timing(
                    activeInterval: .milliseconds(2), idleInterval: .milliseconds(2),
                    locateBackoff: [0.001], sessionRecheck: 0.001, idleSessionRecheck: 0.001))
        }

        // With nothing to bind.
        let waiting = make()
        waiting.show()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await table.requests.count == 1)
        waiting.end()

        // Bound to a conversation whose file is not there.
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        let bound = make()
        bound.show()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await table.requests.count == 2)
        bound.end()

        // Bound to a conversation whose file cannot be read, opening again as it
        // backs off.
        await files.failNext(
            .status, path: Self.transcriptPath(), with: TransportError.channelFailed(detail: "read"), count: 500)
        let failing = make()
        failing.show()
        try await Task.sleep(for: .milliseconds(200))
        #expect(failing.conversation.readFailure != nil)
        #expect(await table.requests.count == 3)
        failing.end()
    }

    /// `/clear` while Chat reads the old conversation's file, and that read fails:
    /// the turn it reported still gets its check.
    @Test func anEventDuringAFailedOpenStillChecks() async throws {
        let held = HeldFileStatus(path: Self.transcriptPath())
        let rig = Rig(host: host, heldStatus: held)
        try await rig.start()
        let entry = "\(Self.home)/.claude/sessions/\(Self.pid).json"
        await rig.files.write(Self.registryEntry(), at: entry)
        await rig.files.failNext(
            .status, path: Self.transcriptPath(), with: TransportError.channelFailed(detail: "read"))
        let chat = try rig.chat()
        chat.show()
        for _ in 0..<500 where await !held.isHolding {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await held.isHolding)

        await rig.files.write(Self.registryEntry(session: Self.second), at: entry)
        await rig.files.write(try Self.transcript(session: Self.second), at: Self.transcriptPath(session: Self.second))
        await rig.transport.deliver(
            Self.event(sequence: 2, type: "turn", data: .object(["turn": .number(1), "reason": .string("status")])))
        // Events arrive in order: by this title the turn has reached the Chat.
        await rig.transport.deliver(
            Self.event(sequence: 3, type: "title", data: .object(["title": .string("a title")])))
        try await rig.waitUntil("the title") { rig.store.agents.first?.agent.title == "a title" }
        await held.release()

        try await rig.waitUntil("Chat to follow the new one") { Self.isFollowing(chat, session: Self.second) }
        #expect(await rig.checks == 2)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func retryChecksAgain() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitForChecks(1)

        chat.retry()
        try await rig.waitForChecks(2)

        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Following

    @Test func aClearRebindsToTheNewConversation() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let entry = "\(Self.home)/.claude/sessions/\(Self.pid).json"
        await rig.files.write(Self.registryEntry(), at: entry)
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        let generation = chat.conversationGeneration

        await rig.files.write(Self.registryEntry(session: Self.second), at: entry)
        await rig.files.write(try Self.transcript(session: Self.second), at: Self.transcriptPath(session: Self.second))
        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "working"))

        try await rig.waitUntil("Chat to follow the new one") { Self.isFollowing(chat, session: Self.second) }
        #expect(chat.conversationGeneration > generation)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aConversationWithNoFileYetIsOneStillToStart() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        let chat = try rig.chat()

        chat.show()

        try await rig.waitUntil("the empty conversation") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude))
        }
        chat.end()
        rig.store.setHosts([])
    }

    @Test func theTranscriptIsReadFromTheAgentsOwnConfigDir() async throws {
        let rig = Rig(host: host)
        let root = "/srv/work account"
        try await rig.start(environment: ["CLAUDE_CONFIG_DIR": root])
        await rig.files.write(Self.registryEntry(), at: "\(root)/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath(root: root))
        let chat = try rig.chat()

        chat.show()

        try await rig.waitUntil("Chat to follow it") {
            if case .following(let path) = chat.conversation.phase { return path == Self.transcriptPath(root: root) }
            return false
        }
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aFailedCheckSaysSoAndRetrySucceeds() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.transport.processTable.setFailure(.timedOut)
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("the failure") { chat.conversation.readFailure != nil }

        await rig.transport.processTable.setFailure(nil)
        chat.retry()

        try await rig.waitUntil("the binding") {
            chat.conversation.readFailure == nil
                && chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude))
        }
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Reasons

    @Test func anAgentWithNoEvidenceSaysChatCannotTell() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()

        chat.show()

        try await rig.waitUntil("the reason") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.claude))
        }
        let reason = ChatUnavailableReason.cannotTellSession(.claude)
        #expect(reason.explanation.contains("can't tell"))
        #expect(reason.offersRetry)
        chat.end()
        rig.store.setHosts([])
    }

    @Test(arguments: [
        ("CLAUDE_CODE_CHILD_SESSION", ChatTranscriptOffVariable.childSession, "neither a session record nor a transcript"),
        ("CLAUDE_CODE_SKIP_PROMPT_HISTORY", ChatTranscriptOffVariable.skipPromptHistory, "keeps no transcript"),
    ])
    func aLeakedVariableIsTheReason(_ name: String, _ variable: ChatTranscriptOffVariable, _ effect: String) async throws {
        let rig = Rig(host: host)
        try await rig.start(environment: [name: "1"])
        let chat = try rig.chat()

        chat.show()

        let reason = ChatUnavailableReason.transcriptOff(variable, coreCarriesIt: false)
        try await rig.waitUntil("the reason") { chat.conversation.phase == .unavailable(reason) }
        #expect(reason.explanation.contains(name))
        #expect(reason.explanation.contains(effect))
        #expect(!reason.explanation.contains("Host's details"))
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aVariableTheCoreCarriesPointsAtTheHostNotice() async throws {
        let rig = Rig(host: host)
        let name = ChatTranscriptOffVariable.childSession.rawValue
        await rig.transport.setLeakedEnvironment([name])
        try await rig.start(environment: [name: "1"])
        try await rig.waitUntil("the notice") { rig.store.hostCoreEnvironmentNotices[self.host.id] != nil }
        let chat = try rig.chat()

        chat.show()

        let reason = ChatUnavailableReason.transcriptOff(.childSession, coreCarriesIt: true)
        try await rig.waitUntil("the reason") { chat.conversation.phase == .unavailable(reason) }
        #expect(reason.explanation.contains("Host's details"))
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aReasonKeepsWhatChatShowedAndAFreshBindingResumesIt() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let entry = "\(Self.home)/.claude/sessions/\(Self.pid).json"
        await rig.files.write(Self.registryEntry(), at: entry)
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        let shown = chat.conversation.transcript.entries.count
        let generation = chat.conversationGeneration

        await rig.files.remove(entry)
        chat.retry()
        try await rig.waitUntil("the reason") { chat.conversation.phase == .unavailable(.cannotTellSession(.claude)) }
        #expect(chat.conversation.transcript.entries.count == shown)

        await rig.files.write(Self.registryEntry(), at: entry)
        chat.retry()
        try await rig.waitUntil("Chat to follow it again") { Self.isFollowing(chat) }
        #expect(chat.conversationGeneration == generation)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Hints

    @Test func aStaleHintIsClearedOnTheCore() async throws {
        let rig = Rig(
            host: host,
            record: Self.record(labels: ["heeler.chat": #"{"session":"\#(Self.first)","pid":9,"start":"1"}"#]))
        try await rig.start()
        let chat = try rig.chat()

        chat.show()
        try await rig.waitUntil("the reason") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.claude))
        }

        let write = try #require(await rig.transport.labelWrites.first)
        #expect(write["terminal"]?.stringValue == "t1")
        #expect(write["labels"]?["heeler.chat"]?.stringValue == "")
        #expect(await rig.transport.mutations == ["terminal.label"])
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aMatchingHintBindsWithNoRegistryEntry() async throws {
        let rig = Rig(
            host: host,
            record: Self.record(labels: [
                "heeler.session": #"{"session":"\#(Self.first)","pid":\#(Self.pid),"start":"\#(Self.start)"}"#
            ]))
        try await rig.start()
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()

        chat.show()

        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        #expect(await rig.transport.labelWrites.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Cache

    private func key(coreID: String, session: String = "default") -> ChatCacheKey {
        ChatCacheKey(
            hostID: host.id, socketLocation: host.socketLocation,
            reference: ConversationReference(program: .claude, sessionID: Self.first),
            coreScope: ChatCacheKey.coreScope(session: session, coreID: coreID))
    }

    @Test func twoCoresOrTwoCoreSessionsNeverShareEntries() {
        #expect(key(coreID: "c1") != key(coreID: "c2"))
        #expect(key(coreID: "c1").storageName != key(coreID: "c2").storageName)
        #expect(key(coreID: "c1", session: "a") != key(coreID: "c1", session: "b"))
        #expect(key(coreID: "c1", session: "a").storageName != key(coreID: "c1", session: "b").storageName)
        // An unnamed session and the default one are the same core session.
        #expect(key(coreID: "c1", session: "") == key(coreID: "c1", session: "default"))
    }

    @Test func aHerdrTUICacheKeyIsWhatItAlwaysWas() {
        let reference = ConversationReference(program: .claude, sessionID: Self.first)
        let named = ChatCacheKey(hostID: host.id, socketLocation: .namedSession("work"), reference: reference)
        #expect(named.herdrSession == "name:work")
        let plain = ChatCacheKey(hostID: host.id, socketLocation: .defaultSession, reference: reference)
        #expect(plain.herdrSession == "")
    }

    @Test func aChatSavesUnderItsCoreAndAnotherCoreStartsOver() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        chat.hide()
        for _ in 0..<500 {
            if case .hit = await rig.cache.load(key(coreID: "c1")) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .hit = await rig.cache.load(key(coreID: "c1")) else {
            Issue.record("Nothing saved under the first core")
            return
        }
        guard case .miss = await rig.cache.load(key(coreID: "c2")) else {
            Issue.record("Saved under a core it never read")
            return
        }

        await rig.transport.setCoreID("c2")
        await rig.transport.endLink()
        try await rig.waitUntil("the new core's Chat") {
            guard let agent = rig.agent else { return false }
            return rig.store.chatStore(for: agent, program: .claude)?.coreScope
                == ChatCacheKey.coreScope(session: "", coreID: "c2")
        }
        let next = try rig.chat()
        #expect(next !== chat)
        #expect(next.coreScope != chat.coreScope)
        next.end()
        rig.store.setHosts([])
    }
}
