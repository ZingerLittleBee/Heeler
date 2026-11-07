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

    func loseRow() {
        hasRow = false
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

    private static func titleEvent(sequence: Int, title: String) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("title"), "terminal": .string("t1"),
                "data": .object(["title": .string(title)]),
            ]),
        ]))) ?? Data()
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: HerdrCoreProgramChatTests.home)
        let transport: ScriptedCoreTransport
        let store: ConsoleStore
        let host: Host
        private var titleSequence = 100

        init(
            host: Host, record: JSONValue, openCodeStore: OpenCodeStoreStub? = nil,
            offering programs: Set<ChatProgram> = Set(ChatProgram.allCases)
        ) {
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
                makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
                coreLinuxChatPrograms: programs, coreMacOSChatPrograms: programs)
        }

        func start(_ rows: [ScriptedProcessTable.Process], kernel: String = "Linux") async throws {
            for row in rows { await transport.processTable.add(row) }
            await transport.setKernel(kernel)
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
            await store.resolveHostPlatform(host.id)
            try await waitUntil("the kernel") { self.store.hostCoreKernels[self.host.id] == kernel }
        }

        var agent: ConsoleAgent? { store.agents.first }

        /// What the program writes to its terminal's title, as far as the Console's
        /// record of the Agent. An empty one reads as none.
        func setTitle(_ title: String) async throws {
            titleSequence += 1
            await transport.deliver(HerdrCoreProgramChatTests.titleEvent(sequence: titleSequence, title: title))
            try await waitUntil("the title") { self.agent?.agent.terminalTitle == (title.isEmpty ? nil : title) }
        }

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
            environment: ["HC_SCOPE": "scope", "HOME": home].merging(environment) { $1 }, argv: argv, openFiles: files)
    }

    // MARK: The offer

    private static let programs: [(program: ChatProgram, argv: [String], name: String, app: String)] = [
        (.codex, ["codex", "--no-daemon"], "codex", "codex"),
        (.grok, ["grok"], "grok", "grok-build"),
        (.opencode, ["opencode"], "opencode", "opencode"),
    ]

    private func offerRig(
        _ program: ChatProgram, offering programs: Set<ChatProgram> = Set(ChatProgram.allCases)
    ) throws -> (Rig, [ScriptedProcessTable.Process]) {
        let entry = try #require(Self.programs.first { $0.program == program })
        let rig = Rig(
            host: host, record: Self.record(foreground: entry.argv, name: entry.name, app: entry.app),
            offering: programs)
        return (rig, [Self.process(name: entry.name, environment: [:], argv: entry.argv)])
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func chatIsOfferedOnceAProgramsCheckHasPassed(_ program: ChatProgram) async throws {
        let (rig, rows) = try offerRig(program, offering: [.claude, program])
        try await rig.start(rows)

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == program)
        #expect(rig.store.chatStore(for: agent, program: program) != nil)
        rig.store.setHosts([])
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode])
    func anotherProgramsPassDoesNotOfferIt(_ program: ChatProgram) async throws {
        let (rig, rows) = try offerRig(program, offering: Set(ChatProgram.allCases).subtracting([program]))
        try await rig.start(rows)

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == nil)
        #expect(rig.store.chatStore(for: agent, program: program) == nil)
        rig.store.setHosts([])
    }

    /// Codex and Grok Build passed their owner check on Linux, and OpenCode stays off
    /// there. The list is the whole switch.
    @Test(arguments: [(ChatProgram.codex, true), (.grok, true), (.opencode, false)])
    func theShippedLinuxListOffersWhatPassedItsOwnerCheck(_ program: ChatProgram, _ passed: Bool) async throws {
        #expect(HostCapabilities.confirmedLinuxCoreChatPrograms.contains(program) == passed)
        let (rig, rows) = try offerRig(program, offering: HostCapabilities.confirmedLinuxCoreChatPrograms)
        try await rig.start(rows)

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == (passed ? program : nil))
        #expect((rig.store.chatStore(for: agent, program: program) != nil) == passed)
        rig.store.setHosts([])
    }

    // MARK: macOS

    /// What the macOS VM's core reported of each program (`host-evidence/macos`), whose
    /// foreground goes by `2.1.316`, `node` or `grok-1.0.70-macos-aarch64` there.
    private nonisolated static let macOSScenes: [(scene: String, program: ChatProgram)] = [
        ("claude-direct", .claude), ("claude-under-zsh", .claude), ("codex-after-reply", .codex),
        ("codex-shared-daemon", .codex), ("grok", .grok), ("opencode", .opencode), ("pi-extension", .pi),
        ("omp-extension", .omp), ("omp-breadcrumb", .omp),
    ]

    private func macOSRig(
        _ scene: String, offering programs: Set<ChatProgram> = Set(ChatProgram.allCases)
    ) throws -> (Rig, HostEvidenceFixture.Scene) {
        let scene = try HostEvidenceFixture.named("macos/vm-26.5").scene(scene)
        let rig = Rig(host: host, record: try #require(scene.record), offering: programs)
        return (rig, scene)
    }

    @Test(arguments: macOSScenes)
    func chatIsOfferedOnAMacOSCoreHost(_ entry: (scene: String, program: ChatProgram)) async throws {
        let (rig, scene) = try macOSRig(entry.scene)
        try await rig.start((scene.processes ?? []).map(\.process), kernel: "Darwin")

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == entry.program)
        #expect(rig.store.chatStore(for: agent, program: entry.program) != nil)
        rig.store.setHosts([])
    }

    /// The store hands the check to the macOS forms: this row binds on nothing else.
    @Test func aMacOSHostChecksInTheMacOSForms() async throws {
        let (rig, scene) = try macOSRig("grok")
        for (path, text) in scene.files ?? [:] { await rig.files.write(text, at: path) }
        let session = "c3b87b14-d6bf-41ed-b273-5594972f9bbf"
        let path = "/Users/admin/lab/iso/grok/grok-home/sessions/%2FUsers%2Fadmin%2Flab%2Fiso%2Fprojects%2Fgrok/\(session)/updates.jsonl"
        let text = try ChatFixture.text("grok/core-turns.jsonl")
        let original = try #require(GrokTranscriptLocator.sessionID(inHead: Data(text.utf8)))
        await rig.files.write(text.replacingOccurrences(of: original, with: session), at: path)
        try await rig.start((scene.processes ?? []).map(\.process), kernel: "Darwin")
        let chat = try rig.chat(.grok)

        chat.show()

        try await rig.waitUntil("Chat to follow it") { chat.conversation.phase == .following(path: path) }
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aCodexOnTheSharedDaemonGetsOnlyTheReopenMessageOnMacOS() async throws {
        let (rig, scene) = try macOSRig("codex-shared-daemon")
        for (path, text) in scene.files ?? [:] { await rig.files.write(text, at: path) }
        try await rig.start((scene.processes ?? []).map(\.process), kernel: "Darwin")
        let chat = try rig.chat(.codex)

        chat.show()

        try await rig.waitUntil("the message") { chat.conversation.phase == .unavailable(.codexSharedDaemon) }
        #expect(await chat.confirmSessionBeforeSend() != nil)
        #expect(await rig.files.reads.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    /// Each kernel offers its own list: a program turned on for one waits on the other.
    @Test func capabilitiesFollowTheProgramsTurnedOnForEachKernel() {
        let expected: [(kernel: String, offered: Set<ChatProgram>)] = [
            ("Linux", [.claude, .grok]), ("Darwin", [.claude, .pi]),
        ]
        for (kernel, offered) in expected {
            let on = HostCapabilities(
                serverKind: .herdrCore, platform: .posix, coreKernel: kernel,
                coreLinuxChatPrograms: [.claude, .grok], coreMacOSChatPrograms: [.claude, .pi])
            #expect(on.chat)
            for program in ChatProgram.allCases {
                #expect(on.offersChat(for: program) == offered.contains(program))
            }
        }
        // Herdr TUI has no such list.
        #expect(
            HostCapabilities(serverKind: .herdrTUI, coreLinuxChatPrograms: [], coreMacOSChatPrograms: []).chatPrograms
                == nil)
    }

    // MARK: Antigravity CLI

    /// agy waits for the owner's check in a core Terminal on Linux and on a Mac
    /// (ADR 0034), and Windows reads hold none of the open files it binds from, so no
    /// shipped list offers it, whatever a Windows list says. Herdr TUI offers it.
    @Test func noShippedListOffersAntigravityCLIUntilTheOwnersCheck() {
        #expect(!HostCapabilities.confirmedLinuxCoreChatPrograms.contains(.agy))
        #expect(!HostCapabilities.confirmedMacOSCoreChatPrograms.contains(.agy))
        #expect(!HostCapabilities.confirmedWindowsCoreChatPrograms.contains(.agy))
        #expect(!HostCapabilities.windowsCoreChatCandidates.contains(.agy))
        for kernel in ["Linux", "Darwin"] {
            #expect(!HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: kernel).offersChat(for: .agy))
        }
        #expect(
            !HostCapabilities(
                serverKind: .herdrCore, platform: .nativeWindows, coreKernel: "Windows",
                coreWindowsChatPrograms: Set(ChatProgram.allCases)
            ).offersChat(for: .agy))
        #expect(HostCapabilities(serverKind: .herdrTUI).offersChat(for: .agy))
    }

    private static let agyRoot = "\(home)/.gemini/antigravity-cli"

    private static func agyTranscript(_ session: String) -> String {
        AgyTranscriptLocator.transcriptPath(inFolder: AgyTranscriptLocator.folder(in: agyRoot, id: session))
    }

    /// Offered by this test's own list, as the owner's check would turn it on: Chat
    /// follows the conversation whose presence lock agy holds, and after `/clear`,
    /// which reports no status from idle, the check before a Send finds the moved
    /// lock and holds that Send.
    @Test(arguments: ["Linux", "Darwin"])
    func anAntigravityCLIOfferedByATestsListFollowsItsHeldLock(_ kernel: String) async throws {
        let first = "3af3ed7f-0f65-423c-8ef4-69072caf1e06"
        let cleared = "3760d133-2936-4a32-95b4-8437ce7a8fbe"
        let rig = Rig(
            host: host, record: Self.record(foreground: ["agy"], name: "agy", app: "antigravity"), offering: [.agy])
        let row = Self.process(
            name: "agy", environment: [:], argv: ["agy"],
            files: [
                "\(Self.agyRoot)/presence/\(first).lock", "\(Self.agyRoot)/brain/\(first)",
                "\(Self.agyRoot)/conversations/\(first).db",
            ])
        let turns = try ChatFixture.data("agy/core-turns.jsonl")
        await rig.files.write(turns, at: Self.agyTranscript(first))
        try await rig.start([row], kernel: kernel)
        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == .agy)
        let chat = try rig.chat(.agy)

        chat.show()

        try await rig.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: Self.agyTranscript(first))
        }
        #expect(await chat.confirmSessionBeforeSend() == nil)

        var moved = row
        moved.openFiles = [
            "\(Self.agyRoot)/presence/\(cleared).lock", "\(Self.agyRoot)/brain/\(first)",
            "\(Self.agyRoot)/conversations/\(first).db", "\(Self.agyRoot)/brain/\(cleared)",
        ]
        await rig.transport.processTable.add(moved)
        await rig.files.write(turns, at: Self.agyTranscript(cleared))

        #expect(await chat.confirmSessionBeforeSend() != nil)
        try await rig.waitUntil("Chat to move with the lock") {
            chat.conversation.phase == .following(path: Self.agyTranscript(cleared))
        }
        chat.end()
        rig.store.setHosts([])
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
        holding.openFiles = [Self.rollout()]
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
        moved.openFiles.append("\(Self.accountRoot)/thread-writer-locks/01a10f87-e025-7fb1-8974-8dd09937767b.lock")
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

    /// Grok Build writes its row and its folder as it starts, and `updates.jsonl` only
    /// with the first message (recording `grok/s-flag.json`).
    @Test func aNewGrokBuildChatWaitsForItsFirstMessageThenFollowsIt() async throws {
        let rig = Rig(host: host, record: Self.record(foreground: ["grok"], name: "grok", app: "grok-build"))
        let folder = "\(Self.accountRoot)/sessions/%2Fwork%2Fapp/\(Self.grokSession)"
        await rig.files.write(Self.activeSessions(), at: "\(Self.accountRoot)/active_sessions.json")
        await rig.files.makeDirectory(folder)
        try await rig.start([Self.process(name: "grok", environment: ["GROK_HOME": Self.accountRoot])])
        let chat = try rig.chat(.grok)

        chat.show()
        try await rig.waitUntil("the new conversation's wait") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.grok))
        }

        await rig.files.write(try Self.grokTranscript(), at: "\(folder)/updates.jsonl")
        chat.retry()
        try await rig.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: "\(folder)/updates.jsonl")
        }
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

    private static func labelsEvent(sequence: Int, labels: [String: String]) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("labels"), "terminal": .string("t1"),
                "data": .object(["labels": .object(labels.mapValues(JSONValue.string))]),
            ]),
        ]))) ?? Data()
    }

    /// OpenCode 1.x reports no status, so nothing but its plugin's label can say
    /// which conversation it is in: that label alone moves Chat, the first time and
    /// after `/new`, and Chat reads the store as on Herdr TUI (ADR 0033).
    @Test func thePluginsLabelBindsAnOpenCodeThatReportsNothingAndFollowsNew() async throws {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let session = try #require(fixture.sessionID).rawValue
        let stub = OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(fixture))
        await stub.takeFirstPrompt()
        let rig = Rig(
            host: host,
            record: Self.record(foreground: ["opencode"], name: "opencode", app: "opencode", status: nil),
            openCodeStore: stub)
        try await rig.start([Self.process(name: "opencode", environment: [:], argv: ["opencode"])])
        let chat = try rig.chat(.opencode)
        func label(_ session: String) -> [String: String] {
            ["heeler.session": #"{"session":"\#(session)","pid":40,"start":"111"}"#]
        }

        chat.show()
        try await rig.waitUntil("Chat to say it can't tell") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.opencode))
        }

        await rig.transport.deliver(Self.labelsEvent(sequence: 2, labels: label(session)))
        try await rig.waitUntil("the conversation") { !chat.conversation.transcript.entries.isEmpty }

        // After `/new`, the next conversation has no row in this store.
        await rig.transport.deliver(Self.labelsEvent(sequence: 3, labels: label("ses_e6a000000009Abcdefghijklmn")))
        try await rig.waitUntil("Chat to leave the conversation") {
            chat.conversation.transcript.entries.isEmpty
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// A stale label is cleared, and the clear coming back asks only once more.
    @Test func aMismatchedLabelIsClearedAndBindsNothing() async throws {
        let rig = Rig(
            host: host,
            record: Self.record(foreground: ["opencode"], name: "opencode", app: "opencode", status: nil),
            openCodeStore: nil)
        try await rig.start([Self.process(name: "opencode", environment: [:], argv: ["opencode"])])
        let chat = try rig.chat(.opencode)

        chat.show()
        try await rig.waitUntil("Chat to say it can't tell") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.opencode))
        }
        await rig.transport.deliver(
            Self.labelsEvent(
                sequence: 2,
                labels: ["heeler.session": #"{"session":"ses_e6a000000009Abcdefghijklmn","pid":40,"start":"999"}"#]))

        for _ in 0..<500 where await rig.transport.labelWrites.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await !rig.transport.labelWrites.isEmpty)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.opencode)))
        chat.end()
        rig.store.setHosts([])
    }

    private static let storeMissing = ChatUnavailableReason.sessionStore(.opencode, .sessionMissing(otherStores: []))

    /// An engine on `pong` as a core binds it, from Host evidence (ADR 0034), or as
    /// Herdr TUI does, from an id herdr reported.
    private func pongEngine(
        store: OpenCodeStoreStub, cache: any ChatTranscriptCache = VolatileChatTranscriptCache(),
        cacheKey: ChatCacheKey? = nil, fromEvidence: Bool = true
    ) throws -> ChatConversationEngine {
        let session = try #require(try OpenCodeStoreFixture.named("pong").sessionID).rawValue
        return ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: session),
            cacheKey: cacheKey
                ?? ChatCacheKey(hostID: UUID(), herdrSession: "", program: .opencode, conversationID: session),
            files: ChatHostFiles(
                status: { _ in nil }, list: { _ in nil }, read: { _ in throw TransportError.cancelled },
                home: { "/home/dev" },
                queryOpenCode: { try await store.response($0) }),
            cache: cache, adapter: try #require(ChatTranscriptAdapter.standard(for: .opencode)),
            sessionMayPrecedeItsStore: fromEvidence)
    }

    private func pongStore() throws -> OpenCodeStoreStub {
        OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(try OpenCodeStoreFixture.named("pong")))
    }

    private static let idle = ChatProjectionContext(activity: .idle)

    /// Herdr TUI reports only ids that exist.
    @Test func onHerdrTUIAStoreWithoutTheIDIsNotAConversationStillToStart() async throws {
        let engine = try pongEngine(store: try pongStore(), fromEvidence: false)

        let snapshot = await engine.open(directories: [], context: Self.idle)

        #expect(snapshot.phase == .unavailable(Self.storeMissing))
    }

    @Test func aConversationChatHasNotSeenWaitsForItsFirstPrompt() async throws {
        let engine = try pongEngine(store: try pongStore())

        let snapshot = await engine.open(directories: [], context: Self.idle)

        #expect(snapshot.phase == .unavailable(.awaitingFirstMessage(.opencode)))
    }

    @Test func aConversationThatLeftTheStoreAfterChatFollowedItIsGone() async throws {
        let store = try pongStore()
        await store.takeFirstPrompt()
        let engine = try pongEngine(store: store)
        guard case .following = await engine.open(directories: [], context: Self.idle).phase else {
            Issue.record("The row should read")
            return
        }

        await store.loseRow()
        let snapshot = await engine.open(directories: [], context: Self.idle)

        #expect(snapshot.phase == .unavailable(Self.storeMissing))
    }

    @Test func aConversationSavedOnTheDeviceThatLeftTheStoreIsGone() async throws {
        let store = try pongStore()
        await store.takeFirstPrompt()
        let cache = VolatileChatTranscriptCache()
        let session = try #require(try OpenCodeStoreFixture.named("pong").sessionID).rawValue
        let key = ChatCacheKey(hostID: UUID(), herdrSession: "", program: .opencode, conversationID: session)
        let earlier = try pongEngine(store: store, cache: cache, cacheKey: key)
        _ = await earlier.open(directories: [], context: Self.idle)
        await earlier.save(force: true)

        await store.loseRow()
        let engine = try pongEngine(store: store, cache: cache, cacheKey: key)
        _ = await engine.restore()
        let snapshot = await engine.open(directories: [], context: Self.idle)

        #expect(snapshot.phase == .unavailable(Self.storeMissing))
    }

    /// `OPENCODE_DB` set only where the Agent runs: the query reads the default
    /// database, which never gets the row. A message that went in and never showed
    /// says this store is not where the conversation is, so the explanation of that
    /// comes back in place of the wait.
    @Test func aMessageThatNeverShowedEndsTheWaitForTheFirstPrompt() async throws {
        let engine = try pongEngine(store: try pongStore())
        #expect(
            await engine.open(directories: [], context: Self.idle).phase
                == .unavailable(.awaitingFirstMessage(.opencode)))

        let snapshot = await engine.open(directories: [], context: Self.idle, lostAMessage: true)

        #expect(snapshot.phase == .unavailable(Self.storeMissing))
    }

    // MARK: OpenCode's title before a Send

    private static let pongTitle = "OC | Pong"

    private func openCodeRig(pongStartedBy store: OpenCodeStoreStub) async throws -> (Rig, AgentChatStore) {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let session = try #require(fixture.sessionID).rawValue
        let rig = openCodeRig(store: store, session: session)
        try await rig.start([Self.process(name: "opencode", environment: [:], argv: ["opencode", "-s", session])])
        return (rig, try rig.chat(.opencode))
    }

    /// Following `pong`, whose conversation is titled `Pong`, under the title OpenCode
    /// writes for it.
    private func openCodeFollowingPong() async throws -> (Rig, AgentChatStore) {
        let store = OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(try OpenCodeStoreFixture.named("pong")))
        await store.takeFirstPrompt()
        let (rig, chat) = try await openCodeRig(pongStartedBy: store)
        chat.show()
        try await rig.waitUntil("the conversation") { chat.conversation.transcript.title == "Pong" }
        try await rig.setTitle(Self.pongTitle)
        return (rig, chat)
    }

    /// `/new` and a prompt, or a pick in OpenCode's list. Its argv keeps the id it
    /// started with, so the check of its process still binds the same conversation,
    /// and only the title says the screen left (ADR 0034).
    @Test func aSendIsRefusedOnceTheTitleNamesAnotherConversation() async throws {
        let (rig, chat) = try await openCodeFollowingPong()
        #expect(await chat.confirmSessionBeforeSend() == nil)

        try await rig.setTitle("OC | Another conversation")

        #expect(
            await chat.confirmSessionBeforeSend()
                == "OpenCode's terminal shows another conversation (Another conversation). Open this one in the terminal, then send again."
        )
        #expect(chat.conversation.transcript.title == "Pong")

        // Back on it in the terminal, Send goes again.
        try await rig.setTitle(Self.pongTitle)
        #expect(await chat.confirmSessionBeforeSend() == nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// OpenCode writes `OpenCode` on its home screen and for a conversation it has
    /// not titled, and this one has a title. So the same `/new` before the new
    /// conversation has its title, and a title model that never gives one, send
    /// nothing either.
    @Test func aSendIsRefusedWhenATitledConversationReadsAsUntitled() async throws {
        let (rig, chat) = try await openCodeFollowingPong()

        try await rig.setTitle(OpenCodeTerminalTitle.untitled)

        #expect(
            await chat.confirmSessionBeforeSend()
                == "OpenCode's terminal isn't showing this conversation. Open it in the terminal, then send again.")
        chat.end()
        rig.store.setHosts([])
    }

    /// OpenCode's `terminal.title` setting off writes nothing, which says nothing.
    @Test func aSendGoesWhenTheTerminalHasNoTitle() async throws {
        let (rig, chat) = try await openCodeFollowingPong()

        try await rig.setTitle("")

        #expect(await chat.confirmSessionBeforeSend() == nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// With no row yet there is no title to compare, so only another conversation's
    /// own title refuses.
    @Test func aConversationStillToStartHasOnlyAnotherTitleToRefuse() async throws {
        let store = OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(try OpenCodeStoreFixture.named("pong")))
        let (rig, chat) = try await openCodeRig(pongStartedBy: store)
        chat.show()
        try await rig.waitUntil("a conversation to start") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.opencode))
        }

        try await rig.setTitle(OpenCodeTerminalTitle.untitled)
        #expect(await chat.confirmSessionBeforeSend() == nil)

        try await rig.setTitle("OC | Picked in the terminal")
        #expect(await chat.confirmSessionBeforeSend()?.contains("Picked in the terminal") == true)
        chat.end()
        rig.store.setHosts([])
    }

    /// `/new` alone, over a conversation with nothing to compare: the title says
    /// nothing and the check of the process passes, and the screen read holds it.
    @Test func theHomeScreenHoldsASendTheChecksLetThrough() async throws {
        let store = OpenCodeStoreStub(harness: try OpenCodeSQLiteHarness(try OpenCodeStoreFixture.named("pong")))
        let (rig, chat) = try await openCodeRig(pongStartedBy: store)
        chat.show()
        try await rig.waitUntil("a conversation to start") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.opencode))
        }
        try await rig.setTitle(OpenCodeTerminalTitle.untitled)
        let home = try ScreenFixture.screen("opencode-18-home-after-new-180")
        let policy = ComposerDeliveryPolicy.chat(
            rules: ChatSendRules(
                program: .opencode,
                commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .opencode)),
            activity: { .idle }, readScreen: { home }, confirmSession: { await chat.confirmSessionBeforeSend() })
        let preflight = try #require(policy.preflight)

        #expect(
            await preflight("hello")
                == .inputNotReady(
                    "OpenCode is on its home screen, where a message starts a new conversation. Open this conversation in the terminal first."
                ))
        chat.end()
        rig.store.setHosts([])
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
