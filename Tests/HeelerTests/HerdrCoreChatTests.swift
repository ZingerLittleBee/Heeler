import Foundation
import SwiftUI
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
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
                budget.charge()
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        func waitForChecks(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                if await checks >= count { return }
                try await Task.sleep(for: .milliseconds(10))
                budget.charge()
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

    @Test func chatStaysOffOnOtherKernels() async throws {
        let rig = Rig(host: host)
        try await rig.start(kernel: "FreeBSD")

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
        #expect(!HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: "FreeBSD").chat)
        for kernel in ["Linux", "Darwin"] {
            let capabilities = HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: kernel)
            #expect(capabilities.chat)
            for program in ChatProgram.allCases {
                #expect(capabilities.offersChat(for: program) == (program == .claude))
                #expect(HostCapabilities(serverKind: .herdrTUI).offersChat(for: program))
            }
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

    // MARK: Choosing a conversation

    /// The Agent's detail on its Chat surface, as the Console builds it.
    static func chatDetail(of agent: ConsoleAgent, console: ConsoleStore, defaults: UserDefaults) -> some View {
        let surface = AgentDetailSurfaceSettings(defaults: defaults)
        surface.select(.chat)
        return AgentDetailView(
            agent: agent,
            console: console,
            terminal: TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults),
                zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults)),
            inputMode: AgentInputModeSettings(defaults: defaults),
            detailSurface: surface,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            stage: AgentDetailStage(isVisible: { true }, terminalAccess: { .holds }),
            onSwitch: { _ in },
            onClosed: {})
    }

    /// Activates the element of this label, until a sheet comes up.
    static func opensASheet(
        from label: String, in controller: UIViewController, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var budget = PollBudget(.seconds(10))
        while budget.hasTimeLeft, controller.presentedViewController == nil {
            AccessibilityProbe.elements(labeled: label, in: controller.view).first?.accessibilityActivate()
            try await Task.sleep(for: .milliseconds(50))
            budget.charge()
        }
        #expect(
            controller.presentedViewController != nil, "\(AccessibilityProbe.labels(in: controller.view))",
            sourceLocation: sourceLocation)
    }

    private static let cannotTell = ChatConversationSnapshot.Phase.unavailable(.cannotTellSession(.claude))

    /// With no conversation to show, the screen in Chat's place opens the list (ADR 0034).
    @Test func aChatThatCannotTellOpensTheListFromItsScreen() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()
        let suite = "core-chat-choose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UIHostingController(
            rootView: Self.chatDetail(of: try #require(rig.agent), console: rig.store, defaults: defaults))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await rig.waitUntil("Chat to say it cannot tell") { chat.conversation.phase == Self.cannotTell }
            #expect(chat.conversation.transcript.entries.isEmpty)
            try await Self.opensASheet(from: ChatCandidatePickerView.title, in: controller)
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// Over a conversation it keeps showing, the banner opens the list (ADR 0034).
    @Test func aChatThatCannotTellOverItsConversationOpensTheListFromItsBanner() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        let chat = try rig.chat()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let suite = "core-chat-choose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UIHostingController(
            rootView: Self.chatDetail(of: try #require(rig.agent), console: rig.store, defaults: defaults))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await rig.waitUntil("the conversation") { !chat.conversation.transcript.entries.isEmpty }
            await rig.files.remove("\(Self.home)/.claude/sessions/\(Self.pid).json")
            chat.retry()
            try await rig.waitUntil("Chat to say it cannot tell") { chat.conversation.phase == Self.cannotTell }
            #expect(!chat.conversation.transcript.entries.isEmpty)
            // The banner reads as one element, whose action is its button's.
            let banner = ChatBannerLine.unavailable(.cannotTellSession(.claude), showingSavedMessages: true).text
            try await Self.opensASheet(from: banner, in: controller)
        }
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

    private final class ManualDate: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    /// Counts what would only run again if the loop went round again.
    private actor Rounds {
        private(set) var count = 0

        func note() {
            count += 1
        }
    }

    /// A core Chat outside `ConsoleStore`, so its `now` and pace are the test's.
    private func evidenceStore(
        table: ScriptedProcessTable, files: VirtualHostFiles, rounds: Rounds? = nil,
        timing: AgentChatStore.Timing = AgentChatStore.Timing(), now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> AgentChatStore {
        let record = try HerdrCoreSessionBinderTests.record(pid: Self.pid, foreground: Self.pid)
        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) }, files: files.hostFiles(), clearLabels: { _ in })
        let agent = Agent(
            terminalID: "t1", kind: "claude", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
            paneID: "t1", cwd: "/work/app", revision: 1, agentSession: nil)
        return AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "t1"), agent: agent, program: .claude,
            source: AgentChatSource(
                hostID: host.id, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: {
                    Issue.record("A core Chat asked for the Agent's record")
                    return agent
                },
                cache: VolatileChatTranscriptCache(),
                adapter: try #require(ChatTranscriptAdapter.standard(for: .claude)),
                cachedSession: { _ in
                    await rounds?.note()
                    return nil
                },
                sessionEvidence: { try await binder.check(record) }),
            timing: timing, now: now)
    }

    private static func eventually(
        _ what: String, _ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Everything that polls runs far faster than any real timer here, and each
    /// stage ends after the loop has gone round many times, however long that took.
    @Test func noTimerEverChecks() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "claude", start: Self.start, environment: ["HC_SCOPE": "scope", "HOME": Self.home]))
        let files = VirtualHostFiles(home: Self.home)
        let timing = AgentChatStore.Timing(
            activeInterval: .milliseconds(2), idleInterval: .milliseconds(2),
            locateBackoff: [0.001], sessionRecheck: 0.001, idleSessionRecheck: 0.001)
        let enoughRounds = 20

        // With nothing to bind: each round looks for a saved binding.
        let rounds = Rounds()
        let waiting = try evidenceStore(table: table, files: files, rounds: rounds, timing: timing)
        waiting.show()
        try await Self.eventually("the rounds") { await rounds.count >= enoughRounds }
        #expect(await table.requests.count == 1)
        waiting.end()

        // Bound to a conversation whose file is not there: each round that opens
        // looks for the file.
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        let bound = try evidenceStore(table: table, files: files, timing: timing)
        await files.clearRecords()
        bound.show()
        try await Self.eventually("the opens") { await files.statuses.count >= enoughRounds }
        #expect(await table.requests.count == 2)
        bound.end()

        // Bound to a conversation whose file cannot be read, opening again as it
        // backs off.
        let faults = 500
        await files.failNext(
            .status, path: Self.transcriptPath(), with: TransportError.channelFailed(detail: "read"), count: faults)
        let failing = try evidenceStore(table: table, files: files, timing: timing)
        failing.show()
        try await Self.eventually("the failed opens") {
            let left = await files.faultsLeft(.status, path: Self.transcriptPath())
            return failing.conversation.readFailure != nil && left <= faults - enoughRounds
        }
        #expect(await table.requests.count == 3)
        failing.end()
    }

    /// One check before the Send, and none for the Send having gone or for its
    /// clock passing: neither is one of the events that say the session may have
    /// changed (ADR 0034).
    @Test func aSendAddsNoCheckOfItsOwn() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "claude", start: Self.start, environment: ["HC_SCOPE": "scope", "HOME": Self.home]))
        let files = VirtualHostFiles(home: Self.home)
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await files.write(try Self.transcript(), at: Self.transcriptPath())
        let date = ManualDate()
        let chat = try evidenceStore(table: table, files: files, now: { date.now })
        await chat.step()
        #expect(Self.isFollowing(chat))
        #expect(await table.requests.count == 1)

        let id = UUID()
        chat.updateSends([AgentChatStore.SentMessage(id: id, text: "nothing records this", isDelivered: false)])
        #expect(await chat.confirmSessionBeforeSend() == nil)
        #expect(await table.requests.count == 2)

        chat.updateSends([AgentChatStore.SentMessage(id: id, text: "nothing records this", isDelivered: true)])
        await chat.step()
        #expect(await table.requests.count == 2)

        date.now = date.now.addingTimeInterval(AgentChatStore.Timing().echoTimeout + 1)
        await chat.step()
        #expect(chat.sendStatuses[id] == .overdue)
        await chat.step()
        #expect(await table.requests.count == 2)
    }

    /// A Send whose answer was lost, once the Transcript shows the core delivered it.
    @Test func aSendWithNoAnswerSettlesWhenTheTranscriptRecordsIt() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "claude", start: Self.start, environment: ["HC_SCOPE": "scope", "HOME": Self.home]))
        let files = VirtualHostFiles(home: Self.home)
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try evidenceStore(table: table, files: files)
        await chat.step()

        let id = UUID()
        let text = "the answer to this was lost"
        chat.updateSends([AgentChatStore.SentMessage(id: id, text: text, isDelivered: false)])
        chat.updateSends([AgentChatStore.SentMessage(id: id, text: text, isDelivered: true)])
        await chat.step()
        #expect(chat.sendStatuses[id] == .awaiting)

        await files.append(Self.userLine(text), to: Self.transcriptPath())
        await chat.step()
        #expect(chat.sendStatuses[id] == .recorded)
    }

    private static func userLine(_ text: String) -> String {
        let uuid = UUID().uuidString.lowercased()
        return #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-11-01T00:00:00.000Z","sessionId":"\#(first)","message":{"role":"user","content":"\#(text)"}}"#
            + "\n"
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

    /// The leak check comes back after the check it should have informed.
    @Test func aLeakAnswerAfterTheReasonPointsAtTheHostNotice() async throws {
        let rig = Rig(host: host)
        let name = ChatTranscriptOffVariable.childSession.rawValue
        await rig.transport.setLeakedEnvironment([name])
        await rig.transport.holdLeakAnswers()
        try await rig.start(environment: [name: "1"])
        let chat = try rig.chat()

        chat.show()
        let before = ChatUnavailableReason.transcriptOff(.childSession, coreCarriesIt: false)
        try await rig.waitUntil("the reason") { chat.conversation.phase == .unavailable(before) }

        await rig.transport.releaseLeakAnswers()

        let after = ChatUnavailableReason.transcriptOff(.childSession, coreCarriesIt: true)
        try await rig.waitUntil("the reason to point at the notice") { chat.conversation.phase == .unavailable(after) }
        chat.end()
        rig.store.setHosts([])
    }

    /// Between a new link and its snapshot nothing is known of any Terminal, so a
    /// check says nothing rather than that Chat cannot tell.
    @Test func aCheckBeforeTheSnapshotLeavesAFollowedConversationAlone() async throws {
        let rig = Rig(host: host)
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        let checks = await rig.checks

        // Back from the background: the link comes up before its snapshot.
        await rig.transport.holdSubscribes()
        await rig.store.suspend()
        await rig.store.resume()
        await rig.transport.waitForSubscribe(count: 2)
        try await rig.waitUntil("the link, with no snapshot yet") {
            rig.store.hostStatuses[self.host.id] == .connected && rig.store.hostsAwaitingSnapshot.contains(self.host.id)
        }

        chat.suspend()
        chat.retry()
        await chat.step()

        #expect(Self.isFollowing(chat))
        #expect(await rig.checks == checks)
        // Send has nothing to go on, and says that rather than what it cannot tell.
        #expect(await chat.confirmSessionBeforeSend() == AgentChatStore.uncheckedSessionReason(.claude))
        #expect(Self.isFollowing(chat))

        await rig.transport.releaseSubscribes()
        try await rig.waitUntil("the snapshot") { !rig.store.hostsAwaitingSnapshot.contains(self.host.id) }
        chat.resume()
        try await rig.waitForChecks(checks + 1)
        #expect(Self.isFollowing(chat))
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: An Agent that leaves while Chat shows

    private static let exitedEnd = JSONValue.object(["reason": .string("exited"), "exit_code": .number(0)])
    private static let lostEnd = JSONValue.object(["reason": .string("signaled"), "signal": .number(9)])

    private static func keptRecord() -> JSONValue {
        guard case .object(var fields) = record() else { return record() }
        fields["keep"] = .bool(true)
        return .object(fields)
    }

    private func followedChat(_ rig: Rig) async throws -> (chat: AgentChatStore, agent: ConsoleAgent) {
        try await rig.start()
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.transcript(), at: Self.transcriptPath())
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") { Self.isFollowing(chat) }
        return (chat, try #require(rig.agent))
    }

    @Test func aChatStaysOnItsConversationWhenItsAgentEnds() async throws {
        let rig = Rig(host: host)
        let (chat, agent) = try await followedChat(rig)
        let shown = chat.conversation.transcript.entries.count
        let checks = await rig.checks

        await rig.transport.deliver(Self.event(sequence: 2, type: "finished", data: Self.exitedEnd))
        try await rig.waitUntil("the Agent to leave") { rig.store.agents.isEmpty }

        let departed = try #require(rig.store.detailAgent(for: agent.id))
        #expect(rig.store.chatDeparture(of: agent.id) == .ended)
        #expect(rig.store.chatStore(for: departed, program: .claude) === chat)
        #expect(chat.isVisible)
        #expect(Self.isFollowing(chat))
        #expect(chat.conversation.transcript.entries.count == shown)

        // Nothing is left to look at, so a check runs nothing and says nothing.
        chat.suspend()
        chat.retry()
        await chat.step()
        #expect(await rig.checks == checks)
        #expect(Self.isFollowing(chat))
        // And a Send goes nowhere.
        #expect(await chat.confirmSessionBeforeSend() == AgentChatStore.uncheckedSessionReason(.claude))
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aChatFollowsAProgramTheCoreBroughtBackAtItsAddress() async throws {
        let rig = Rig(host: host, record: Self.keptRecord())
        let (chat, agent) = try await followedChat(rig)
        let checks = await rig.checks

        await rig.transport.deliver(Self.event(sequence: 2, type: "lost", data: Self.lostEnd))
        try await rig.waitUntil("the Agent to leave") { rig.store.agents.isEmpty }
        #expect(rig.store.chatDeparture(of: agent.id) == .restarting)
        let departed = try #require(rig.store.detailAgent(for: agent.id))
        #expect(rig.store.chatStore(for: departed, program: .claude) === chat)
        #expect(chat.isVisible)

        await rig.transport.deliver(
            Self.event(
                sequence: 3, type: "restarted",
                data: Self.record(foreground: ["/bin/zsh"], name: "zsh", status: nil)))
        try await rig.waitUntil("the new shell") { rig.store.chatDeparture(of: agent.id) == .shell }
        #expect(rig.store.chatStore(for: departed, program: .claude) === chat)
        #expect(await rig.checks == checks)

        await rig.files.write(try Self.transcript(session: Self.second), at: Self.transcriptPath(session: Self.second))
        await rig.files.write(
            Self.registryEntry(session: Self.second), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.transport.deliver(
            Self.event(
                sequence: 5, type: "foreground",
                data: Self.foregroundValue(["claude"], name: "claude", pid: Self.pid)))

        try await rig.waitUntil("Chat to follow the new one") { Self.isFollowing(chat, session: Self.second) }
        #expect(rig.store.chatDeparture(of: agent.id) == nil)
        #expect(chat.isVisible)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aDepartedAgentsChatStopsShowingItAsWorking() async throws {
        let rig = Rig(host: host, record: Self.record(status: "working"))
        let (chat, _) = try await followedChat(rig)
        #expect(chat.agent.status == .working)

        await rig.transport.deliver(Self.event(sequence: 2, type: "finished", data: Self.exitedEnd))
        try await rig.waitUntil("the Agent to leave") { rig.store.agents.isEmpty }

        #expect(chat.agent.status == .unknown)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aChatOnScreenGoesOnToTheNewCoresChat() async throws {
        let rig = Rig(host: host)
        let (chat, _) = try await followedChat(rig)

        await rig.transport.setCoreID("c2")
        await rig.transport.endLink()
        try await rig.waitUntil("the new core's Chat") {
            guard let agent = rig.agent else { return false }
            return rig.store.chatStore(for: agent, program: .claude)?.coreScope
                == ChatCacheKey.coreScope(session: "", coreID: "c2")
        }

        let next = try rig.chat()
        #expect(next !== chat)
        #expect(next.isVisible)
        #expect(!chat.isVisible)
        try await rig.waitUntil("the new Chat to follow it") { Self.isFollowing(next) }
        next.end()
        rig.store.setHosts([])
    }

    @Test(arguments: [ChatAgentDeparture.restarting, .ended, .shell])
    func aDepartureIsSaidOverAConversation(_ departure: ChatAgentDeparture) {
        var conversation = ChatConversationSnapshot()
        conversation.transcript.entries = [
            ChatEntry(id: ChatEntryID("e0"), sourceOffset: 0, content: .assistant(ChatAssistantMessage(text: "said")))
        ]
        conversation.phase = .unavailable(.cannotTellSession(.claude))

        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: conversation, hasPendingEchoes: false, departure: departure)

        #expect(lines == [.departure(departure)])
        #expect(
            ChatSurfacePresentation(
                conversation: conversation, hasPendingEchoes: false, isHostConnected: true, departure: departure)
                == .timeline)
    }

    @Test func aDepartureSaysWhatBecameOfTheAgent() {
        #expect(
            ChatBannerLine.departure(.restarting).text
                == "Restarting… The program was lost. A new shell takes its place in a moment.")
        #expect(
            ChatBannerLine.departure(.ended).text == "The Agent ended. Its program exited, so it will not come back.")
        #expect(
            ChatBannerLine.departure(.shell).text
                == "The Agent is gone. A shell runs in its Terminal now. Chat comes back with the next Agent it can read there.")
    }

    @Test(arguments: [ChatAgentDeparture.restarting, .ended, .shell])
    func aDepartureTakesThePlaceOfAConversationNothingShows(_ departure: ChatAgentDeparture) {
        var phases: [ChatConversationSnapshot.Phase] = [.locating, .unavailable(.cannotTellSession(.claude))]
        phases.append(.unavailable(.transcriptOff(.childSession, coreCarriesIt: false)))
        for phase in phases {
            var conversation = ChatConversationSnapshot()
            conversation.phase = phase
            #expect(
                ChatSurfacePresentation(
                    conversation: conversation, hasPendingEchoes: false, isHostConnected: true, departure: departure)
                    == .departed(departure))
            #expect(
                ChatBannerLine.lines(
                    hostStatus: .connected, conversation: conversation, hasPendingEchoes: false, departure: departure)
                    .isEmpty)
        }
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

    /// A check that began on one core read that core's hint.
    @Test func aStaleHintIsNotClearedOnTheCoreThatCameDuringTheCheck() async throws {
        let rig = Rig(
            host: host,
            record: Self.record(labels: ["heeler.chat": #"{"session":"\#(Self.first)","pid":9,"start":"1"}"#]))
        try await rig.start()
        let core = try #require(rig.store.coreProjection(on: host.id))
        let gate = ScriptedTransportCallGate()
        await rig.transport.processTable.hold(using: gate)

        let check = Task { try await core.checkChatSession(paneID: "t1", program: .claude) }
        await gate.waitForEntry()
        await rig.transport.setCoreID("c2")
        await rig.transport.endLink()
        try await rig.waitUntil("the new core's snapshot") { rig.store.hostCores[host.id] == "c2" }
        await gate.open()
        _ = try? await check.value

        #expect(await rig.transport.labelWrites.isEmpty)
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
