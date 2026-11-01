import Foundation
import Testing

@testable import Heeler

/// The virtual Host's files and OpenCode's store, as a core transport's services
/// read them.
private struct ProgramChatServices: HostServices {
    let files: VirtualHostFiles
    var store: OpenCodeStoreStub?

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await files.readRange(range)
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        try await files.fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        try await files.listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        try await files.home()
    }

    func queryOpenCode(_ query: OpenCodeQuery) async throws -> OpenCodeQueryResponse {
        guard let store else { throw TransportError.hostFeatureUnavailable(feature: "Chat") }
        return try await store.response(query)
    }
}

/// A store with no row for the session until OpenCode's first prompt makes one.
private actor OpenCodeStoreStub {
    private let harness: OpenCodeSQLiteHarness
    private var hasRow = false

    init(harness: OpenCodeSQLiteHarness) {
        self.harness = harness
    }

    func takeFirstPrompt() {
        hasRow = true
    }

    func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
        hasRow ? try harness.response(query) : .sessionMissing(otherStores: [])
    }
}

/// Chat for Codex, Grok Build and OpenCode on a Linux core Host, through
/// `ConsoleStore` and the scripted core transport. Their processes come from the
/// recordings in `ChatFixtures/host-evidence`, and their Transcripts from the
/// captures Chat's own suites read.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreProgramChatTests {
    private static let home = "/home/dev"
    private static let accountRoot = "/srv/work account"
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        pid: Int = 40, foreground: [String], name: String, app: String, status: String? = "idle",
        labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array(foreground.map(JSONValue.string)), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(Double(pid)),
            "foreground": .object([
                "pid": .number(Double(pid)), "name": .string(name),
                "argv": .array(foreground.map(JSONValue.string)), "cwd": .string("/work/app"),
            ]),
            "status": status.map { .object(["state": .string($0), "app": .string(app)]) } ?? .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func statusEvent(sequence: Int, state: String, app: String) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("status"), "terminal": .string("t1"),
                "data": .object([
                    "status": .object(["state": .string(state), "app": .string(app)]),
                    "records": .object([:]), "reported": .bool(true),
                ]),
            ]),
        ]))) ?? Data()
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: HerdrCoreProgramChatTests.home)
        let transport: ScriptedCoreTransport
        let store: ConsoleStore
        let host: Host

        init(host: Host, record: JSONValue, openCodeStore: OpenCodeStoreStub? = nil) {
            self.host = host
            let result = JSONValue.object([
                "seq": .number(1), "terminals": .array([record]), "channel": .number(1),
            ])
            transport = ScriptedCoreTransport(
                coreID: "c1", subscribeResults: [result],
                services: ProgramChatServices(files: files, store: openCodeStore))
            let transport = transport
            store = ConsoleStore(
                chatCache: VolatileChatTranscriptCache(),
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) })
        }

        func start(
            _ rows: [ScriptedProcessTable.Process], kernel: String = "Linux",
            turningOn programs: Set<ChatProgram> = Set(ChatProgram.allCases)
        ) async throws {
            for row in rows { await transport.processTable.add(row) }
            await transport.setKernel(kernel)
            store.coreChatPrograms = programs
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
            await store.resolveHostPlatform(host.id)
            try await waitUntil("the kernel") { self.store.hostCoreKernels[self.host.id] == kernel }
        }

        var agent: ConsoleAgent? { store.agents.first }

        func chat(_ program: ChatProgram) throws -> AgentChatStore {
            let agent = try #require(agent)
            return try #require(store.chatStore(for: agent, program: program))
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
    }

    private static func process(
        pid: Int = 40, parent: Int = 1, name: String, start: String = "111", environment: [String: String],
        argv: [String] = [], files: [String] = []
    ) -> ScriptedProcessTable.Process {
        ScriptedProcessTable.Process(
            pid: pid, parent: parent, name: name, start: start,
            environment: ["HC_SCOPE": "scope", "HOME": home].merging(environment) { $1 }, argv: argv, files: files)
    }

    // MARK: The offer

    private static let programs: [(program: ChatProgram, argv: [String], name: String, app: String)] = [
        (.codex, ["codex", "--no-daemon"], "codex", "codex"),
        (.grok, ["grok"], "grok", "grok-build"),
        (.opencode, ["opencode"], "opencode", "opencode"),
    ]

    private func offerRig(_ program: ChatProgram) throws -> (Rig, [ScriptedProcessTable.Process]) {
        let entry = try #require(Self.programs.first { $0.program == program })
        let rig = Rig(
            host: host, record: Self.record(foreground: entry.argv, name: entry.name, app: entry.app))
        return (rig, [Self.process(name: entry.name, environment: [:], argv: entry.argv)])
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func chatIsOfferedOnceAProgramsCheckHasPassed(_ program: ChatProgram) async throws {
        let (rig, rows) = try offerRig(program)
        try await rig.start(rows, turningOn: [.claude, program])

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == program)
        #expect(rig.store.chatStore(for: agent, program: program) != nil)
        rig.store.setHosts([])
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func anotherProgramsPassDoesNotOfferIt(_ program: ChatProgram) async throws {
        let (rig, rows) = try offerRig(program)
        let others = Set(ChatProgram.allCases).subtracting([program])
        try await rig.start(rows, turningOn: others)

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == nil)
        #expect(rig.store.chatStore(for: agent, program: program) == nil)
        rig.store.setHosts([])
    }

    /// None of them has passed its owner check yet. Turning one on changes this,
    /// which is the point: the list is the whole switch.
    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func chatStaysOffUntilTheOwnerCheckPasses(_ program: ChatProgram) async throws {
        #expect(!HerdrCoreChatRollout.confirmed.contains(program))
        let (rig, rows) = try offerRig(program)
        try await rig.start(rows, turningOn: HerdrCoreChatRollout.confirmed)

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == nil)
        rig.store.setHosts([])
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func chatStaysOffOnAMacOSCoreHost(_ program: ChatProgram) async throws {
        let (rig, rows) = try offerRig(program)
        try await rig.start(rows, kernel: "Darwin")

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == nil)
        #expect(rig.store.chatStore(for: agent, program: program) == nil)
        rig.store.setHosts([])
    }

    @Test func capabilitiesFollowTheProgramsTurnedOn() {
        let on = HostCapabilities(
            serverKind: .herdrCore, platform: .posix, coreKernel: "Linux", coreChatPrograms: [.claude, .grok])
        for program in ChatProgram.allCases {
            #expect(on.offersChat(for: program) == [.claude, .grok].contains(program))
        }
        let mac = HostCapabilities(
            serverKind: .herdrCore, platform: .posix, coreKernel: "Darwin", coreChatPrograms: [.claude, .grok])
        #expect(!mac.chat)
        // Herdr TUI has no such list.
        #expect(HostCapabilities(serverKind: .herdrTUI, coreChatPrograms: []).chatPrograms == nil)
    }

    // MARK: Codex

    private static let codexThread = "01a10f87-e025-7fb1-8974-8dd09937767a"

    private static func rollout(root: String = accountRoot) -> String {
        "\(root)/sessions/2026/10/06/rollout-2026-10-06T12-45-25-\(codexThread).jsonl"
    }

    private func codexRig() -> Rig {
        Rig(host: host, record: Self.record(foreground: ["codex", "--no-daemon"], name: "codex", app: "codex"))
    }

    @Test func aCodexChatReadsTheRolloutItHoldsUnderItsOwnCodexHome() async throws {
        let rig = codexRig()
        let path = Self.rollout()
        // The same thread under the Host's home holds other text, and must stay unread.
        await rig.files.write(try ChatFixture.data("codex/probe1-rollout.jsonl"), at: path)
        await rig.files.write(Data("wrong\n".utf8), at: Self.rollout(root: "\(Self.home)/.codex"))
        try await rig.start([
            Self.process(
                name: "codex", environment: ["CODEX_HOME": Self.accountRoot], argv: ["codex", "--no-daemon"],
                files: [path])
        ])
        let chat = try rig.chat(.codex)

        chat.show()

        try await rig.waitUntil("Chat to follow it") { chat.conversation.phase == .following(path: path) }
        #expect(!(await rig.files.reads.map(\.path).contains(Self.rollout(root: "\(Self.home)/.codex"))))
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aCodexOnTheSharedDaemonShowsTheReopenMessageAndSendsNothing() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["codex"], name: "codex", app: "codex"))
        try await rig.start([
            Self.process(name: "codex", environment: [:], argv: ["codex"]),
            Self.process(
                pid: 41, parent: 40, name: "codex", environment: [:],
                argv: ["codex", "app-server", "--managed-daemon"], files: [Self.rollout(root: "\(Self.home)/.codex")]),
        ])
        let chat = try rig.chat(.codex)

        chat.show()

        try await rig.waitUntil("the message") { chat.conversation.phase == .unavailable(.codexSharedDaemon) }
        #expect(await chat.confirmSessionBeforeSend() != nil)
        #expect(await rig.files.reads.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    /// The rollout comes with the first prompt, whose turn the core reports.
    @Test func aCodexChatFollowsOnceTheFirstPromptMakesTheRollout() async throws {
        let rig = codexRig()
        let row = Self.process(
            name: "codex", environment: ["CODEX_HOME": Self.accountRoot], argv: ["codex", "--no-daemon"])
        try await rig.start([row])
        let chat = try rig.chat(.codex)
        chat.show()
        try await rig.waitUntil("Chat to say so") { chat.conversation.phase == .unavailable(.cannotTellSession(.codex)) }

        var holding = row
        holding.files = [Self.rollout()]
        await rig.transport.processTable.add(holding)
        await rig.files.write(try ChatFixture.data("codex/probe1-rollout.jsonl"), at: Self.rollout())
        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "working", app: "codex"))

        try await rig.waitUntil("Chat to follow it") { chat.conversation.phase == .following(path: Self.rollout()) }
        chat.end()
        rig.store.setHosts([])
    }

    /// `/new` moved the screen, and the first prompt there left the new thread's lock
    /// with no rollout (`host-evidence/codex/no-daemon-after-new.json`, `observed`).
    /// No status change comes, since that prompt shows no turn, so Send has to find it.
    @Test func aSendFindsTheNewThreadsLockAndSendsNothing() async throws {
        let rig = codexRig()
        let row = Self.process(
            name: "codex", environment: ["CODEX_HOME": Self.accountRoot], argv: ["codex", "--no-daemon"],
            files: [Self.rollout(), "\(Self.accountRoot)/thread-writer-locks/\(Self.codexThread).lock"])
        await rig.files.write(try ChatFixture.data("codex/probe1-rollout.jsonl"), at: Self.rollout())
        try await rig.start([row])
        let chat = try rig.chat(.codex)
        chat.show()
        try await rig.waitUntil("Chat to follow it") { chat.conversation.phase == .following(path: Self.rollout()) }
        #expect(await chat.confirmSessionBeforeSend() == nil)

        var moved = row
        moved.files.append("\(Self.accountRoot)/thread-writer-locks/01a10f87-e025-7fb1-8974-8dd09937767b.lock")
        await rig.transport.processTable.add(moved)

        let refusal = try #require(await chat.confirmSessionBeforeSend())
        #expect(refusal.contains("can't tell"))
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.codex)))
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Grok Build

    /// The UUIDv4 a launch gives Grok Build with `-s`, the form the recording's
    /// folder and row keep.
    private static let grokSession = "6f1d2c3b-8a7e-4f10-9b2d-0c1e2f3a4b5c"

    private static func grokTranscript() throws -> Data {
        let text = try ChatFixture.text("grok/core-turns.jsonl")
        let original = try #require(GrokTranscriptLocator.sessionID(inHead: Data(text.utf8)))
        return Data(text.replacingOccurrences(of: original, with: grokSession).utf8)
    }

    private static func activeSessions(pid: Int = 40, start: Int = 111, rows: Int = 1) -> Data {
        let row = #"{"session_id":"\#(grokSession)","pid":\#(pid),"pid_start":\#(start),"cwd":"/work/app"}"#
        return Data("[\(Array(repeating: row, count: rows).joined(separator: ","))]".utf8)
    }

    @Test func aGrokBuildChatReadsItsOwnGrokHomeUnderTheIDItWasStartedWith() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["grok"], name: "grok", app: "grok-build"))
        let path = "\(Self.accountRoot)/sessions/%2Fwork%2Fapp/\(Self.grokSession)/updates.jsonl"
        await rig.files.write(Self.activeSessions(), at: "\(Self.accountRoot)/active_sessions.json")
        await rig.files.write(try Self.grokTranscript(), at: path)
        try await rig.start([Self.process(name: "grok", environment: ["GROK_HOME": Self.accountRoot])])
        let chat = try rig.chat(.grok)

        chat.show()

        try await rig.waitUntil("Chat to follow it") { chat.conversation.phase == .following(path: path) }
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aGrokBuildAfterNewCannotTell() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["grok"], name: "grok", app: "grok-build"))
        await rig.files.write(Self.activeSessions(rows: 2), at: "\(Self.home)/.grok/active_sessions.json")
        try await rig.start([Self.process(name: "grok", environment: [:])])
        let chat = try rig.chat(.grok)

        chat.show()

        try await rig.waitUntil("Chat to say so") { chat.conversation.phase == .unavailable(.cannotTellSession(.grok)) }
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: OpenCode

    private func openCodeRig(store: OpenCodeStoreStub, session: String) -> Rig {
        Rig(
            host: host,
            record: Self.record(
                foreground: ["opencode", "-s", session], name: "opencode", app: "opencode",
                labels: [HerdrCoreLaunch.sessionHintLabel: session]),
            openCodeStore: store)
    }

    /// Heeler knows the id before OpenCode's first prompt makes the row, so the
    /// store's "no such conversation" means one still to start. The query runs as
    /// it does on Herdr TUI, through the Host's reader.
    @Test func anOpenCodeChatWaitsForItsFirstPromptThenReadsTheStore() async throws {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let session = try #require(fixture.sessionID).rawValue
        let store = OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(fixture))
        let rig = openCodeRig(store: store, session: session)
        try await rig.start([Self.process(name: "opencode", environment: [:], argv: ["opencode", "-s", session])])
        let chat = try rig.chat(.opencode)

        chat.show()
        try await rig.waitUntil("a conversation to start") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.opencode))
        }

        await store.takeFirstPrompt()
        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "working", app: "opencode"))

        try await rig.waitUntil("the conversation") { !chat.conversation.transcript.entries.isEmpty }
        chat.end()
        rig.store.setHosts([])
    }

    @Test func anOpenCodeWithoutAHintSaysChatCannotTell() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["opencode"], name: "opencode", app: "opencode"))
        try await rig.start([Self.process(name: "opencode", environment: [:], argv: ["opencode"])])
        let chat = try rig.chat(.opencode)

        chat.show()

        try await rig.waitUntil("Chat to say so") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.opencode))
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// A conversation that went missing from the store is not one still to start.
    @Test func aConversationThatLeftTheStoreIsNotStillToStart() async throws {
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: "ses_e6a000000001Abcdefghijklmn"),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .opencode,
                conversationID: "ses_e6a000000001Abcdefghijklmn"),
            files: ChatHostFiles(
                status: { _ in nil }, list: { _ in nil }, read: { _ in throw TransportError.cancelled },
                home: { "/home/dev" },
                queryOpenCode: { _ in .sessionMissing(otherStores: []) }),
            cache: VolatileChatTranscriptCache(), adapter: try #require(ChatTranscriptAdapter.standard(for: .opencode)))

        // Herdr TUI reports only ids that exist.
        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        #expect(snapshot.phase == .unavailable(.sessionStore(.opencode, .sessionMissing(otherStores: []))))
    }

    // MARK: What it says

    @Test func cantTellSaysWhatEachProgramNeeds() {
        func explanation(_ program: ChatProgram) -> String {
            ChatUnavailableReason.cannotTellSession(program).explanation
                .replacingOccurrences(of: "\u{2011}", with: "-")
        }
        #expect(explanation(.codex).contains("first message"))
        #expect(explanation(.codex).contains("/new"))
        #expect(explanation(.codex).contains("codex resume --no-daemon"))
        #expect(explanation(.grok).contains("/new"))
        #expect(explanation(.opencode).contains("OpenCode 2.1 or later"))
        #expect(explanation(.opencode).contains("New Agent"))
        #expect(explanation(.claude).contains("reaches its prompt"))
    }
}
