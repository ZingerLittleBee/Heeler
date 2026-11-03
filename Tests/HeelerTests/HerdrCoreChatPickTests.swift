import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The virtual Host's files and OpenCode's store, as a core transport's services
/// read them.
private struct PickHostServices: HostServices {
    let files: VirtualHostFiles
    var store: PickOpenCodeStore?

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

private actor PickOpenCodeStore {
    private let harness: OpenCodeSQLiteHarness

    init(harness: sending OpenCodeSQLiteHarness) {
        self.harness = harness
    }

    func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
        try harness.response(query)
    }
}

@MainActor @Observable
final class ChatPickerPresence {
    var isOpen = true
}

/// Time for a Chat under test, which passes only when the test says so.
private final class PickClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_792_440_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Picking a conversation for a core Agent, through `ConsoleStore` and the scripted
/// core transport: a Chat that cannot tell lists candidates on request, the user's
/// confirmation is a `heeler.chat` label, and the label goes when anything says it
/// no longer holds (ADR 0034). Processes and Transcripts follow the recordings in
/// `ChatFixtures/host-evidence`. OpenCode's recording holds no session file open, so
/// its held file here is an edited process row.
@MainActor
@Suite("herdr-core Chat pick", .timeLimit(.minutes(1)))
struct HerdrCoreChatPickTests {
    private static let home = "/home/dev"
    private static let directory = "/work/app"
    private nonisolated static let pid = 40
    private nonisolated static let start = "145585"
    /// The Terminal's own process, which outlives the Agents run in it.
    private static let shell = 30
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static let grokHeld = "6f1d2c3b-8a7e-4f10-9b2d-0c1e2f3a4b5c"
    private static let grokChild = "7a2e3d4c-9b8f-4a21-8c3e-1d2f3a4b5c6d"
    private static let grokRecent = "8b3f4e5d-ac90-4b32-9d4f-2e3a4b5c6d7e"
    private static let openCodeHeld = "ses_e6a000000001Abcdefghijklmn"
    private static let openCodeChild = "ses_e6a000000002Abcdefghijklmn"

    private static func record(
        _ program: ChatProgram, argv: [String]? = nil, app: String? = nil, labels: [String: String] = [:],
        children: [String] = []
    ) -> JSONValue {
        let name = program.rawValue
        let argv = (argv ?? [name]).map(JSONValue.string)
        let app = app ?? name
        return .object([
            "address": .string("t1"), "cwd": .string(directory), "state": .string("live"),
            "argv": .array(argv), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(Double(shell)),
            "foreground": foreground(argv: argv, name: name, pid: pid),
            "status": .object(["state": .string("idle"), "app": .string(app)]),
            "records": .object(
                Dictionary(
                    uniqueKeysWithValues: children.map {
                        ($0, JSONValue.object(["state": .string("idle"), "app": .string(app)]))
                    })),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func foreground(argv: [JSONValue], name: String, pid: Int) -> JSONValue {
        .object([
            "pid": .number(Double(pid)), "name": .string(name), "argv": .array(argv), "cwd": .string(directory),
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

    /// A whole new inventory, as `missed` carries it, with this Agent's Terminal in it.
    private static func inventory(sequence: Int, labels: [String: String]) -> Data {
        let terminal = record(.grok, app: "grok-build", labels: labels, children: [grokChild])
        return (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("missed"),
            "params": .object(["seq": .number(Double(sequence)), "terminals": .array([terminal])]),
        ]))) ?? Data()
    }

    private static func process(
        _ program: ChatProgram, pid: Int = pid, start: String = start, files: [String] = [], argv: [String] = []
    ) -> ScriptedProcessTable.Process {
        ScriptedProcessTable.Process(
            pid: pid, parent: shell, name: program.rawValue, start: start,
            environment: ["HC_SCOPE": "scope", "HOME": home], argv: argv, openFiles: files)
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: HerdrCoreChatPickTests.home)
        let transport: ScriptedCoreTransport
        let store: ConsoleStore
        let host: Host
        let program: ChatProgram
        let clock = PickClock()

        /// `steppedByTheTest` puts the Chat on `clock`, for a test that moves it itself.
        init(
            host: Host, program: ChatProgram, record: JSONValue, openCodeStore: PickOpenCodeStore? = nil,
            steppedByTheTest: Bool = false
        ) {
            self.host = host
            self.program = program
            let result = JSONValue.object(["seq": .number(1), "terminals": .array([record]), "channel": .number(1)])
            transport = ScriptedCoreTransport(
                coreID: "c1", subscribeResults: [result],
                services: PickHostServices(files: files, store: openCodeStore))
            let transport = transport
            var timing = AgentChatStore.Timing()
            timing.activeInterval = .milliseconds(20)
            timing.idleInterval = .milliseconds(20)
            timing.queryActiveInterval = .milliseconds(20)
            let clock = clock
            store = ConsoleStore(
                chatCache: VolatileChatTranscriptCache(),
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
                coreLinuxChatPrograms: Set(ChatProgram.allCases),
                chatTiming: timing,
                chatNow: { steppedByTheTest ? clock.now : Date() })
        }

        func start(_ rows: [ScriptedProcessTable.Process]) async throws {
            await transport.processTable.add(
                ScriptedProcessTable.Process(
                    pid: HerdrCoreChatPickTests.shell, name: "bash", start: "1", environment: ["HC_SCOPE": "scope"]))
            for row in rows { await transport.processTable.add(row) }
            await transport.setKernel("Linux")
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
            await store.resolveHostPlatform(host.id)
            try await waitUntil("the kernel") { self.store.hostCoreKernels[self.host.id] == "Linux" }
        }

        func chat() throws -> AgentChatStore {
            let agent = try #require(store.agents.first)
            return try #require(store.chatStore(for: agent, program: program))
        }

        func waitUntil(
            _ what: String, _ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        func waitUntilCannotTell(_ chat: AgentChatStore, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let cannotTell = ChatConversationSnapshot.Phase.unavailable(.cannotTellSession(program))
            try await waitUntil(
                "Chat to say it cannot tell", { chat.conversation.phase == cannotTell }, sourceLocation: sourceLocation)
        }

        /// Chat says it cannot tell in place of the conversation: none of the dropped
        /// pick's rows are left to read, and the fix is on offer.
        func expectLeftConversation(_ chat: AgentChatStore, sourceLocation: SourceLocation = #_sourceLocation) {
            let reason = ChatUnavailableReason.cannotTellSession(program)
            #expect(chat.conversation.phase == .unavailable(reason), sourceLocation: sourceLocation)
            #expect(chat.conversation.transcript.entries.isEmpty, sourceLocation: sourceLocation)
            #expect(!chat.conversation.isFromCache, sourceLocation: sourceLocation)
            #expect(
                ChatSurfacePresentation(conversation: chat.conversation, hasPendingEchoes: false, isHostConnected: true)
                    == .unavailable(reason),
                sourceLocation: sourceLocation)
            #expect(chat.offersCandidates, sourceLocation: sourceLocation)
        }

        /// The value of each write of the pick label, oldest first.
        var pickWrites: [String] {
            get async {
                await transport.labelWrites.compactMap { $0["labels"]?["heeler.chat"]?.stringValue }
            }
        }

        var turnPhaseSequence = 10

        /// The Terminal's own process goes out of sight and back, as an exec that shows
        /// no scope does, with the pick's process and label where they were.
        func hideTerminalProcess() async {
            await transport.processTable.remove(HerdrCoreChatPickTests.shell)
        }

        func showTerminalProcess() async {
            await transport.processTable.add(
                ScriptedProcessTable.Process(
                    pid: HerdrCoreChatPickTests.shell, name: "bash", start: "1", environment: ["HC_SCOPE": "scope"]))
        }

        /// An event that asks Chat to check the process again, naming the one it has.
        func nudgeCheck() async {
            turnPhaseSequence += 1
            await transport.deliver(
                HerdrCoreChatPickTests.event(
                    sequence: turnPhaseSequence, type: "foreground",
                    data: HerdrCoreChatPickTests.foreground(
                        argv: [.string(program.rawValue)], name: program.rawValue, pid: HerdrCoreChatPickTests.pid)))
        }

        /// Steps the Chat until `condition` holds, for what comes from the core's events.
        func stepUntil(
            _ chat: AgentChatStore, _ what: String, _ condition: @MainActor () -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                await chat.step()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        /// Lets the time a guard waits after a turn pass, and starts a read. When this
        /// returns the guard has judged that read: `step` runs it before it ends. A test
        /// that expects a pick to stay goes through this same step as one that expects
        /// it to go.
        func passGuardSettle(_ chat: AgentChatStore) async {
            clock.advance(AgentChatStore.Timing().pickGuardSettle)
            await chat.step()
        }

        /// One turn, as the core reports it.
        func runTurn(whileWorking: () async throws -> Void = {}) async throws {
            let app = program == .grok ? "grok-build" : program.rawValue
            turnPhaseSequence += 1
            await transport.deliver(
                HerdrCoreChatPickTests.statusEvent(sequence: turnPhaseSequence, state: "working", app: app))
            try await waitUntil("the Agent to work") { self.store.agents.first?.agent.status == .working }
            try await whileWorking()
            turnPhaseSequence += 1
            await transport.deliver(
                HerdrCoreChatPickTests.statusEvent(sequence: turnPhaseSequence, state: "idle", app: app))
            try await waitUntil("the Agent to stop") { self.store.agents.first?.agent.status != .working }
        }
    }

    // MARK: Fixtures

    private static func grokFile(_ session: String) -> String {
        "\(home)/.grok/sessions/%2Fwork%2Fapp/\(session)/updates.jsonl"
    }

    /// `core-turns.jsonl` under another id, cut after `lines` lines. Line 4 is the
    /// prompt `grokPrompt`.
    private static func grokTranscript(session: String, lines: Int = 4) throws -> Data {
        let text = try ChatFixture.text("grok/core-turns.jsonl")
        let original = try #require(GrokTranscriptLocator.sessionID(inHead: Data(text.utf8)))
        let kept = text.replacingOccurrences(of: original, with: session)
            .split(separator: "\n").prefix(lines).joined(separator: "\n")
        return Data((kept + "\n").utf8)
    }

    private static let grokPrompt = "Answer with just the word ok.\nThis is line two.\nThis is line three."

    private static func pickLabel(session: String, pid: Int = pid, start: String = start) -> String {
        HerdrCoreSessionHint.pickLabelValue(session: session, file: nil, pid: pid, start: start) ?? ""
    }

    /// Candidates on disk and under the process, for an Agent no row matches.
    private func grokRig(
        labels: [String: String] = [:], children: [String] = [grokChild], steppedByTheTest: Bool = false
    ) async throws -> Rig {
        let rig = Rig(
            host: host, program: .grok,
            record: Self.record(.grok, app: "grok-build", labels: labels, children: children),
            steppedByTheTest: steppedByTheTest)
        await rig.files.write(
            #"[{"session_id":"\#(Self.grokRecent)","pid":9,"pid_start":1,"cwd":"/work/app"}]"#,
            at: "\(Self.home)/.grok/active_sessions.json")
        await rig.files.write(try Self.grokTranscript(session: Self.grokRecent), at: Self.grokFile(Self.grokRecent))
        await rig.files.write(try Self.grokTranscript(session: Self.grokHeld), at: Self.grokFile(Self.grokHeld))
        try await rig.start([
            Self.process(.grok, files: ["\(Self.home)/.grok/sessions/%2Fwork%2Fapp/\(Self.grokHeld)/events.jsonl"])
        ])
        return rig
    }

    private static func openCodeStore() throws -> PickOpenCodeStore {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let harness = try OpenCodeSQLiteHarness(fixture)
        try harness.execute("UPDATE session_v2 SET directory = '/work/app'")
        return PickOpenCodeStore(harness: harness)
    }

    private static var pongSession: String {
        get throws { try #require(try OpenCodeStoreFixture.named("pong").sessionID).rawValue }
    }

    /// OpenCode 2.x started without a launch id.
    private func openCodeRig(labels: [String: String] = [:], store: PickOpenCodeStore? = nil) async throws -> Rig {
        let rig = Rig(
            host: host, program: .opencode,
            record: Self.record(.opencode, labels: labels, children: [Self.openCodeChild]),
            openCodeStore: try store ?? Self.openCodeStore())
        try await rig.start([
            Self.process(
                .opencode, files: ["\(Self.home)/.local/share/opencode/sessions/\(Self.openCodeHeld).json"],
                argv: ["opencode"])
        ])
        return rig
    }

    private static func listed(_ chat: AgentChatStore, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> ChatSessionCandidates
    {
        guard case .listed(let list) = chat.candidates else {
            Issue.record("expected a list, read \(chat.candidates)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return list
    }

    private static func candidate(
        _ session: String, in chat: AgentChatStore, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ChatSessionCandidate {
        try #require(
            try listed(chat, sourceLocation: sourceLocation).candidates.first { $0.sessionID == session },
            sourceLocation: sourceLocation)
    }

    /// A Chat that cannot tell, with the list the user asked for.
    private func listing(_ rig: Rig) async throws -> AgentChatStore {
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntilCannotTell(chat)
        await chat.listCandidates()
        return chat
    }

    private static func sent(
        _ id: UUID, _ text: String, delivered: Bool = true, mayNotHaveGone: Bool = false
    ) -> AgentChatStore.SentMessage {
        AgentChatStore.SentMessage(id: id, text: text, isDelivered: delivered, mayNotHaveGone: mayNotHaveGone)
    }

    private static func send(_ text: String, on chat: AgentChatStore) {
        let id = UUID()
        chat.updateSends([sent(id, text, delivered: false)])
        chat.updateSends([sent(id, text)])
    }

    // MARK: Listing

    @Test func anOpenCodeWithoutALaunchIDListsItsCandidatesAndBindsNothing() async throws {
        let rig = try await openCodeRig()

        let chat = try await listing(rig)

        let list = try Self.listed(chat)
        let pong = try Self.pongSession
        #expect(list.candidates.map(\.sessionID) == [Self.openCodeHeld, Self.openCodeChild, pong])
        #expect(list.candidates.map(\.origins) == [[.heldOpen], [.programStatus], [.recentTranscript]])
        #expect(list.candidates.last?.title == "Pong")
        #expect(list.pid == Self.pid)
        #expect(list.start == Self.start)

        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.opencode)))
        #expect(await rig.transport.mutations.isEmpty)
        #expect(await chat.confirmSessionBeforeSend() != nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// A store Heeler can't read isn't a directory with no conversations, so the list
    /// says what the store's other readers say.
    @Test func anOpenCodeStoreItCantReadSaysSoRatherThanListingNothing() async throws {
        let harness = try OpenCodeSQLiteHarness(try OpenCodeStoreFixture.named("pong"))
        // OpenCode 1.x's own tables, with no `session_v2`.
        try harness.execute("ALTER TABLE session_v2 RENAME TO gone; CREATE TABLE session (id TEXT)")
        let rig = try await openCodeRig(store: PickOpenCodeStore(harness: harness))

        let chat = try await listing(rig)

        #expect(chat.candidates == .unavailable(ChatSessionStoreProblem.olderOpenCode.explanation))
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aGrokBuildWithNoMatchingRowListsItsCandidatesAndBindsNothing() async throws {
        let rig = try await grokRig()

        let chat = try await listing(rig)

        let list = try Self.listed(chat)
        #expect(list.candidates.map(\.sessionID) == [Self.grokHeld, Self.grokChild, Self.grokRecent])
        // The folder of the file it holds is in the directory too.
        #expect(list.candidates.map(\.origins) == [[.heldOpen, .recentTranscript], [.programStatus], [.recentTranscript]])

        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        #expect(await rig.transport.mutations.isEmpty)
        #expect(await chat.confirmSessionBeforeSend() != nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// Grok Build's recorded children are `s0` and `s1`, which name no conversation
    /// (`host-evidence/grok/s-flag-core-events.ndjson`).
    @Test func aStatusChildThatNamesNoConversationIsNotListed() async throws {
        let rig = try await grokRig(children: ["s0", "s1"])

        let chat = try await listing(rig)

        #expect(try Self.listed(chat).candidates.map(\.sessionID) == [Self.grokHeld, Self.grokRecent])
        chat.end()
        rig.store.setHosts([])
    }

    @Test func nothingIsListedUntilTheUserAsks() async throws {
        let rig = try await grokRig()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntilCannotTell(chat)

        #expect(chat.acceptsPicks)
        #expect(chat.offersCandidates)
        #expect(chat.candidates == .notAsked)
        #expect(await rig.files.listings.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    /// A list comes from one exec of its own, and asks for open files.
    @Test func aListingReadsTheProcessOnce() async throws {
        let rig = try await grokRig()
        let core = try #require(rig.store.coreProjection(on: host.id))

        _ = try await core.chatCandidates(paneID: "t1", program: .grok)

        let requests = await rig.transport.processTable.requests
        #expect(requests.count == 1)
        #expect(requests.first?.readsOpenFiles == true)
        rig.store.setHosts([])
    }

    // MARK: Reading before choosing

    @Test func aCandidatesConversationCanBeReadAndTouchesNothing() async throws {
        let rig = try await grokRig()
        let chat = try await listing(rig)

        let preview = await chat.previewCandidate(try Self.candidate(Self.grokHeld, in: chat))

        guard case .conversation(_, let entries) = preview else {
            Issue.record("expected a conversation, read \(preview)")
            return
        }
        #expect(!entries.isEmpty)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        #expect(chat.conversation.transcript.entries.isEmpty)
        #expect(await rig.transport.mutations.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func anOpenCodeCandidatesConversationCanBeRead() async throws {
        let rig = try await openCodeRig()
        let chat = try await listing(rig)

        let preview = await chat.previewCandidate(try Self.candidate(try Self.pongSession, in: chat))

        guard case .conversation(let title, let entries) = preview else {
            Issue.record("expected a conversation, read \(preview)")
            return
        }
        #expect(title == "Pong")
        #expect(!entries.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aCandidateNobodyCouldReadSaysSoAndCannotBeChosen() async throws {
        let rig = try await grokRig()
        let chat = try await listing(rig)
        // The status child has no Transcript under it.
        let unread = try Self.candidate(Self.grokChild, in: chat)

        guard case .unreadable = await chat.previewCandidate(unread) else {
            Issue.record("expected it to read as unreadable")
            return
        }
        await chat.confirmCandidate(unread)

        #expect(await rig.transport.labelWrites.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aCandidateNotYetReadCannotBeConfirmed() async throws {
        let rig = try await grokRig()
        let chat = try await listing(rig)

        await chat.confirmCandidate(try Self.candidate(Self.grokHeld, in: chat))

        #expect(await rig.transport.labelWrites.isEmpty)
        #expect(chat.pickConfirmation == .none)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Confirming

    private func confirmed(_ rig: Rig, session: String) async throws -> AgentChatStore {
        let chat = try await listing(rig)
        let candidate = try Self.candidate(session, in: chat)
        _ = await chat.previewCandidate(candidate)
        await chat.confirmCandidate(candidate)
        return chat
    }

    @Test func confirmingWritesOneLabelThroughTheMutationDispatchAndChatFollowsIt() async throws {
        let rig = try await grokRig()

        let chat = try await confirmed(rig, session: Self.grokHeld)

        #expect(chat.pickConfirmation == .confirmed)
        #expect(await rig.transport.mutations == ["terminal.label"])
        let write = try #require(await rig.transport.labelWrites.first)
        #expect(write["terminal"]?.stringValue == "t1")
        #expect(
            write["labels"]
                == .object(["heeler.chat": .string(#"{"pid":40,"session":"\#(Self.grokHeld)","start":"145585"}"#)]))
        try await rig.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        #expect(await chat.confirmSessionBeforeSend() == nil)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aConfirmedOpenCodeConversationIsFollowedFromTheStore() async throws {
        let rig = try await openCodeRig()
        let pong = try Self.pongSession

        let chat = try await confirmed(rig, session: pong)

        try await rig.waitUntil("Chat to follow it") { chat.conversation.transcript.title == "Pong" }
        #expect(await rig.pickWrites == [Self.pickLabel(session: pong)])
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aLabelWriteWithNoAnswerReadsOutcomeUnknownAndIsNeverRepeated() async throws {
        let rig = try await grokRig()
        await rig.transport.setLabelFailure(TransportError.coreMutationOutcomeUnknown)
        let chat = try await listing(rig)
        let candidate = try Self.candidate(Self.grokHeld, in: chat)
        _ = await chat.previewCandidate(candidate)

        await chat.confirmCandidate(candidate)
        #expect(chat.pickConfirmation == .outcomeUnknown)
        await chat.confirmCandidate(candidate)

        #expect(chat.pickConfirmation == .outcomeUnknown)
        #expect(await rig.transport.labelWrites.count == 1)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        chat.end()
        rig.store.setHosts([])
    }

    /// A refusal is an answer: nothing landed, so asking again is safe.
    @Test func aRefusedWriteSaysSoAndCanBeChosenAgain() async throws {
        let rig = try await grokRig()
        await rig.transport.setLabelFailure(HerdrAPIError(code: "refused", message: "the core said no"))
        let chat = try await listing(rig)
        let candidate = try Self.candidate(Self.grokHeld, in: chat)
        _ = await chat.previewCandidate(candidate)

        await chat.confirmCandidate(candidate)
        #expect(chat.pickConfirmation == .failed("the core said no"))

        await rig.transport.setLabelFailure(nil)
        await chat.confirmCandidate(candidate)

        #expect(chat.pickConfirmation == .confirmed)
        #expect(await rig.transport.labelWrites.count == 2)
        chat.end()
        rig.store.setHosts([])
    }

    /// A detail keeps to its own core (ADR 0031): after the Host's core changed, its
    /// address means another Terminal.
    @Test func aDetailThatLeftItsCoreListsNothingAndWritesNothing() async throws {
        let rig = try await grokRig()
        let chat = try await listing(rig)
        let candidate = try Self.candidate(Self.grokHeld, in: chat)
        _ = await chat.previewCandidate(candidate)
        let left = TerminalCorePin(joined: "another core")

        await chat.confirmCandidate(candidate, keepingTo: left)
        guard case .failed = chat.pickConfirmation else {
            Issue.record("expected the confirmation to fail, read \(chat.pickConfirmation)")
            return
        }
        #expect(await rig.transport.labelWrites.isEmpty)

        await chat.listCandidates(keepingTo: left)
        guard case .unavailable = chat.candidates else {
            Issue.record("expected no list, read \(chat.candidates)")
            return
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// A list taken on one core does not write on the next one the Host serves.
    @Test func aListFromAnEarlierCoreWritesNothingOnTheNextOne() async throws {
        let rig = try await grokRig()
        let chat = try await listing(rig)
        let candidate = try Self.candidate(Self.grokHeld, in: chat)
        _ = await chat.previewCandidate(candidate)
        let list = try Self.listed(chat)
        #expect(list.core == "c1")
        let core = try #require(rig.store.coreProjection(on: host.id))

        var earlier = list
        earlier.core = "another core"
        await #expect(throws: (any Error).self) {
            try await core.writeChatPick(candidate, of: earlier, paneID: "t1")
        }

        #expect(await rig.transport.labelWrites.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: A second device

    @Test func aSecondDeviceAdoptsALabelForTheResolvedProcess() async throws {
        let first = try await grokRig()
        _ = try await confirmed(first, session: Self.grokHeld)
        let label = try #require(await first.pickWrites.first)
        first.store.setHosts([])

        let second = try await grokRig(labels: ["heeler.chat": label])
        let chat = try second.chat()
        chat.show()

        try await second.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        #expect(await second.transport.labelWrites.isEmpty)
        chat.end()
        second.store.setHosts([])
    }

    /// The label's event is what tells a device already watching.
    @Test func aDeviceWatchingAdoptsALabelAsItArrivesAndLetsItGo() async throws {
        let rig = try await grokRig()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntilCannotTell(chat)

        await rig.transport.deliver(
            Self.labelsEvent(sequence: 2, labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)]))
        try await rig.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }

        try await rig.waitUntil("its rows") { !chat.conversation.transcript.entries.isEmpty }

        await rig.transport.deliver(Self.labelsEvent(sequence: 3, labels: [:]))
        try await rig.waitUntilCannotTell(chat)
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    @Test(arguments: [(pid: 9, start: start), (pid: pid, start: "111")])
    func aSecondDeviceIgnoresAndClearsALabelFromAnEarlierProcess(pid: Int, start: String) async throws {
        let rig = try await grokRig(labels: [
            "heeler.chat": Self.pickLabel(session: Self.grokHeld, pid: pid, start: start)
        ])
        let chat = try rig.chat()
        chat.show()

        try await rig.waitUntilCannotTell(chat)

        try await Self.waitForClear(rig)
        #expect(await rig.pickWrites.allSatisfy(\.isEmpty))
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Dropping

    private func following() async throws -> (Rig, AgentChatStore) {
        let rig = try await grokRig(labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)])
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        try await rig.waitUntil("its rows") { !chat.conversation.transcript.entries.isEmpty }
        return (rig, chat)
    }

    private static func waitForClear(_ rig: Rig, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<500 where await !rig.pickWrites.contains("") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.pickWrites.contains(""), sourceLocation: sourceLocation)
    }

    @Test(arguments: [(pid: 41, start: start), (pid: pid, start: "999")])
    func aForegroundOfAnotherProcessDropsThePick(pid: Int, start: String) async throws {
        let (rig, chat) = try await following()

        await rig.transport.processTable.remove(Self.pid)
        await rig.transport.processTable.add(Self.process(.grok, pid: pid, start: start))
        await rig.transport.deliver(
            Self.event(
                sequence: 2, type: "foreground",
                data: Self.foreground(argv: [.string("grok")], name: "grok", pid: pid)))

        try await rig.waitUntilCannotTell(chat)
        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aSessionLabelFromThisProcessDropsThePick() async throws {
        let (rig, chat) = try await following()
        let label = Self.pickLabel(session: Self.grokHeld)
        let session = #"{"session":"\#(Self.grokRecent)","pid":40,"start":"145585"}"#

        await rig.transport.deliver(
            Self.labelsEvent(sequence: 2, labels: ["heeler.chat": label, "heeler.session": session]))

        try await rig.waitUntilCannotTell(chat)
        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: The send guard

    /// A Chat only the test moves, on a clock only the test moves, so a test knows a
    /// read started after the turn and that the guard judged it.
    private func steppedFollowing() async throws -> (Rig, AgentChatStore) {
        let rig = try await grokRig(
            labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)], steppedByTheTest: true)
        let chat = try rig.chat()
        try await rig.stepUntil(chat, "Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
                && !chat.conversation.transcript.entries.isEmpty
        }
        return (rig, chat)
    }

    /// The picked conversation is still what Chat follows, and no label was written.
    private static func expectPickKept(
        _ rig: Rig, _ chat: AgentChatStore, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(chat.conversation.phase == .following(path: grokFile(grokHeld)), sourceLocation: sourceLocation)
        #expect(await rig.pickWrites.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func aMessageMissingOnceTheTurnEndsDropsThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("this never reaches the bound conversation", on: chat)

        try await rig.runTurn {
            // A turn under way says nothing yet, however long it takes.
            await rig.passGuardSettle(chat)
            rig.clock.advance(60)
            await chat.step()
            await Self.expectPickKept(rig, chat)
        }
        // Nor does a read before the program had its time to write.
        rig.clock.advance(AgentChatStore.Timing().pickGuardSettle / 2)
        await chat.step()
        await Self.expectPickKept(rig, chat)

        await rig.passGuardSettle(chat)

        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        // Nothing is left that claims a conversation.
        #expect(await chat.confirmSessionBeforeSend() != nil)
        await chat.step()
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    private static let piLaunched = "019a0000-0000-7000-8000-00000000a001"

    private static func piFile(_ session: String) -> String {
        "\(home)/.pi/agent/sessions/--work-app--/2026-11-01T07-19-26-219Z_\(session).jsonl"
    }

    private static func piTranscript(session: String) throws -> Data {
        let data = try ChatFixture.data("pi/provider-retry.jsonl")
        let recorded = try #require(PiTranscriptLocator.sessionID(inHead: data))
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: recorded, with: session).utf8)
    }

    /// hc-lab P11: a Pi Heeler started, then `/new` in the terminal. Its launch hint
    /// still names the first conversation and nothing on the Host says Pi left it, so
    /// a Send from Chat stayed "Sent. It hasn't appeared…". The guard watches that
    /// binding as it does a pick: a message missing once the turn ends drops the hint
    /// here and on the core.
    @Test func aPiLaunchHintTheTurnDisprovesIsDropped() async throws {
        var record = Self.record(
            .pi, argv: ["pi", "--session-id", Self.piLaunched],
            labels: [HerdrCoreLaunch.sessionHintLabel: Self.piLaunched])
        // Heeler's launch runs Pi as the Terminal's own process.
        if case .object(var fields) = record {
            fields["pid"] = .number(Double(Self.pid))
            record = .object(fields)
        }
        let rig = Rig(host: host, program: .pi, record: record, steppedByTheTest: true)
        await rig.files.write(try Self.piTranscript(session: Self.piLaunched), at: Self.piFile(Self.piLaunched))
        try await rig.start([Self.process(.pi, argv: ["pi", "--session-id", Self.piLaunched])])
        let chat = try rig.chat()
        try await rig.stepUntil(chat, "Chat to follow it") {
            chat.conversation.phase == .following(path: Self.piFile(Self.piLaunched))
                && !chat.conversation.transcript.entries.isEmpty
        }

        Self.send("this goes to the conversation /new started", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)

        rig.expectLeftConversation(chat)
        func hintWrites() async -> [String] {
            await rig.transport.labelWrites.compactMap {
                $0["labels"]?[HerdrCoreLaunch.sessionHintLabel]?.stringValue
            }
        }
        for _ in 0..<500 where await hintWrites().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await hintWrites() == [""])
        // Whatever the record still holds, the hint is not taken again.
        await rig.nudgeCheck()
        await chat.step()
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// hc-lab D1: Grok Build 1.0.70 wrote its `active_sessions.json` row 0.18 s after
    /// the core's idle, and nothing checked after it until Check Again. While Chat
    /// can't tell, one more check follows a few seconds after an idle report, and no
    /// other: no clock asks again.
    @Test func aGrokRowWrittenJustAfterIdleBindsAtTheOneLaterCheck() async throws {
        let rig = try await grokRig(steppedByTheTest: true)
        let chat = try rig.chat()
        try await rig.stepUntil(chat, "Chat to say it cannot tell") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.grok))
        }
        try await rig.runTurn()
        // The checks the turn's events ask for, with the row not written yet.
        await chat.step()
        try await Task.sleep(for: .milliseconds(50))
        await chat.step()
        let checks = await rig.transport.processTable.requests.count

        await rig.files.write(
            #"[{"session_id":"\#(Self.grokHeld)","pid":\#(Self.pid),"pid_start":\#(Self.start),"cwd":"/work/app"}]"#,
            at: "\(Self.home)/.grok/active_sessions.json")
        await chat.step()
        #expect(await rig.transport.processTable.requests.count == checks)
        let delay = try #require(AgentChatStore.Timing().lateEvidenceCheck[.grok])
        #expect(chat.interval <= .seconds(delay))
        rig.clock.advance(delay)
        await chat.step()
        #expect(await rig.transport.processTable.requests.count == checks + 1)
        try await rig.stepUntil(chat, "Chat to follow the row") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }

        rig.clock.advance(60)
        await chat.step()
        #expect(await rig.transport.processTable.requests.count == checks + 1)
        chat.end()
        rig.store.setHosts([])
    }

    /// The message the guard judged stays as an echo only until its clock runs out,
    /// and then nothing holds a timeline up over the reason.
    @Test func aMissingMessageLeavesNoTimelineOnceItsEchoEnds() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, "this never reaches the bound conversation", delivered: false)])
        chat.updateSends([Self.sent(id, "this never reaches the bound conversation")])

        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        rig.clock.advance(AgentChatStore.Timing().echoTimeout)
        await chat.step()

        #expect(chat.sendStatuses[id] == .abandoned)
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    @Test func aMessageThatAppearsKeepsThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, Self.grokPrompt, delivered: false)])
        chat.updateSends([Self.sent(id, Self.grokPrompt)])

        try await rig.runTurn {
            await rig.files.write(
                try Self.grokTranscript(session: Self.grokHeld, lines: 7), at: Self.grokFile(Self.grokHeld))
        }
        await rig.passGuardSettle(chat)

        #expect(chat.sendStatuses[id] == .recorded)
        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A `/` command is the program's to answer, and many never reach a Transcript. The
    /// message beside it is what the guard goes on.
    @Test func aCommandSaysNothingAboutThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("/compact", on: chat)

        try await rig.runTurn()
        await rig.passGuardSettle(chat)

        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// The failure this rule is for: verify finds the text still in the input box, the
    /// user clears it in the terminal, and the next Send goes where the pick says.
    @Test func aMessageLeftInTheInputBoxSaysNothingAboutThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let (first, second) = (UUID(), UUID())
        let left = "left in the input box"
        chat.updateSends([Self.sent(first, left, delivered: false)])
        chat.updateSends([Self.sent(first, left)])
        chat.updateSends([Self.sent(first, left, mayNotHaveGone: true)])
        chat.updateSends([
            Self.sent(first, left, mayNotHaveGone: true), Self.sent(second, Self.grokPrompt, delivered: false),
        ])
        chat.updateSends([Self.sent(first, left, mayNotHaveGone: true), Self.sent(second, Self.grokPrompt)])

        try await rig.runTurn {
            await rig.files.write(
                try Self.grokTranscript(session: Self.grokHeld, lines: 7), at: Self.grokFile(Self.grokHeld))
        }
        rig.clock.advance(AgentChatStore.Timing().echoTimeout)
        await rig.passGuardSettle(chat)

        #expect(chat.sendStatuses[second] == .recorded)
        #expect(chat.sendStatuses[first] == .overdue)
        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A paste that got no answer may never have reached the program, whatever turn
    /// ends after it.
    @Test func aSendWithNoAnswerSaysNothingAboutThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        let text = "this paste got no answer"
        chat.updateSends([Self.sent(id, text, delivered: false)])
        chat.updateSends([Self.sent(id, text, mayNotHaveGone: true)])

        try await rig.runTurn()
        rig.clock.advance(AgentChatStore.Timing().echoTimeout)
        await rig.passGuardSettle(chat)

        #expect(chat.sendStatuses[id] == .overdue)
        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// One send in doubt takes nothing from the one beside it that went.
    @Test func aMessageThatWentStillDropsThePickBesideOneInDoubt() async throws {
        let (rig, chat) = try await steppedFollowing()
        let (first, second) = (UUID(), UUID())
        let (left, gone) = ("left in the input box", "this never reaches the bound conversation")
        chat.updateSends([Self.sent(first, left, delivered: false), Self.sent(second, gone, delivered: false)])
        chat.updateSends([Self.sent(first, left, mayNotHaveGone: true), Self.sent(second, gone)])

        try await rig.runTurn()
        await rig.passGuardSettle(chat)

        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    /// The program's own log naming another session says the send went, and where,
    /// whatever the Composer could tell.
    @Test func aSendInDoubtTheLogPlacesElsewhereDropsThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let history = "\(Self.home)/.grok/sessions/%2Fwork%2Fapp/prompt_history.jsonl"
        func logged(_ prompt: String, session: String) -> String {
            #"{"is_bash":false,"prompt":"\#(prompt)","session_id":"\#(session)"}"# + "\n"
        }
        await rig.files.write(logged("earlier", session: Self.grokHeld), at: history)
        let id = UUID()
        let text = "Reply with the word lime."
        chat.updateSends([Self.sent(id, text, delivered: false)])
        await chat.witnessMarksSettled()
        #expect(chat.sendConcern(for: text, after: GrokScreenBuilder(scrollback: []).screen) == nil)
        chat.updateSends([Self.sent(id, text, mayNotHaveGone: true)])
        await rig.files.append(logged(GrokTranscriptReducer.echoKey(text), session: Self.grokRecent), to: history)
        rig.clock.advance(AgentChatStore.Timing().witnessFirstRead)
        await chat.step()
        #expect(chat.sendStatuses[id] == .misdirected)

        try await rig.runTurn()
        await rig.passGuardSettle(chat)

        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    /// The label may outlast the drop, when its removal gets no further and the core
    /// reports it again. This device does not take it back, and removes it again.
    @Test func aDroppedPickStaysDroppedWhenItsRemovalFails() async throws {
        let (rig, chat) = try await steppedFollowing()
        await rig.transport.setLabelFailure(TransportError.sshUnreachable(detail: "the link went"))
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        try await Self.waitForClear(rig)
        let attempts = await rig.pickWrites.count

        await rig.transport.setLabelFailure(nil)
        await rig.transport.deliver(
            Self.labelsEvent(sequence: 40, labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)]))

        for _ in 0..<500 where await rig.pickWrites.count == attempts {
            await chat.step()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.pickWrites.dropFirst(attempts).first == "")
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A guard's verdict is about the core it judged. On the core that took its place
    /// the same address and label mean another Terminal (ADR 0031).
    @Test func aGuardDropFromAnEarlierCoreLeavesThisCoreAlone() async throws {
        let (rig, chat) = try await steppedFollowing()
        let core = try #require(rig.store.coreProjection(on: host.id))
        let picked = ChatSessionEvidence.picked(sessionID: Self.grokHeld, transcriptRoot: "\(Self.home)/.grok")
        #expect(try await core.checkChatSession(paneID: "t1", program: .grok) == picked)

        core.dropChatPick(paneID: "t1", scope: "an earlier core", program: .grok)

        #expect(try await core.checkChatSession(paneID: "t1", program: .grok) == picked)
        #expect(await rig.pickWrites.isEmpty)

        core.dropChatPick(paneID: "t1", scope: core.chatCacheScope, program: .grok)

        #expect(try await core.checkChatSession(paneID: "t1", program: .grok) == .unavailable(.cannotTellSession(.grok)))
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    /// A check that sees no process to hold the pick against says nothing about the
    /// pick: the conversation stays readable, and sending waits for a check that can say.
    @Test func aCheckThatCannotSeeTheProcessKeepsThePick() async throws {
        let (rig, chat) = try await following()
        let shown = chat.conversation.transcript.entries

        await rig.hideTerminalProcess()
        await rig.nudgeCheck()
        try await rig.waitUntilCannotTell(chat)

        #expect(chat.conversation.transcript.entries == shown)
        #expect(chat.conversation.isFromCache)
        #expect(
            ChatSurfacePresentation(conversation: chat.conversation, hasPendingEchoes: false, isHostConnected: true)
                == .timeline)
        #expect(await chat.confirmSessionBeforeSend() != nil)
        #expect(await rig.pickWrites.isEmpty)

        await rig.showTerminalProcess()
        await rig.nudgeCheck()
        try await rig.waitUntil("Chat to follow it again") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        #expect(chat.conversation.transcript.entries == shown)
        #expect(await chat.confirmSessionBeforeSend() == nil)
        chat.end()
        rig.store.setHosts([])
    }

    /// The pick's guard outlasts such a check: what was sent before it is still judged.
    @Test func aCheckThatCannotSeeTheProcessKeepsTheSendGuard() async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("this never reaches the bound conversation", on: chat)

        try await rig.runTurn {
            await rig.hideTerminalProcess()
            await rig.nudgeCheck()
            try await rig.stepUntil(chat, "Chat to say it cannot tell") {
                chat.conversation.phase == .unavailable(.cannotTellSession(.grok))
            }
            await rig.showTerminalProcess()
            await rig.nudgeCheck()
            try await rig.stepUntil(chat, "Chat to follow it again") {
                chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
            }
        }
        await rig.passGuardSettle(chat)

        rig.expectLeftConversation(chat)
        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    /// Once the label is gone the pick is too, even while Chat waited on a check.
    @Test func aLabelRemovedWhileAwaitingACheckLeavesTheConversation() async throws {
        let (rig, chat) = try await following()
        await rig.hideTerminalProcess()
        await rig.nudgeCheck()
        try await rig.waitUntilCannotTell(chat)
        #expect(!chat.conversation.transcript.entries.isEmpty)

        await rig.transport.deliver(Self.labelsEvent(sequence: 90, labels: [:]))

        try await rig.waitUntil("the conversation to go") { chat.conversation.transcript.entries.isEmpty }
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// The user can choose the same conversation again after it was dropped.
    @Test func aPickDroppedEarlierCanBeChosenAgain() async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))

        await chat.listCandidates()
        let candidate = try Self.candidate(Self.grokHeld, in: chat)
        _ = await chat.previewCandidate(candidate)
        await chat.confirmCandidate(candidate)

        try await rig.stepUntil(chat, "Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// What the core can say that shows a value a guard dropped is no longer on it.
    enum DroppedValueGone: CaseIterable {
        case labelRemoved, onlyOtherLabels, anotherPick, inventoryWithoutIt
    }

    private static func report(_ gone: DroppedValueGone, sequence: Int) -> Data {
        switch gone {
        case .labelRemoved: labelsEvent(sequence: sequence, labels: [:])
        case .onlyOtherLabels: labelsEvent(sequence: sequence, labels: ["other": "kept"])
        case .anotherPick: labelsEvent(sequence: sequence, labels: ["heeler.chat": pickLabel(session: grokRecent)])
        case .inventoryWithoutIt: inventory(sequence: sequence, labels: [:])
        }
    }

    /// Once the core says the value is gone, the same value arriving is someone
    /// confirming that conversation again on another device, which every device adopts.
    @Test(arguments: DroppedValueGone.allCases)
    func aDroppedPickConfirmedAgainElsewhereIsAdopted(after gone: DroppedValueGone) async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        #expect(chat.conversation.phase == .unavailable(.cannotTellSession(.grok)))
        try await Self.waitForClear(rig)
        let writes = await rig.pickWrites.count

        await rig.transport.deliver(Self.report(gone, sequence: 40))
        await rig.transport.deliver(
            Self.labelsEvent(sequence: 41, labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)]))

        try await rig.stepUntil(chat, "Chat to follow it again") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
                && !chat.conversation.transcript.entries.isEmpty
        }
        #expect(await rig.pickWrites.count == writes)
        chat.end()
        rig.store.setHosts([])
    }

    /// An inventory still holding the value is a removal that did not arrive, as a
    /// labels event still holding it is.
    @Test func aDroppedPickAFreshInventoryStillHoldsIsRemovedAgain() async throws {
        let (rig, chat) = try await steppedFollowing()
        await rig.transport.setLabelFailure(TransportError.sshUnreachable(detail: "the link went"))
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        try await Self.waitForClear(rig)
        let attempts = await rig.pickWrites.count

        await rig.transport.setLabelFailure(nil)
        await rig.transport.deliver(
            Self.inventory(sequence: 40, labels: ["heeler.chat": Self.pickLabel(session: Self.grokHeld)]))

        for _ in 0..<500 where await rig.pickWrites.count == attempts {
            await chat.step()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.pickWrites.dropFirst(attempts).first == "")
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A removal's answer can trail what the core reported after it. By then the label
    /// the core holds is the newer choice, which that answer says nothing about.
    @Test func aRemovalAnsweredAfterTheSameChoiceCameBackLeavesItStanding() async throws {
        let (rig, chat) = try await steppedFollowing()
        let answer = ScriptedTransportCallGate()
        await rig.transport.holdLabelWrites(using: answer)
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        try await Self.waitForClear(rig)

        await rig.transport.deliver(Self.labelsEvent(sequence: 40, labels: [:]))
        let label = Self.pickLabel(session: Self.grokHeld)
        await rig.transport.deliver(Self.labelsEvent(sequence: 41, labels: ["heeler.chat": label, "seen": "41"]))
        // A check before both have landed would wait on the held answer too.
        let core = try #require(rig.store.coreProjection(on: host.id))
        try await rig.waitUntil("both reports") { core.terminalRecord(at: "t1")?.labels["seen"] == "41" }
        let following = ChatConversationSnapshot.Phase.following(path: Self.grokFile(Self.grokHeld))
        try await rig.stepUntil(chat, "Chat to follow it again") { chat.conversation.phase == following }

        await answer.open()
        await core.pickRemoval?.value
        await chat.step()

        #expect(chat.conversation.phase == following)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: What a read can prove

    /// Lines the reducer takes for nothing, enough to pass one poll's budget of 2 MiB.
    private static func backlog(lines: Int = 48) -> Data {
        let filler = String(repeating: "x", count: 64 << 10)
        return Data(String(repeating: #"{"method":"noise","text":"\#(filler)"}"# + "\n", count: lines).utf8)
    }

    /// Lines 4 to 7 of `grokTranscript`: the prompt `grokPrompt`, and its answer.
    private static func grokReply(session: String) throws -> Data {
        let whole = try grokTranscript(session: session, lines: 7)
        return whole.dropFirst(try grokTranscript(session: session).count)
    }

    /// A poll stops at its budget. The prompt behind that is not missing, only unread.
    @Test func aMessageBehindAnUnreadBacklogKeepsThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, Self.grokPrompt, delivered: false)])
        chat.updateSends([Self.sent(id, Self.grokPrompt)])

        try await rig.runTurn {
            await rig.files.append(
                Self.backlog() + (try Self.grokReply(session: Self.grokHeld)), to: Self.grokFile(Self.grokHeld))
        }
        await rig.passGuardSettle(chat)
        await Self.expectPickKept(rig, chat)

        try await rig.stepUntil(chat, "the read to reach it") { chat.sendStatuses[id] == .recorded }
        await rig.passGuardSettle(chat)
        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A rewritten file reopens at its tail, so a prompt before that window cannot
    /// match. What that window leaves out says nothing about the pick.
    @Test func aMessageLeftBeforeARewrittenFilesTailKeepsThePick() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, Self.grokPrompt, delivered: false)])
        chat.updateSends([Self.sent(id, Self.grokPrompt)])

        try await rig.runTurn {
            var rewritten = try Self.grokTranscript(session: Self.grokHeld, lines: 7)
            rewritten.append(Self.backlog(lines: 24))
            guard let shifted = String(data: rewritten, encoding: .utf8) else { return }
            await rig.files.write(
                shifted.replacingOccurrences(of: "1792421826", with: "1792421827"), at: Self.grokFile(Self.grokHeld))
        }
        await rig.passGuardSettle(chat)

        #expect(chat.sendStatuses[id] != .recorded)
        await Self.expectPickKept(rig, chat)

        // The next message that goes missing still says the pick is wrong.
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Which turn judges

    /// A queued message: the turn that ended was not the one that took it, and the next
    /// one starting inside the settle time says so.
    @Test func aNewTurnCancelsAPendingJudgement() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, Self.grokPrompt, delivered: false)])
        chat.updateSends([Self.sent(id, Self.grokPrompt)])

        try await rig.runTurn()
        try await rig.runTurn {
            await rig.passGuardSettle(chat)
            await Self.expectPickKept(rig, chat)
            await rig.files.append(try Self.grokReply(session: Self.grokHeld), to: Self.grokFile(Self.grokHeld))
        }
        await rig.passGuardSettle(chat)

        #expect(chat.sendStatuses[id] == .recorded)
        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    /// A message delivered after the turn ended is the next turn's to judge.
    @Test func aSendAfterTheTurnEndedIsNotJudgedByIt() async throws {
        let (rig, chat) = try await steppedFollowing()
        let id = UUID()
        chat.updateSends([Self.sent(id, Self.grokPrompt, delivered: false)])
        chat.updateSends([Self.sent(id, Self.grokPrompt)])
        try await rig.runTurn {
            await rig.files.append(try Self.grokReply(session: Self.grokHeld), to: Self.grokFile(Self.grokHeld))
        }

        rig.clock.advance(AgentChatStore.Timing().pickGuardSettle / 2)
        Self.send("this never reaches the bound conversation", on: chat)
        await rig.passGuardSettle(chat)
        await Self.expectPickKept(rig, chat)

        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: Between links

    /// A verdict can land where the core has no record to read the label from. It
    /// holds once the snapshot brings the label back, which goes again.
    @Test func aVerdictReachedBetweenLinksOutlastsTheSnapshot() async throws {
        let (rig, chat) = try await steppedFollowing()
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.transport.holdSubscribes()
        await rig.store.suspend()
        await rig.store.resume()
        await rig.transport.waitForSubscribe(count: 2)
        try await rig.waitUntil("the link, with no snapshot yet") {
            rig.store.hostStatuses[self.host.id] == .connected && rig.store.hostsAwaitingSnapshot.contains(self.host.id)
        }

        await rig.passGuardSettle(chat)
        rig.expectLeftConversation(chat)

        await rig.transport.releaseSubscribes()
        try await rig.waitUntil("the snapshot") { !rig.store.hostsAwaitingSnapshot.contains(self.host.id) }
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft, await !rig.pickWrites.contains("") {
            await chat.step()
            await Task.yield()
            budget.charge()
        }
        #expect(await rig.pickWrites == [""])
        await chat.step()
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: A removal that fails

    /// With the link up nothing reports the label again, so this device's next check
    /// is what removes it.
    @Test func aRemovalTheCoreRefusedGoesAgainAtTheNextCheck() async throws {
        let (rig, chat) = try await steppedFollowing()
        await rig.transport.setLabelFailure(HerdrAPIError(code: "internal", message: "refused"))
        Self.send("this never reaches the bound conversation", on: chat)
        try await rig.runTurn()
        await rig.passGuardSettle(chat)
        try await Self.waitForClear(rig)
        let core = try #require(rig.store.coreProjection(on: host.id))
        await core.pickRemoval?.value
        let attempts = await rig.pickWrites.count

        await rig.transport.setLabelFailure(nil)
        await rig.nudgeCheck()
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft, await rig.pickWrites.count == attempts {
            await chat.step()
            await Task.yield()
            budget.charge()
        }

        #expect(await rig.pickWrites.dropFirst(attempts).first == "")
        rig.expectLeftConversation(chat)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: An Agent that quits to its shell

    private static func shellForeground() -> Data {
        event(
            sequence: 60, type: "foreground",
            data: foreground(argv: [.string("bash")], name: "bash", pid: shell))
    }

    /// The Agent leaves the list in the pass that would have asked for a check, and its
    /// store ends with it. The label does not stay behind for the Terminal's life.
    @Test func quittingToTheShellRemovesThePicksLabel() async throws {
        let (rig, chat) = try await following()

        await rig.transport.processTable.remove(Self.pid)
        await rig.transport.deliver(Self.shellForeground())

        try await Self.waitForClear(rig)
        chat.end()
        rig.store.setHosts([])
    }

    /// Ctrl-Z also hands the shell the foreground, with the Agent's process still under
    /// it, and that process is what the pick names.
    @Test func aSuspendedAgentKeepsThePicksLabel() async throws {
        let (rig, chat) = try await following()
        let checks = await rig.transport.processTable.requests.count

        await rig.transport.deliver(Self.shellForeground())

        try await rig.waitUntil("the Agent to leave the list") { rig.store.agents.isEmpty }
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft, await rig.transport.processTable.requests.count == checks {
            await Task.yield()
            budget.charge()
        }
        let core = try #require(rig.store.coreProjection(on: host.id))
        #expect(
            try await core.checkChatSession(paneID: "t1", program: .grok)
                == .picked(sessionID: Self.grokHeld, transcriptRoot: "\(Self.home)/.grok"))
        #expect(await rig.pickWrites.isEmpty)
        chat.end()
        rig.store.setHosts([])
    }

    /// Exact evidence needs no guard: a send it does not find proves nothing about
    /// which conversation the Agent is in.
    @Test func anExactBindingHasNoSendGuard() async throws {
        let rig = Rig(host: host, program: .grok, record: Self.record(.grok, app: "grok-build"), steppedByTheTest: true)
        await rig.files.write(
            #"[{"session_id":"\#(Self.grokHeld)","pid":40,"pid_start":145585,"cwd":"/work/app"}]"#,
            at: "\(Self.home)/.grok/active_sessions.json")
        await rig.files.write(try Self.grokTranscript(session: Self.grokHeld), at: Self.grokFile(Self.grokHeld))
        try await rig.start([Self.process(.grok)])
        let chat = try rig.chat()
        try await rig.stepUntil(chat, "Chat to follow it") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
        #expect(!chat.offersCandidates)
        Self.send("this never arrives", on: chat)

        try await rig.runTurn()
        await rig.passGuardSettle(chat)

        await Self.expectPickKept(rig, chat)
        chat.end()
        rig.store.setHosts([])
    }

    // MARK: No list

    @Test func aCodexOnTheSharedDaemonGetsNoListOnlyTheReopenMessage() async throws {
        let rig = Rig(host: host, program: .codex, record: Self.record(.codex))
        try await rig.start([
            Self.process(.codex, argv: ["codex"]),
            ScriptedProcessTable.Process(
                pid: 41, parent: Self.pid, name: "codex", start: "2",
                environment: ["HC_SCOPE": "scope", "HOME": Self.home],
                argv: ["codex", "app-server", "--managed-daemon"]),
        ])
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntil("the message") { chat.conversation.phase == .unavailable(.codexSharedDaemon) }

        #expect(!chat.offersCandidates)
        await chat.listCandidates()
        #expect(chat.candidates == .notAsked)
        let core = try #require(rig.store.coreProjection(on: host.id))
        #expect(try await core.chatCandidates(paneID: "t1", program: .codex) == .sharedDaemon)
        #expect(await rig.files.listings.isEmpty)
        #expect(ChatUnavailableReason.codexSharedDaemon.explanation.contains("codex resume \(ChatLaunchNotice.unbrokenNoDaemon)"))
        chat.end()
        rig.store.setHosts([])
    }

    /// Before its first prompt it holds no rollout and has no daemon under it, and the
    /// shared server's socket says which kind it is.
    @Test func aCodexLaunchedOnTheSharedServerGetsNoListEither() async throws {
        let rig = Rig(host: host, program: .codex, record: Self.record(.codex, argv: ["codex"]))
        await rig.files.write("", at: CodexLaunch.controlSocketPath(codexHome: "\(Self.home)/.codex"))
        try await rig.start([Self.process(.codex, argv: ["codex"])])
        let core = try #require(rig.store.coreProjection(on: host.id))

        #expect(try await core.chatCandidates(paneID: "t1", program: .codex) == .sharedDaemon)
        rig.store.setHosts([])
    }

    /// Herdr TUI wires no picks: its Console builds this Chat with nothing to list
    /// through.
    @Test func aHerdrTUIChatOffersNoList() async throws {
        let tui = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = ConsoleStore(
            chatCache: VolatileChatTranscriptCache(),
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            })
        defer { store.setHosts([]) }
        store.setHosts([tui])
        await store.resume()
        for _ in 0..<500 where store.agents.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let agent = try #require(store.agents.first)

        let chat = try #require(store.chatStore(for: agent, program: .grok))

        #expect(!chat.acceptsPicks)
        #expect(!chat.offersCandidates)
        await chat.listCandidates()
        #expect(chat.candidates == .notAsked)
        chat.end()
    }

    // MARK: The picker

    private struct PickerSheet: View {
        @Bindable var presence: ChatPickerPresence
        let chat: AgentChatStore
        let pin: TerminalCorePin

        var body: some View {
            Color.clear.sheet(isPresented: $presence.isOpen) {
                ChatCandidatePickerView(chat: chat, corePin: pin)
            }
        }
    }

    /// Chat keeps a conversation it can no longer place, and the one edit that settles
    /// that stays on offer, from the banner over it (ADR 0033).
    @Test func anOpenCodeThatCannotTellOverItsConversationOffersTheEditFromItsBanner() async throws {
        let rig = try await openCodeRig()
        let chat = try await confirmed(rig, session: try Self.pongSession)
        try await rig.waitUntil("its rows") { !chat.conversation.transcript.entries.isEmpty }
        let suite = "core-chat-edit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UIHostingController(
            rootView: HerdrCoreChatTests.chatDetail(
                of: try #require(rig.store.agents.first), console: rig.store, defaults: defaults))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            await rig.hideTerminalProcess()
            await rig.nudgeCheck()
            try await rig.waitUntilCannotTell(chat)
            #expect(!chat.conversation.transcript.entries.isEmpty)
            let choose = ChatCandidatePickerView.title
            try await rig.waitUntil("the banner's list") {
                !AccessibilityProbe.elements(labeled: choose, in: controller.view).isEmpty
            }

            try await HerdrCoreChatTests.opensASheet(from: OpenCodePluginEdit.offerTitle, in: controller)

            let sheet = try #require(controller.presentedViewController)
            try await rig.waitUntil("the offer") {
                AccessibilityProbe.labels(in: sheet.view).contains("Review the Change")
            }
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// The write that says confirmed also empties the list, which takes the preview
    /// off the screen, so the sheet's own root is what closes it, with no preview there.
    @Test func aConfirmationClosesThePickerFromItsRoot() async throws {
        let rig = try await grokRig()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntilCannotTell(chat)
        let pin = TerminalCorePin(joined: "c1")
        let presence = ChatPickerPresence()
        let controller = UIHostingController(rootView: PickerSheet(presence: presence, chat: chat, pin: pin))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await rig.waitUntil("the sheet") { controller.presentedViewController != nil }
            try await rig.waitUntil("the list") {
                if case .listed = chat.candidates { true } else { false }
            }
            let candidate = try Self.candidate(Self.grokHeld, in: chat)
            _ = await chat.previewCandidate(candidate)

            await chat.confirmCandidate(candidate, keepingTo: pin)

            #expect(chat.pickConfirmation == .confirmed)
            try await rig.waitUntil("the sheet to close") { !presence.isOpen }
            try await rig.waitUntil("the sheet to leave") { controller.presentedViewController == nil }
        }
        chat.end()
        rig.store.setHosts([])
    }

    /// The way a user goes, through the accessibility actions a hosted window has: open
    /// a candidate from the list and use it from its preview, which the same write takes
    /// off the screen. Touch itself is the owner's check.
    @Test func usingAConversationFromItsPreviewClosesThePicker() async throws {
        let rig = try await grokRig()
        let chat = try rig.chat()
        chat.show()
        try await rig.waitUntilCannotTell(chat)
        let presence = ChatPickerPresence()
        let controller = UIHostingController(
            rootView: PickerSheet(presence: presence, chat: chat, pin: TerminalCorePin(joined: "c1")))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            @MainActor func element(_ matches: (NSObject) -> Bool) -> NSObject? {
                accessibleElements(in: window).first(where: matches)
            }
            let held = "Conversation \(Self.grokHeld.prefix(8))"
            try await rig.waitUntil("the row") {
                element { $0.accessibilityLabel?.hasPrefix(held) == true } != nil
            }
            _ = try #require(element { $0.accessibilityLabel?.hasPrefix(held) == true }).accessibilityActivate()
            @MainActor func use() -> NSObject? { accessibleElement(labeled: "Use This Conversation", in: window) }
            try await rig.waitUntil("the preview's button") { use() != nil }

            _ = try #require(use()).accessibilityActivate()

            try await rig.waitUntil("the choice") { chat.pickConfirmation == .confirmed }
            try await rig.waitUntil("the sheet to close") { !presence.isOpen }
            try await rig.waitUntil("the sheet to leave") { controller.presentedViewController == nil }
        }
        #expect(await rig.pickWrites == [Self.pickLabel(session: Self.grokHeld)])
        chat.end()
        rig.store.setHosts([])
    }
}
