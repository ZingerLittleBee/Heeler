import Foundation
import Testing

@testable import Heeler

/// The virtual Host's files as a core transport's services read them.
private struct PiVirtualHostServices: HostServices {
    let files: VirtualHostFiles

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
}

/// Pi's and Oh My Pi's Chat on a Linux core Host, through `ConsoleStore` and the
/// scripted core transport. Both stay off until the owner's signed-in check of each
/// passes, so these turn them on through the store's own list.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCorePiChatTests {
    private static let first = "11111111-1111-4111-8111-111111111111"
    private static let second = "22222222-2222-4222-8222-222222222222"
    private static let pid = 40
    private static let start = "987654321"
    private static let hostHome = "/home/dev"
    private static let directory = "/work/app"
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        _ program: ChatProgram, argv: [String]? = nil, labels: [String: String] = [:]
    ) -> JSONValue {
        let name = program.rawValue
        return .object([
            "address": .string("t1"), "cwd": .string(directory), "state": .string("live"),
            "argv": .array((argv ?? [name]).map(JSONValue.string)), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(Double(pid)),
            "foreground": .object([
                "pid": .number(Double(pid)), "name": .string(name), "argv": .array([.string(name)]),
                "cwd": .string(directory),
            ]),
            "status": .object(["state": .string("idle"), "app": .string(name)]),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func event(sequence: Int, type: String, data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type), "terminal": .string("t1"), "data": data,
            ]),
        ]))) ?? Data()
    }

    private static func statusEvent(sequence: Int, state: String, app: String) -> Data {
        event(
            sequence: sequence, type: "status",
            data: .object([
                "status": .object(["state": .string(state), "app": .string(app)]),
                "records": .object([:]), "reported": .bool(true),
            ]))
    }

    private static func labelsEvent(sequence: Int, labels: [String: String]) -> Data {
        event(sequence: sequence, type: "labels", data: .object(["labels": .object(labels.mapValues(JSONValue.string))]))
    }

    /// What the extension writes for this test's process.
    private static func label(session: String, file: String? = nil) -> String {
        let fileField = file.map { #","file":"\#($0)""# } ?? ""
        return #"{"session":"\#(session)"\#(fileField),"pid":\#(pid),"start":"\#(start)"}"#
    }

    /// One recorded session of the program, under another id.
    private static func transcript(_ program: ChatProgram, session: String) throws -> Data {
        let fixture = program == .pi ? "pi/provider-retry.jsonl" : "omp/approvals-asks-plan.jsonl"
        let data = try ChatFixture.data(fixture)
        let recorded = try #require(PiTranscriptLocator.sessionID(inHead: data))
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: recorded, with: session).utf8)
    }

    private static func fileName(_ session: String) -> String {
        "2026-11-01T07-19-26-219Z_\(session).jsonl"
    }

    private static func sessionFile(root: String, session: String) -> String {
        "\(root)/--work-app--/\(fileName(session))"
    }

    private static func defaultRoot(_ program: ChatProgram) -> String {
        program == .pi ? "\(hostHome)/.pi/agent/sessions" : "\(hostHome)/.omp/agent/sessions"
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: HerdrCorePiChatTests.hostHome)
        let transport: ScriptedCoreTransport
        let store: ConsoleStore
        let host: Host
        let program: ChatProgram

        init(host: Host, program: ChatProgram, record: JSONValue, offered: Set<ChatProgram> = [.claude, .pi, .omp]) {
            self.host = host
            self.program = program
            transport = ScriptedCoreTransport(
                coreID: "c1",
                subscribeResults: [
                    JSONValue.object(["seq": .number(1), "terminals": .array([record]), "channel": .number(1)])
                ],
                services: PiVirtualHostServices(files: files))
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
                coreLinuxChatPrograms: offered)
        }

        func start(environment: [String: String] = [:], openFiles: [String] = []) async throws {
            await transport.processTable.add(
                ScriptedProcessTable.Process(
                    pid: HerdrCorePiChatTests.pid, name: program.rawValue, start: HerdrCorePiChatTests.start,
                    environment: ["HC_SCOPE": "scope", "HOME": HerdrCorePiChatTests.hostHome].merging(environment) { $1 },
                    openFiles: openFiles))
            await transport.setKernel("Linux")
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
            await store.resolveHostPlatform(host.id)
            try await waitUntil("the kernel") { self.store.hostCoreKernels[self.host.id] == "Linux" }
        }

        var agent: ConsoleAgent? { store.agents.first }

        func chat() throws -> AgentChatStore {
            let agent = try #require(agent)
            return try #require(store.chatStore(for: agent, program: program))
        }

        var checks: Int {
            get async { await transport.processTable.requests.count }
        }

        func waitUntil(
            _ what: String, _ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
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

    private static func following(_ chat: AgentChatStore) -> String? {
        if case .following(let path) = chat.conversation.phase { path } else { nil }
    }

    private nonisolated static let programs = [ChatProgram.pi, .omp]

    // MARK: The offer

    /// Both passed their owner's check on hc-lab, so the shipped Linux list offers them.
    @Test(arguments: programs)
    func theShippedLinuxListOffersIt(_ program: ChatProgram) async throws {
        let linux = HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: "Linux")
        #expect(linux.offersChat(for: program))

        let rig = Rig(
            host: host, program: program, record: Self.record(program),
            offered: HostCapabilities.confirmedLinuxCoreChatPrograms)
        try await rig.start()

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == program)
        rig.store.setHosts([])
    }

    @Test(arguments: programs)
    func aListWithoutItOffersNoChat(_ program: ChatProgram) async throws {
        let rig = Rig(host: host, program: program, record: Self.record(program), offered: [.claude])
        try await rig.start()

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == nil)
        #expect(rig.store.chatStore(for: try #require(rig.agent), program: program) == nil)
        rig.store.setHosts([])
    }

    @Test(arguments: programs)
    func onceTurnedOnItsDetailOffersChat(_ program: ChatProgram) async throws {
        let rig = Rig(host: host, program: program, record: Self.record(program))
        try await rig.start()

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == program)
        #expect(rig.store.chatStore(for: try #require(rig.agent), program: program) != nil)
        rig.store.setHosts([])
    }

    /// Each program's Chat turns on by itself.
    @Test func oneProgramsCheckPassingLeavesTheOtherOff() async throws {
        let rig = Rig(host: host, program: .omp, record: Self.record(.omp), offered: [.claude, .pi])
        try await rig.start()

        #expect(rig.store.chatProgram(for: try #require(rig.agent)) == nil)
        rig.store.setHosts([])
    }

    // MARK: Following a label

    @Test(arguments: programs)
    func aRewrittenLabelRebindsOnTheNextCheck(_ program: ChatProgram) async throws {
        let root = Self.defaultRoot(program)
        let firstFile = Self.sessionFile(root: root, session: Self.first)
        let secondFile = Self.sessionFile(root: root, session: Self.second)
        let rig = Rig(
            host: host, program: program,
            record: Self.record(program, labels: ["heeler.session": Self.label(session: Self.first, file: firstFile)]))
        try await rig.start()
        await rig.files.write(try Self.transcript(program, session: Self.first), at: firstFile)
        await rig.files.write(try Self.transcript(program, session: Self.second), at: secondFile)
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("the first conversation") { Self.following(chat) == firstFile }
        #expect(await rig.checks == 1)

        // `/new`: the extension rewrites its label, and that alone calls for a check.
        await rig.transport.deliver(
            Self.labelsEvent(
                sequence: 2, labels: ["heeler.session": Self.label(session: Self.second, file: secondFile)]))
        try await rig.waitForChecks(2)
        try await rig.waitUntil("the new conversation") { Self.following(chat) == secondFile }

        #expect(await rig.checks == 2)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: A kept Terminal's next Agent

    /// `restarted` keeps labels, so the next Agent starts under the last one's. It
    /// writes its own once, as its session starts, which may be while a check runs.
    @Test(arguments: programs)
    func aLabelWrittenDuringACheckBindsAndIsNotCleared(_ program: ChatProgram) async throws {
        let earlier = #"{"session":"\#(Self.second)","pid":9,"start":"1"}"#
        let file = Self.sessionFile(root: Self.defaultRoot(program), session: Self.first)
        let rig = Rig(host: host, program: program, record: Self.record(program, labels: ["heeler.session": earlier]))
        try await rig.start()
        let core = try #require(rig.store.coreProjection(on: host.id))
        let gate = ScriptedTransportCallGate()
        await rig.transport.processTable.hold(using: gate)

        let check = Task { try await core.checkChatSession(paneID: "t1", program: program) }
        await gate.waitForEntry()
        let own = Self.label(session: Self.first, file: file)
        await rig.transport.deliver(Self.labelsEvent(sequence: 2, labels: ["heeler.session": own]))
        try await rig.waitUntil("the new label") { core.terminalRecord(at: "t1")?.labels["heeler.session"] == own }
        await gate.open()

        let evidence = try await check.value
        #expect(evidence == .bound(sessionID: file, transcriptRoot: Self.defaultRoot(program), directory: nil))
        #expect(await rig.transport.labelWrites.isEmpty)
        rig.store.setHosts([])
    }

    /// An earlier Agent's label that outlasts the exec still goes.
    @Test(arguments: programs)
    func aLabelStillStaleAfterTheExecIsCleared(_ program: ChatProgram) async throws {
        let earlier = #"{"session":"\#(Self.second)","pid":9,"start":"1"}"#
        let rig = Rig(host: host, program: program, record: Self.record(program, labels: ["heeler.session": earlier]))
        try await rig.start()
        let core = try #require(rig.store.coreProjection(on: host.id))

        let evidence = try await core.checkChatSession(paneID: "t1", program: program)

        #expect(evidence == .unavailable(.cannotTellSession(program)))
        let write = try #require(await rig.transport.labelWrites.first)
        #expect(write["labels"]?["heeler.session"]?.stringValue == "")
        rig.store.setHosts([])
    }

    /// The core replaces labels by name, so the app is what compares them.
    @Test func aLabelThatChangedAfterItWasFoundStaleStays() async throws {
        let earlier = #"{"session":"\#(Self.second)","pid":9,"start":"1"}"#
        let own = Self.label(session: Self.first)
        let rig = Rig(
            host: host, program: .pi,
            record: Self.record(.pi, labels: ["heeler.session": earlier, "heeler.chat": earlier]))
        try await rig.start()
        let core = try #require(rig.store.coreProjection(on: host.id))
        await rig.transport.deliver(
            Self.labelsEvent(sequence: 2, labels: ["heeler.session": own, "heeler.chat": earlier]))
        try await rig.waitUntil("the new label") { core.terminalRecord(at: "t1")?.labels["heeler.session"] == own }

        try await core.clearStaleLabels(
            ["heeler.session": earlier, "heeler.chat": earlier], at: "t1", on: core.inventoryCore)

        let writes = await rig.transport.labelWrites
        #expect(writes.count == 1)
        #expect(writes.first?["labels"]?["heeler.chat"]?.stringValue == "")
        #expect(writes.first?["labels"]?["heeler.session"] == nil)
        rig.store.setHosts([])
    }

    @Test func noLabelStillStaleSendsNothing() async throws {
        let earlier = #"{"session":"\#(Self.second)","pid":9,"start":"1"}"#
        let own = Self.label(session: Self.first)
        let rig = Rig(host: host, program: .pi, record: Self.record(.pi, labels: ["heeler.session": own]))
        try await rig.start()
        let core = try #require(rig.store.coreProjection(on: host.id))

        try await core.clearStaleLabels(["heeler.session": earlier], at: "t1", on: core.inventoryCore)

        #expect(await rig.transport.labelWrites.isEmpty)
        #expect(await rig.transport.mutations.isEmpty)
        rig.store.setHosts([])
    }

    // MARK: The Agent's own root

    @Test(arguments: [
        (ChatProgram.pi, ["PI_CODING_AGENT_DIR": "/srv/agent"], "/srv/agent/sessions"),
        (ChatProgram.omp, ["PI_CODING_AGENT_DIR": "/srv/agent"], "/srv/agent/sessions"),
        (ChatProgram.pi, ["PI_CODING_AGENT_SESSION_DIR": "/srv/flat"], "/srv/flat"),
    ])
    func itReadsTheTranscriptFromTheAgentsOwnRoot(
        _ program: ChatProgram, _ environment: [String: String], _ root: String
    ) async throws {
        let rig = Rig(
            host: host, program: program,
            record: Self.record(program, labels: ["heeler.session": Self.label(session: Self.first)]))
        try await rig.start(environment: environment)
        // The core's own root holds a file under the same name, and it is not this one.
        await rig.files.write(
            try Self.transcript(program, session: Self.second),
            at: Self.sessionFile(root: Self.defaultRoot(program), session: Self.first))
        let own =
            root == "/srv/flat"
            ? "\(root)/\(Self.fileName(Self.first))" : Self.sessionFile(root: root, session: Self.first)
        await rig.files.write(try Self.transcript(program, session: Self.first), at: own)
        let chat = try rig.chat()

        chat.show()
        try await rig.waitUntil("the Agent's own Transcript") { Self.following(chat) == own }

        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Pi's launch hint

    @Test func aPiHeelerStartedWaitsForItsFirstMessageThenFollowsIt() async throws {
        let rig = Rig(
            host: host, program: .pi,
            record: Self.record(
                .pi, argv: ["pi", "--session-id", Self.first], labels: [HerdrCoreLaunch.sessionHintLabel: Self.first]))
        try await rig.start()
        let chat = try rig.chat()

        chat.show()
        try await rig.waitUntil("the new conversation's wait") {
            chat.conversation.phase == .unavailable(.awaitingFirstMessage(.pi))
        }

        // Pi writes the file with the first prompt or its reply, by release.
        let file = Self.sessionFile(root: Self.defaultRoot(.pi), session: Self.first)
        await rig.files.write(try Self.transcript(.pi, session: Self.first), at: file)
        chat.retry()
        try await rig.waitUntil("the Transcript") { Self.following(chat) == file }

        chat.end()
        rig.store.setHosts([])
    }

    /// The launch id and the extension's file name one conversation, and a label comes
    /// after the check that reached it by id. Chat reads on, and a Send goes.
    @Test func aLabelNamingTheFileChatFollowsIsTheSameConversation() async throws {
        let rig = Rig(
            host: host, program: .pi,
            record: Self.record(
                .pi, argv: ["pi", "--session-id", Self.first], labels: [HerdrCoreLaunch.sessionHintLabel: Self.first]))
        let file = Self.sessionFile(root: Self.defaultRoot(.pi), session: Self.first)
        await rig.files.write(try Self.transcript(.pi, session: Self.first), at: file)
        try await rig.start()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("the Transcript") { Self.following(chat) == file }
        let core = try #require(rig.store.coreProjection(on: host.id))
        let generation = chat.conversationGeneration

        let own = Self.label(session: Self.first, file: file)
        await rig.transport.deliver(Self.labelsEvent(sequence: 2, labels: ["heeler.session": own]))
        try await rig.waitUntil("the label") { core.terminalRecord(at: "t1")?.labels["heeler.session"] == own }

        #expect(await chat.confirmSessionBeforeSend() == nil)
        #expect(chat.conversationGeneration == generation)
        #expect(Self.following(chat) == file)

        // Another session's file is still another conversation.
        let otherFile = Self.sessionFile(root: Self.defaultRoot(.pi), session: Self.second)
        await rig.files.write(try Self.transcript(.pi, session: Self.second), at: otherFile)
        let other = Self.label(session: Self.second, file: otherFile)
        await rig.transport.deliver(Self.labelsEvent(sequence: 3, labels: ["heeler.session": other]))
        try await rig.waitUntil("the other label") { core.terminalRecord(at: "t1")?.labels["heeler.session"] == other }
        _ = await chat.confirmSessionBeforeSend()
        try await rig.waitUntil("the other conversation") { Self.following(chat) == otherFile }
        chat.end()
        rig.store.setHosts([])
    }

    /// While it waits, the file comes in place of the id, and a Send is not told that
    /// the Agent moved.
    @Test func aLabelNamingTheFileOfAConversationStillToStartIsNotAnotherOne() async throws {
        let rig = Rig(
            host: host, program: .pi,
            record: Self.record(
                .pi, argv: ["pi", "--session-id", Self.first], labels: [HerdrCoreLaunch.sessionHintLabel: Self.first]))
        try await rig.start()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("the wait") { chat.conversation.phase == .unavailable(.awaitingFirstMessage(.pi)) }
        let core = try #require(rig.store.coreProjection(on: host.id))

        let file = Self.sessionFile(root: Self.defaultRoot(.pi), session: Self.first)
        let own = Self.label(session: Self.first, file: file)
        await rig.transport.deliver(Self.labelsEvent(sequence: 2, labels: ["heeler.session": own]))
        try await rig.waitUntil("the label") { core.terminalRecord(at: "t1")?.labels["heeler.session"] == own }

        #expect(await chat.confirmSessionBeforeSend() == nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// Nothing here is written until the first message, and a wait looks on every
    /// pass: its own folders each time, every project's once per activity, as Claude
    /// Code's does.
    @Test func aWaitForAFirstMessageSearchesEveryProjectOncePerActivity() async throws {
        let files = VirtualHostFiles(home: Self.hostHome)
        let root = Self.defaultRoot(.pi)
        await files.makeDirectory("\(root)/--elsewhere--")
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .pi, sessionID: Self.first),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .pi, conversationID: Self.first),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .pi)),
            transcriptRoot: root, sessionMayPrecedeItsStore: true)
        func projectSearches() async -> Int {
            await files.listings.count { $0.directory == "\(root)/--elsewhere--" }
        }
        let idle = ChatProjectionContext(activity: .idle)
        let working = ChatProjectionContext(activity: .working)

        for _ in 0..<3 {
            let snapshot = await engine.open(directories: ["/work/app"], context: idle)
            #expect(snapshot.phase == .unavailable(.awaitingFirstMessage(.pi)))
        }
        #expect(await projectSearches() == 1)

        for _ in 0..<3 {
            _ = await engine.open(directories: ["/work/app"], context: working)
        }
        #expect(await projectSearches() == 2)

        // Its own folder still shows the file on the next pass, with no new activity.
        let file = Self.sessionFile(root: root, session: Self.first)
        await files.write(try Self.transcript(.pi, session: Self.first), at: file)
        #expect(await engine.open(directories: ["/work/app"], context: working).phase == .following(path: file))
    }

    // MARK: Without exact evidence

    @Test(arguments: programs)
    func withNoEvidenceChatSaysItCannotTellAndOffersTheHelper(_ program: ChatProgram) async throws {
        let rig = Rig(host: host, program: program, record: Self.record(program))
        try await rig.start()
        // The newest Transcript in the Agent's directory, for the taking.
        await rig.files.write(
            try Self.transcript(program, session: Self.first),
            at: Self.sessionFile(root: Self.defaultRoot(program), session: Self.first))
        let chat = try rig.chat()
        await rig.files.clearRecords()

        chat.show()
        try await rig.waitUntil("Chat to say so") {
            chat.conversation.phase == .unavailable(.cannotTellSession(program))
        }

        let reason = ChatUnavailableReason.cannotTellSession(program)
        #expect(reason.title == "Can't Tell the Conversation")
        #expect(reason.explanation.contains("Host Helper"))
        #expect(reason.explanation.contains("doesn't guess"))
        #expect(reason.offersRetry)
        #expect(await rig.checks == 1)
        #expect(await rig.files.listings.isEmpty)
        #expect(await rig.files.statuses.isEmpty)
        #expect(Self.following(chat) == nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// The owner's Mac, 2026-11-02: `pi --no-extensions` with the Helper installed was
    /// told to install the Helper. The extension is there, so the words say why it
    /// isn't running, and the conversation can still be picked.
    @Test(arguments: [ChatProgram.pi, .omp])
    func withTheExtensionInPlaceChatSaysItIsntLoadedAndOffersNoHelper(_ program: ChatProgram) async throws {
        let rig = Rig(host: host, program: program, record: Self.record(program))
        try await rig.start()
        let folder = program == .pi ? ".pi/agent/extensions" : ".omp/agent/extensions"
        await rig.files.write("export default function () {}\n", at: "\(Self.hostHome)/\(folder)/heeler-session.js")
        let chat = try rig.chat()

        chat.show()
        try await rig.waitUntil("Chat to say so") {
            chat.conversation.phase == .unavailable(.extensionNotLoaded(program, turnedOff: false))
        }

        let reason = ChatUnavailableReason.extensionNotLoaded(program, turnedOff: false)
        #expect(reason.title == "Can't Tell the Conversation")
        #expect(!reason.explanation.contains("Install the Helper"))
        #expect(reason.explanation.contains("--no-extensions"))
        #expect(reason.offersRetry)
        #expect(chat.offersCandidates)
        let turnedOff = ChatUnavailableReason.extensionNotLoaded(program, turnedOff: true).explanation
        #expect(turnedOff.contains("started with its extensions turned off (--no-extensions)"))
        #expect(!turnedOff.contains("Install the Helper"))
        chat.end()
        rig.store.setHosts([])
    }

    /// The Claude Code wording stays Claude Code's: it names its conversation by
    /// itself and has no extension.
    @Test func claudeCodesReasonOffersNoHelper() {
        #expect(!ChatUnavailableReason.cannotTellSession(.claude).explanation.contains("Host Helper"))
    }

    // MARK: Oh My Pi's breadcrumb

    @Test func ompBindsFromItsBreadcrumbOnlyOnceItsFirstMessageOpensTheFile() async throws {
        let root = Self.defaultRoot(.omp)
        let file = Self.sessionFile(root: root, session: Self.first)
        let crumb = "\(Self.hostHome)/.omp/agent/terminal-sessions/pts-0"
        let rig = Rig(host: host, program: .omp, record: Self.record(.omp))
        try await rig.start(openFiles: ["/dev/pts/0"])
        await rig.files.write("\(Self.directory)\n\(file)\nfresh\ncwdstat 1 2\n", at: crumb)
        let chat = try rig.chat()
        await rig.files.clearRecords()

        chat.show()
        try await rig.waitUntil("Chat to say it cannot tell") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.omp))
        }
        #expect(await rig.checks == 1)
        // The breadcrumb, then whether Heeler's extension is in place.
        #expect(
            await rig.files.reads.map(\.path)
                == [crumb, "\(Self.hostHome)/.omp/agent/extensions/heeler-session.js"])

        // The reply wrote the file, dropped `fresh`, and the process opened it.
        await rig.files.write(try Self.transcript(.omp, session: Self.first), at: file)
        await rig.files.write("\(Self.directory)\n\(file)\ncwdstat 1 2\n", at: crumb)
        await rig.transport.processTable.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "omp", start: Self.start,
                environment: ["HC_SCOPE": "scope", "HOME": Self.hostHome], openFiles: ["/dev/pts/0", file]))
        await rig.transport.deliver(Self.statusEvent(sequence: 2, state: "done", app: "omp"))
        try await rig.waitUntil("the Transcript") { Self.following(chat) == file }

        #expect(await rig.checks == 2)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: The locator

    private static func locate(
        _ reference: ConversationReference, in files: VirtualHostFiles, sessionsRoot: String?
    ) async throws -> Result<String, PiTranscriptUnavailable> {
        try await PiTranscriptLocator(files: files.hostFiles())
            .locate(reference: reference, directories: [directory], sessionsRoot: sessionsRoot)
    }

    @Test(arguments: programs)
    func theLocatorLooksOnlyUnderTheRootItIsGiven(_ program: ChatProgram) async throws {
        let files = VirtualHostFiles(home: Self.hostHome)
        let reference = ConversationReference(program: program, sessionID: Self.first)
        let inDefault = Self.sessionFile(root: Self.defaultRoot(program), session: Self.first)
        await files.write(try Self.transcript(program, session: Self.first), at: inDefault)

        let elsewhere = try await Self.locate(reference, in: files, sessionsRoot: "/srv/agent/sessions")
        let unnamed = try await Self.locate(reference, in: files, sessionsRoot: nil)

        #expect(elsewhere == .failure(.notFound(searchedAll: true)))
        #expect(unnamed == .success(inDefault))
    }

    @Test func theLocatorFindsAFileDirectlyInACustomSessionFolder() async throws {
        let files = VirtualHostFiles(home: Self.hostHome)
        let reference = ConversationReference(program: .pi, sessionID: Self.first)
        let path = "/srv/flat/\(Self.fileName(Self.first))"
        await files.write(try Self.transcript(.pi, session: Self.first), at: path)

        #expect(try await Self.locate(reference, in: files, sessionsRoot: "/srv/flat") == .success(path))
    }

    @Test func theLocatorRefusesAFileHoldingAnotherSession() async throws {
        let files = VirtualHostFiles(home: Self.hostHome)
        let reference = ConversationReference(program: .pi, sessionID: Self.first)
        await files.write(
            try Self.transcript(.pi, session: Self.second), at: Self.sessionFile(root: "/srv/s", session: Self.first))

        #expect(try await Self.locate(reference, in: files, sessionsRoot: "/srv/s") == .failure(.mismatched))
    }
}
