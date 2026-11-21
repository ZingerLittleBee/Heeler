import Foundation
import GhosttyTerminal
import Testing

@testable import Heeler

/// A core Host's terminals from the store down: the real Console, Host session
/// and link, with the SSH connection and the core scripted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreTerminalStoreTests {
    private final class Sink: TerminalByteSink {
        var received = Data()
        func receive(_ data: Data) { received.append(data) }
    }

    /// The Console builds its Host session; this keeps hold of it.
    private final class SessionBox: @unchecked Sendable {
        var session: HerdrCoreHostSession?
    }

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        private let box = SessionBox()
        private let directory = AgentSceneDirectory()
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let console: ConsoleStore

        init(terminals: [JSONValue] = []) async throws {
            let scripted = ScriptedCoreHost(channel: .core(.init(id: "c1", terminals: terminals)))
            self.scripted = scripted
            let box = box
            console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    let session = HerdrCoreHostSession(
                        connect: {
                            await scripted.setConnected(true)
                            return scripted.transport()
                        },
                        keepalive: nil)
                    box.session = session
                    return session
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-terminals-\(UUID().uuidString)") ?? .standard),
                // Rename asks the platform as each connection lands; this follows the asks
                // a Composer and New Agent make.
                herdrAppRename: false)
            console.setHosts([host])
            await console.resume()
            try await until("the first snapshot") { [console, host] in
                !console.hostsAwaitingSnapshot.contains(host.id)
            }
        }

        var runner: TerminalSessionRunner { console.terminalRunner(for: host.id) }

        func store(
            _ address: String = "t1", viewer: TerminalViewerRole = .interactive, isViewed: Bool = true
        ) -> AttachTerminalStore {
            AttachTerminalStore(
                target: .terminal(address), viewer: viewer, isViewed: isViewed, runTerminal: runner)
        }

        /// The store's attach, once the core has answered it.
        func opened(
            _ store: AttachTerminalStore, count: Int = 1
        ) async throws -> (channel: UInt32, params: JSONValue, socket: FakeCoreSocket) {
            store.viewDidResize(cols: 80, rows: 24)
            await scripted.waitForMethod("terminal.attach", count: count)
            let attach = try #require(await scripted.attaches.last)
            return attach
        }

        func deliverOutput(_ text: String, on attach: (channel: UInt32, params: JSONValue, socket: FakeCoreSocket))
            async throws
        {
            try await attach.socket.deliver(
                HerdrCoreFrame(channel: attach.channel, kind: .data, payload: Data(text.utf8)))
        }

        /// A round trip on the link, so what it queued before has left.
        func settle() async throws {
            let session = try #require(box.session)
            for _ in 0..<2 {
                _ = try await session.withTransport { try await $0.serverStatus() }
            }
        }

        func finish() async {
            await console.terminalConnections.suspend()
            await console.agentTerminals.suspend()
            console.setHosts([])
        }
    }

    fileprivate static func until(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private static let facts = TerminalDisplayFacts(
        foreground: "#ffffff", background: "#000000", cursor: "#ff0000", cell: .init(width: 10, height: 20))

    // MARK: Credit

    @Test func bytesWaitingForASurfaceHoldTheirCreditUntilItTakesThem() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("opening", on: attach)
        try await Self.until("the first output") { store.status == .live }
        try await fixture.settle()
        #expect(await attach.socket.creditTotal(channel: attach.channel) == 0)

        let sink = Sink()
        store.feed.attach(sink)
        #expect(sink.received == Data("opening".utf8))
        await attach.socket.waitForCredit(channel: attach.channel, total: 7)
        await store.stop()
        await fixture.finish()
    }

    @Test func bytesASurfaceTakesReturnTheirCreditAndAGoneSurfaceHoldsNothingUp() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        var sink: Sink? = Sink()
        if let sink { store.feed.attach(sink) }
        try await fixture.deliverOutput("seen", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: 4)
        #expect(sink?.received == Data("seen".utf8))

        sink = nil
        try await fixture.deliverOutput("unseen", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: 10)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Viewer role, focus and facts

    @Test func aViewedAttachOpensInteractiveAndReportsFocusAndFacts() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        store.feed.updateDisplayFacts { $0 = Self.facts }
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == nil)
        #expect(attach.params["observe"] == nil)
        #expect(attach.params["takeover"] == nil)
        #expect(attach.params["display"]?["bg"] == .string("#000000"))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])])
        await store.stop()
        await fixture.finish()
    }

    @Test func aHiddenAttachReportsNothingUntilItIsViewedAndOneEdgeWhenItLeaves() async throws {
        let fixture = try await Fixture()
        let store = fixture.store(isViewed: false)
        store.feed.updateDisplayFacts { $0 = Self.facts }
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == .bool(true))
        #expect(attach.params["display"] == nil)
        store.feed.updateDisplayFacts { $0.cell = .init(width: 12, height: 24) }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).isEmpty)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).isEmpty)

        store.setViewed(true)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])])

        store.setViewed(false)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1]), Data([0])]
        }
        store.feed.updateDisplayFacts { $0.cell = .init(width: 14, height: 28) }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).count == 1)
        await store.stop()
        await fixture.finish()
    }

    @Test func aViewedAttachReportsItsFactsChangingAndEveryResize() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        store.feed.updateDisplayFacts { $0 = Self.facts }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        store.viewDidResize(cols: 100, rows: 30)
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("two resizes") {
            await attach.socket.frames(channel: attach.channel, kind: .resize).count == 2
        }
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .resize).map(\.payload)
                == [Data([100, 0, 30, 0]), Data([80, 0, 24, 0])])
        await store.stop()
        await fixture.finish()
    }

    @Test func comingBackToTheForegroundReportsFocusAndNeverNudgesTheSize() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { store.status == .live }
        store.didBecomeActive()
        try await Self.until("a second focus") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).count == 2
        }
        #expect(await attach.socket.frames(channel: attach.channel, kind: .resize).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    @Test func typedBytesReachTheAttachUnchanged() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { store.status == .live }
        store.send(Data([0x1C]))
        let typed = await attach.socket.waitForFrame(channel: attach.channel, kind: .data)
        #expect(typed.payload == Data([0x1C]))
        await store.stop()
        await fixture.finish()
    }

    /// The request already went out hidden, so nobody but this report tells the
    /// core a viewer is looking now.
    @Test func anAttachOpenedHiddenThatComesIntoViewOpeningReportsOnceOpen() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies()
        let store = fixture.store(isViewed: false)
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == .bool(true))
        #expect(attach.params["display"] == nil)

        store.setViewed(true)
        await fixture.scripted.releaseAttachReplies()

        try await Self.until("focus") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])]
        }
        store.feed.updateDisplayFacts { $0 = Self.facts }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Ending

    @Test func aServerCloseEndsTheSessionWithoutAnError() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await attach.socket.deliver(
            HerdrCoreFrame(
                channel: attach.channel, kind: .close,
                payload: Data(#"{"reason":"exited","exit_code":0}"#.utf8)))
        try await Self.until("the end") { store.status == .ended("The session ended.") }
        await fixture.finish()
    }

    // MARK: Kept restarts

    private static func keptRecord(
        address: String = "t1", argv: String = "vim", pid: Int = 7, columns: Int = 80
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string(argv)]), "keep": .bool(true), "title": .string(""),
            "cols": .number(Double(columns)), "rows": .number(24), "pid": .number(Double(pid)),
        ])
    }

    /// A kept Terminal in the middle of a restart, as a snapshot lists it.
    private static let restartingRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("vim")]), "keep": .bool(true), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "reason": .string("signaled"),
    ])

    private static let finishedRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("finished"),
        "argv": .array([.string("vim")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "reason": .string("exited"), "exit_code": .number(0),
    ])

    /// The order a program's end comes in, since a cursor drops what is not newer.
    private static let eventOrder = ["lost", "restarted", "finished", "foreground", "removed"]

    private static func eventLine(
        _ type: String, data: JSONValue, terminal: String = "t1", sequence: Int? = nil
    ) throws -> Data {
        let sequence = sequence ?? 50 + (eventOrder.firstIndex(of: type) ?? 0)
        return try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(sequence)), "type": .string(type), "terminal": .string(terminal),
                    "data": data,
                ]),
            ]))
    }

    private static let lostEnd: JSONValue = .object([
        "reason": .string("signaled"), "signal": .number(9),
    ])

    private static let exitedEnd: JSONValue = .object([
        "reason": .string("exited"), "exit_code": .number(0),
    ])

    /// What the core sends a viewer when the program goes.
    private static func deliverClose(on attach: CoreAttach, end: JSONValue = lostEnd) async throws {
        try await attach.socket.deliver(
            HerdrCoreFrame(channel: attach.channel, kind: .close, payload: try JSONEncoder().encode(end)))
    }

    @Test func aLostProgramShowsRestartingAndTheNewShellComesBackWithNoOneAsking() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let sink = Sink()
        store.feed.attach(sink)
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("vim screen", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.count == 1)

        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["resumed"] == .bool(true))
        #expect(second.params["history"] == nil)
        #expect(store.status == .restarting)
        // The screen still shows the program that ended, so this key is not for the shell.
        store.send(Data("y".utf8))
        try await fixture.deliverOutput("new shell", on: second)
        try await Self.until("the new shell") { store.status == .live }
        #expect(String(data: sink.received, encoding: .utf8) == "vim screennew shell")

        // Typing reaches the shell that came back.
        store.send(Data("ls".utf8))
        try await Self.until("the typed bytes") {
            await second.socket.frames(channel: second.channel, kind: .data).reduce(Data()) { $0 + $1.payload }
                == Data("ls".utf8)
        }
        await store.stop()
        await fixture.finish()
    }

    /// Nothing orders the two channels on this side: the CLOSE can be read
    /// before the event the core sent ahead of it, and neither that wait nor
    /// the restart ever reads as an ended session.
    @Test func aCloseReadBeforeWordOfTheLossNeverReadsAsAnEnd() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await Self.deliverClose(on: first)
        try await Task.sleep(for: .milliseconds(200))
        if case .ended = store.status { Issue.record("read as ended before word of the loss") }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("restarting") { store.status == .restarting }
        await store.stop()
        await fixture.finish()
    }

    /// A slow reader can hear of the whole restart before its CLOSE: the new
    /// shell's process says this is another program.
    @Test func aCloseReadAfterTheRestartReattachesAtOnce() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        try await fixture.settle()
        try await Self.deliverClose(on: first)
        let second = try await fixture.opened(store, count: 2)
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func aFinishedProgramEndsForGoodWithNoReattach() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("finished", data: Self.exitedEnd))
        try await Self.deliverClose(on: first, end: Self.exitedEnd)
        try await Self.until("the end") { store.status == .finished }

        store.retry()
        try await fixture.settle()
        #expect(store.status == .finished)
        #expect(await fixture.scripted.attaches.count == 1)
        await store.stop()
        await fixture.finish()
    }

    @Test func openingATerminalBetweenProgramsWaitsForItsShell() async throws {
        let fixture = try await Fixture(terminals: [Self.restartingRecord])
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.isEmpty)

        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("shell", on: attach)
        try await Self.until("the shell") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func openingATerminalThatEndedAttachesToNothing() async throws {
        let fixture = try await Fixture(terminals: [Self.finishedRecord])
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("the end") { store.status == .finished }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.isEmpty)
        await store.stop()
        await fixture.finish()
    }

    /// A core refuses an attach between a program's loss and its new shell.
    /// Asked in that moment, before word of the loss, it is the same restart.
    @Test func anAttachRefusedForALostProgramWaitsForTheShell() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        await fixture.scripted.refuseNextAttach(kind: "unavailable")
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        await fixture.scripted.waitForMethod("terminal.attach", count: 2)
        let attach = try #require(await fixture.scripted.attaches.last)
        try await fixture.deliverOutput("shell", on: attach)
        try await Self.until("the shell") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func anAttachRefusedForAFinishedTerminalEndsIt() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        await fixture.scripted.refuseNextAttach(kind: "finished")
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("the end") { store.status == .finished }
        await store.stop()
        await fixture.finish()
    }

    /// Stop must not sit behind the wait for a shell that may never come.
    @Test func stoppingWhileRestartingLeavesAtOnce() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }
        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }

        await store.stop()
        #expect(store.status == .stopped)
        await fixture.finish()
    }

    /// A hidden retained terminal comes back too, and stays quiet.
    @Test func aHiddenAttachComesBackHiddenAfterARestart() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store(viewer: .resumed, isViewed: false)
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["resumed"] == .bool(true))
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        try await fixture.settle()
        #expect(await second.socket.frames(channel: second.channel, kind: .focus).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    // MARK: A detail over a kept restart

    private static let keptAgentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(true), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(7), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
        "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        "labels": .object([:]),
    ])

    private static let restoredShell = keptRecord(argv: "/bin/zsh", pid: 99)

    @Test func anAgentThatLeftItsShellRunningLeavesNoDetailBehind() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(8), "name": .string("zsh"), "argv": .array([.string("/bin/zsh")]),
                    "cwd": .string("/work/app"),
                ])))
        try await Self.until("no Agent") { fixture.console.agents.isEmpty }
        #expect(fixture.console.detailAgent(for: agent.id) == nil)
        await fixture.finish()
    }

    /// The same address can host an Agent again, and that one is on the list.
    @Test func anAgentStartedInTheRestoredShellIsListedAgain() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("no Agent") { fixture.console.agents.isEmpty }
        try await fixture.scripted.deliverEvent(Self.eventLine("restarted", data: Self.restoredShell))
        try await Self.until("the shell") {
            fixture.console.terminals.first?.isRestarting == false
        }
        #expect(fixture.console.departedAgents.map(\.id) == [agent.id])

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(120), "name": .string("claude"), "argv": .array([.string("claude")]),
                    "cwd": .string("/work/app"),
                ])))
        try await Self.until("the Agent") { !fixture.console.agents.isEmpty }
        #expect(fixture.console.departedAgents.isEmpty)
        await fixture.finish()
    }

    /// An Agent no lookup knows, listed only while it reports a status (#555).
    private static func genericAgentRecord(keep: Bool) -> JSONValue {
        .object([
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/bash")]), "keep": .bool(keep), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "foreground": .object([
                "pid": .number(4242), "name": .string("inert"), "argv": .array([.string("/work/app/inert")]),
                "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string("idle"), "app": .string("inert")]),
            "labels": .object([:]),
        ])
    }

    private static let clearedStatus: JSONValue = .object([
        "records": .object([:]), "reported": .bool(true), "status": .null,
    ])

    /// One whose shell took the Terminal back only left, so the shell's own end
    /// later brings nothing back.
    @Test func aGenericAgentThatLeftItsShellRunningLeavesNoDetailBehind() async throws {
        let fixture = try await Fixture(terminals: [Self.genericAgentRecord(keep: false)])
        let agent = try #require(fixture.console.agents.first)
        try await fixture.scripted.deliverEvent(Self.eventLine("status", data: Self.clearedStatus, sequence: 60))
        try await Self.until("no Agent") { fixture.console.agents.isEmpty }
        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(8), "name": .string("bash"), "argv": .array([.string("/bin/bash")]),
                    "cwd": .string("/work/app"),
                ]), sequence: 61))
        try await fixture.settle()
        try await fixture.scripted.deliverEvent(Self.eventLine("finished", data: Self.exitedEnd, sequence: 62))
        try await Self.until("the Terminal ends") { fixture.console.terminals.isEmpty }
        #expect(fixture.console.departedAgents.isEmpty)
        #expect(fixture.console.detailAgent(for: agent.id) == nil)
        await fixture.finish()
    }

    // MARK: Scrollback

    /// The core paints no history unless asked (`history` defaults to 0), and
    /// its own client asks only once: a surface that took output keeps its
    /// scrollback, so asking again would repeat every line.
    @Test func aFreshSurfaceAsksForScrollbackAndAReattachOntoOneThatHasItDoesNot() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        #expect(first.params["history"] == .number(10_000))
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["history"] == nil)
        await store.stop()
        await fixture.finish()
    }

    @Test func aReattachBeforeAnyOutputStillAsksForScrollback() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["history"] == .number(10_000))
        await store.stop()
        await fixture.finish()
    }

    @Test func aHiddenAttachAsksForScrollbackToo() async throws {
        let fixture = try await Fixture()
        let store = fixture.store(isViewed: false)
        let attach = try await fixture.opened(store)
        #expect(attach.params["history"] == .number(10_000))
        await store.stop()
        await fixture.finish()
    }

    /// A long main-screen session's first paint spans many frames and credit
    /// windows. Handed over frame by frame, the surface draws its history
    /// scrolling past for as long as the link takes to carry it; handed over
    /// whole, it opens on the latest screen. Output after the paint still
    /// flows as it comes.
    @Test func aFirstPaintSpanningManyFramesReachesTheSurfaceWhole() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let sink = TakeRecordingSink()
        store.feed.attach(sink)
        let attach = try await fixture.opened(store)
        let paint = Self.longFirstPaint(historyRows: 8_000)
        #expect(paint.count > 2 * HerdrCoreFrame.initialCredit)

        try await Self.deliverAsTheCoreDoes(paint, on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: paint.count)
        #expect(sink.takes.count == 1)
        #expect(sink.takes.first == paint)
        #expect(store.status == .live)

        try await fixture.deliverOutput("live", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: paint.count + 4)
        #expect(sink.takes.last == Data("live".utf8))
        await store.stop()
        await fixture.finish()
    }

    private static let paint = "\u{1B}[!p\u{1B}[H\u{1B}[2Jscreen\u{1B}[?9001l"
    /// Antigravity CLI's first answer to a resize: the screen erased down to
    /// its status line.
    private static let cleared = "\u{1B}[?2026h\r\u{1B}[20A\u{1B}[Jstatus\u{1B}[?2026l"
    private static let reprint = "\u{1B}[2J\u{1B}[3J\u{1B}[H\u{1B}[?2026hhistory\r\n\u{1B}[?2026l"

    /// The core sizes a Terminal to its viewer, and Antigravity CLI answers a
    /// resize by erasing the screen and then printing its whole history again.
    /// Where both hold, what follows the first paint waits for that reprint, so
    /// the surface keeps the paint until then. The view here is 80 columns.
    @Test(arguments: [("agy", 200, true), ("agy", 80, false), ("vim", 200, false)])
    func onlyAnAntigravityTerminalItsAttachResizesKeepsItsFirstPaintUntilTheReprintIsWhole(
        program: String, columns: Int, holds: Bool
    ) async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord(argv: program, columns: columns)])
        let store = fixture.store()
        let sink = TakeRecordingSink()
        store.feed.attach(sink)
        let attach = try await fixture.opened(store)
        let (paint, cleared, reprint) = (Self.paint, Self.cleared, Self.reprint)

        try await fixture.deliverOutput(paint, on: attach)
        try await fixture.deliverOutput(cleared, on: attach)
        // Held or taken, the frame's credit has gone back by now.
        await attach.socket.waitForCredit(channel: attach.channel, total: paint.utf8.count + cleared.utf8.count)
        #expect(sink.takes == (holds ? [paint] : [paint, cleared]).map { Data($0.utf8) })

        try await fixture.deliverOutput(reprint, on: attach)
        let all = paint + cleared + reprint
        await attach.socket.waitForCredit(channel: attach.channel, total: all.utf8.count)
        #expect(sink.takes.reduce(Data(), +) == Data(all.utf8))
        if holds { #expect(sink.takes.last == Data((cleared + reprint).utf8)) }
        await store.stop()
        await fixture.finish()
    }

    /// A viewer that leaves with its connection gives the Terminal its own
    /// size back, so the reattach resizes it again. It goes out while the new
    /// link's snapshot is still settling, with no Agent listed yet.
    @Test func aReattachToAnAntigravityTerminalKeepsItsFirstPaintUntilTheReprintIsWhole() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord(argv: "agy")])
        let store = fixture.store()
        let sink = TakeRecordingSink()
        store.feed.attach(sink)
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput(Self.paint, on: first)
        try await Self.until("the first output") { store.status == .live }

        await fixture.console.suspend()
        await fixture.scripted.setChannel(
            .core(
                .init(
                    id: "c1", terminals: [Self.keptRecord(argv: "agy", columns: 200)],
                    answersDocumentReads: false)))
        await fixture.console.resume()
        let second = try await fixture.opened(store, count: 2)
        #expect(fixture.console.hostsAwaitingSnapshot.contains(fixture.host.id))
        try await fixture.deliverOutput(Self.paint, on: second)
        try await fixture.deliverOutput(Self.cleared, on: second)
        let held = Self.paint.utf8.count + Self.cleared.utf8.count
        await second.socket.waitForCredit(channel: second.channel, total: held)
        #expect(sink.takes.last == Data(Self.paint.utf8))

        try await fixture.deliverOutput(Self.reprint, on: second)
        await second.socket.waitForCredit(channel: second.channel, total: held + Self.reprint.utf8.count)
        #expect(sink.takes.last == Data((Self.cleared + Self.reprint).utf8))
        await store.stop()
        await fixture.finish()
    }

    /// Each take apart, so a test can tell what a surface could draw between them.
    private final class TakeRecordingSink: TerminalByteSink {
        var takes: [Data] = []
        func receive(_ data: Data) { takes.append(data) }
    }

    /// Shaped like what herdr-core 0.1.18 sends a phone-sized viewer of a long
    /// main-screen session (`viewers.rs` `first_paint`, `ghostty-vt` `paint`):
    /// CAN, modes off, styled history rows, the newlines that push them into
    /// scrollback, the screen, then the win32 mode that closes the paint.
    private static func longFirstPaint(historyRows: Int, rows: Int = 40) -> Data {
        var paint = Data([0x18])
        paint.append(Data("\u{1B}[!p\u{1B}[?2026l\u{1B}[?1049l\u{1B}[?1047l\u{1B}[?47l\u{1B}[H\u{1B}[2J".utf8))
        for row in 0..<historyRows {
            paint.append(
                Data(
                    ("\u{1B}[38;2;\(row % 256);120;200mhistory row \(row)\u{1B}[0m "
                        + "\u{1B}[38;2;90;\(row % 256);40mof a long main-screen session\u{1B}[0m\r\n").utf8))
        }
        paint.append(Data("\u{1B}[0m\r\n".utf8))
        paint.append(Data(repeating: UInt8(ascii: "\n"), count: rows))
        paint.append(Data("\u{1B}[H\u{1B}[2J\u{1B}[0m> the latest screen\u{1B}[1;20H".utf8))
        paint.append(Data("\u{1B}[?9001l".utf8))
        return paint
    }

    /// DATA in frames the size a core's writer cuts them, never past the credit
    /// the client has granted.
    private static func deliverAsTheCoreDoes(
        _ bytes: Data, on attach: (channel: UInt32, params: JSONValue, socket: FakeCoreSocket),
        frameSize: Int = 16 * 1024
    ) async throws {
        var sent = 0
        while sent < bytes.count {
            let end = min(sent + frameSize, bytes.count)
            let owed = end - HerdrCoreFrame.initialCredit
            if owed > 0 { await attach.socket.waitForCredit(channel: attach.channel, total: owed) }
            let start = bytes.index(bytes.startIndex, offsetBy: sent)
            let stop = bytes.index(bytes.startIndex, offsetBy: end)
            try await attach.socket.deliver(
                HerdrCoreFrame(channel: attach.channel, kind: .data, payload: Data(bytes[start..<stop])))
            sent = end
        }
    }

    @Test func aLinkThatDropsReattachesOnTheNextOneAsAResumedViewerOnTheSameConnection() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.socket !== first.socket)
        #expect(second.params["resumed"] == .bool(true))
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        try await fixture.settle()
        #expect(await second.socket.frames(channel: second.channel, kind: .focus).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Another core at the same socket

    @Test func aReattachOntoAnotherCoreEndsTheTerminalWithNothingAttached() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("the old program", on: first)
        try await Self.until("the first output") { store.status == .live }

        // Another core, wiped or under another state directory, hands out t1 again.
        await fixture.scripted.setChannel(.core(.init(id: "c2", terminals: [Self.keptRecord()])))
        await first.socket.deliverEndOfFile()

        try await Self.until("the store sees the end") { store.status == .finished }
        #expect(await fixture.scripted.attaches.count == 1)
        await store.stop()
        await fixture.finish()
    }

    /// A replacement store for the same screen keeps what the first attach joined.
    @Test func aPipelinesLaterStoresStayOnTheCoreItFirstJoined() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let runner = fixture.runner
        let first = AttachTerminalStore(target: .terminal("t1"), runTerminal: runner)
        let attached = try await fixture.opened(first)
        try await fixture.deliverOutput("x", on: attached)
        try await Self.until("the first output") { first.status == .live }
        await first.stop()

        await fixture.scripted.setChannel(.core(.init(id: "c2", terminals: [Self.keptRecord()])))
        await attached.socket.deliverEndOfFile()
        try await Self.until("the new core's snapshot") { [console = fixture.console, host = fixture.host] in
            console.hostStatuses[host.id] == .connected
                && !console.hostsAwaitingSnapshot.contains(host.id)
        }
        await fixture.scripted.waitForMethod("events.subscribe", count: 2)

        let replacement = AttachTerminalStore(target: .terminal("t1"), runTerminal: runner)
        replacement.viewDidResize(cols: 80, rows: 24)
        try await Self.until("the replacement sees the end") { replacement.status == .finished }
        #expect(await fixture.scripted.attaches.count == 1)
        await replacement.stop()
        await fixture.finish()
    }

    /// Nobody holds it, so its address means whatever runs there now.
    @Test func anEndedAgentTerminalReopenedAtItsAddressGetsAFreshStore() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = fixture.console.agentTerminals
        let owner = UUID()
        let ended = cache.acquire(agent: agent, console: fixture.console, ownerID: owner)
        ended.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let first = try #require(await fixture.scripted.attaches.last)
        try await fixture.deliverOutput("agent screen", on: first)

        await fixture.scripted.setChannel(.core(.init(id: "c2", terminals: [Self.keptAgentRecord])))
        await first.socket.deliverEndOfFile()
        try await Self.until("the ended state") { ended.attach.terminalStatus == .finished }
        cache.release(ended, ownerID: owner)
        try await Self.until("the core's new Agent") { !fixture.console.agents.isEmpty }

        let newAgent = try #require(fixture.console.agents.first)
        let reopened = cache.acquire(agent: newAgent, console: fixture.console, ownerID: UUID())
        #expect(reopened !== ended)
        reopened.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach", count: 2)
        let second = try #require(await fixture.scripted.attaches.last)
        #expect(second.socket !== first.socket)
        await fixture.finish()
    }

    @Test func anEndedShellTerminalReopenedAtItsAddressGetsAFreshStore() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let identity = ShellTerminalIdentity(
            paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID)
        let pool = fixture.console.terminalConnections
        let owner = UUID()
        let ended = try await pool.select(
            hostID: fixture.host.id, identity: identity, ownerID: owner, generation: nil,
            runTerminal: fixture.runner)
        ended.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let first = try #require(await fixture.scripted.attaches.last)
        try await fixture.deliverOutput("x", on: first)

        await fixture.scripted.setChannel(.core(.init(id: "c2", terminals: [Self.shellRecord])))
        await first.socket.deliverEndOfFile()
        try await Self.until("the ended state") { ended.store.terminalStatus == .finished }
        pool.release(hostID: fixture.host.id, identity: identity, ownerID: owner)
        await fixture.scripted.waitForMethod("events.subscribe", count: 2)
        try await Self.until("the new core's snapshot") { [console = fixture.console, host = fixture.host] in
            console.hostStatuses[host.id] == .connected
                && !console.hostsAwaitingSnapshot.contains(host.id)
        }

        let returning = UUID()
        #expect(pool.reclaim(hostID: fixture.host.id, identity: identity, ownerID: returning, generation: nil) == nil)
        let reopened = try await pool.select(
            hostID: fixture.host.id, identity: identity, ownerID: returning, generation: nil,
            runTerminal: fixture.runner)
        #expect(reopened !== ended)
        reopened.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach", count: 2)
        let second = try #require(await fixture.scripted.attaches.last)
        #expect(second.socket !== first.socket)
        await fixture.finish()
    }

    // MARK: A detail and the core it opened on, through the real Console

    /// As on a Herdr TUI Host: the detail stays up, input waits with nothing sent,
    /// and a fresh snapshot decides whether the Agent is still there.
    @Test func anAgentDetailStaysThroughRecoveryUntilAFreshSnapshotSays() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        let hostID = fixture.host.id
        #expect(fixture.console.isHostReadyForInput(hostID))

        await fixture.console.suspend()
        try await Self.until("suspended") { fixture.console.hostStatuses[hostID] == .suspended }
        #expect(fixture.console.agents.isEmpty)
        #expect(fixture.console.detailAgent(for: agent.id) == agent)
        #expect(!fixture.console.isHostReadyForInput(hostID))
        await #expect(throws: HerdrCoreChatTyping.Refusal.self) {
            try await fixture.console.sendAgentKeys(["Enter"], to: agent.agent.paneID, on: hostID)
        }

        await fixture.scripted.setChannel(.core(.init(id: "c1", terminals: [])))
        await fixture.console.resume()
        try await Self.until("the fresh snapshot") {
            fixture.console.hostStatuses[hostID] == .connected
                && !fixture.console.hostsAwaitingSnapshot.contains(hostID)
        }
        #expect(fixture.console.detailAgent(for: agent.id) == nil)
        #expect(fixture.console.isHostReadyForInput(hostID))
        await fixture.finish()
    }

    /// A new screen in the window takes what its predecessor left, but not another
    /// core's pipeline; another window's stays with that window.
    @Test func aPipelineOnAnotherCoreMakesWayInItsOwnWindowOnly() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let identity = ShellTerminalIdentity(
            paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID)
        let pool = fixture.console.terminalConnections
        let hostID = fixture.host.id
        let window = UUID()
        let old = TerminalCorePin(joined: "c1")
        let new = TerminalCorePin(joined: "c2")
        let held = try await pool.select(
            hostID: hostID, identity: identity, ownerID: UUID(), sceneID: window, generation: nil,
            corePin: old, runTerminal: fixture.runner)

        let sameCore = pool.reclaim(
            hostID: hostID, identity: identity, ownerID: UUID(), sceneID: window, generation: nil,
            corePin: TerminalCorePin(joined: "c1"))
        #expect(sameCore === held)
        #expect(
            pool.reclaim(
                hostID: hostID, identity: identity, ownerID: UUID(), sceneID: window, generation: nil,
                corePin: new) == nil)
        await #expect(throws: TerminalConnectionPool.Failure.alreadyVisible) {
            _ = try await pool.select(
                hostID: hostID, identity: identity, ownerID: UUID(), sceneID: UUID(), generation: nil,
                corePin: new, runTerminal: fixture.runner)
        }
        #expect(pool.entries[.init(hostID: hostID, identity: identity)] === held)

        let replaced = try await pool.select(
            hostID: hostID, identity: identity, ownerID: UUID(), sceneID: window, generation: nil,
            corePin: new, runTerminal: fixture.runner)
        #expect(replaced !== held)
        await fixture.finish()
    }

    // MARK: Modes

    /// What herdr-core 0.1.13 sends a fresh viewer (`ghostty-vt` `paint`): every
    /// mode off, then the program's own on again, then the win32 mode that
    /// closes every paint.
    private static let firstPaint = Data(
        ("\u{1B}[!p\u{1B}[?2026l\u{1B}[?9l\u{1B}[?1000l\u{1B}[?1001l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l"
            + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l\u{1B}[?2004l\u{1B}[?1l\u{1B}[?66l\u{1B}[?2031l"
            + "\u{1B}[?2048l\u{1B}[=0;1u\u{1B}[?1049l\u{1B}[?1047l\u{1B}[?47l\u{1B}[H\u{1B}[2J"
            + "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[=5;1uscreen\u{1B}[?9001l").utf8)

    @Test func theFirstPaintLeavesTheModesTheProgramLastSetAndARemountKeepsThem() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        let first = Sink()
        store.feed.attach(first)
        try await attach.socket.deliver(
            HerdrCoreFrame(channel: attach.channel, kind: .data, payload: Self.firstPaint))
        await attach.socket.waitForCredit(channel: attach.channel, total: Self.firstPaint.count)
        #expect(store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        #expect(store.modes.isAlternateScreen)

        let remounted = Sink()
        store.feed.attach(remounted)
        #expect(store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        try await fixture.deliverOutput("\u{1B}[?2004l", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: Self.firstPaint.count + 8)
        #expect(remounted.received == Data("\u{1B}[?2004l".utf8))
        #expect(!store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Retention

    private static func identity(_ number: Int) -> ShellTerminalIdentity {
        ShellTerminalIdentity(paneID: "t\(number)", tabID: "tab\(number)", terminalID: "t\(number)")
    }

    private func open(
        _ number: Int, in fixture: Fixture, ownerID: UUID, count: Int
    ) async throws -> (entry: TerminalConnectionPool.Entry, attach: (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)) {
        let entry = try await fixture.console.terminalConnections.select(
            hostID: fixture.host.id, identity: Self.identity(number), ownerID: ownerID, generation: nil,
            runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach", count: count)
        let attach = try #require(await fixture.scripted.attaches.last)
        #expect(attach.params["terminal"] == .string("t\(number)"))
        return (entry, attach)
    }

    @Test func fiveTerminalsStayOnOneLinkAndTheLeastRecentlyViewedMakesRoomForASixth() async throws {
        let fixture = try await Fixture()
        let pool = fixture.console.terminalConnections
        var opened: [(channel: UInt32, params: JSONValue, socket: FakeCoreSocket)] = []
        for number in 1...5 {
            let owner = UUID()
            let (_, attach) = try await open(number, in: fixture, ownerID: owner, count: number)
            opened.append(attach)
            pool.release(hostID: fixture.host.id, identity: Self.identity(number), ownerID: owner)
        }
        #expect(pool.entries.count == 5)
        let socket = try #require(await fixture.scripted.socket)
        #expect(opened.allSatisfy { $0.socket === socket })
        for attach in opened {
            #expect(await socket.frames(channel: attach.channel, kind: .close).isEmpty)
        }

        // Coming back to the first makes the second the least recently viewed.
        let returning = UUID()
        _ = try #require(
            pool.reclaim(
                hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning, generation: nil))
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning)

        _ = try await open(6, in: fixture, ownerID: UUID(), count: 6)
        _ = await socket.waitForFrame(channel: opened[1].channel, kind: .close)
        #expect(await socket.frames(channel: opened[0].channel, kind: .close).isEmpty)
        #expect(await socket.frames(channel: opened[2].channel, kind: .close).isEmpty)
        #expect(pool.entries.count == 5)

        #expect(await fixture.scripted.log.filter { $0.hasPrefix("open ") }.count == 1)
        #expect(await fixture.scripted.sockets.count == 1)
        await fixture.finish()
    }

    @Test func aHiddenRetainedTerminalReportsNothingAndComesBackWithFocus() async throws {
        let fixture = try await Fixture()
        let pool = fixture.console.terminalConnections
        let owner = UUID()
        let (entry, attach) = try await open(1, in: fixture, ownerID: owner, count: 1)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { entry.store.terminalStatus == .live }
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        let hidden = await attach.socket.frames(channel: attach.channel, kind: .focus).count
        entry.store.terminalFeed.updateDisplayFacts { $0 = Self.facts }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).count == hidden)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).isEmpty)

        let returning = UUID()
        _ = try #require(
            pool.reclaim(
                hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning, generation: nil))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([1]))
        await fixture.finish()
    }

    @Test func aRetainedTerminalWhoseFiveMinutesAreOverClosesItsChannel() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(idleTimeout: .milliseconds(20))
        let owner = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner, generation: nil,
            runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(pool.entries.isEmpty)
        await fixture.finish()
    }

    @Test func anAgentIsHeldWhileItsDetailLivesAndFreeOnceItIsGone() async throws {
        final class Detail {}
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = fixture.console.agentTerminals
        let first = UUID()
        var detail: Detail? = Detail()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: first, holder: detail)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: first))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        cache.release(entry, ownerID: first)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: first))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        detail = nil
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        await fixture.finish()
    }

    /// The replaced detail's late release finds nothing to undo, and the
    /// timer runs from the release of the detail that took over.
    @Test func aDetailInTheOwnersWindowTakesTheEntryAndAnotherWindowDoesNot() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let replaced = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: replaced, sceneID: scene)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        let replacement = UUID()
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: replacement))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: replacement, sceneID: UUID()))
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: replacement, sceneID: scene))

        let taken = cache.acquire(agent: agent, console: fixture.console, ownerID: replacement, sceneID: scene)
        #expect(taken === entry)
        cache.release(entry, ownerID: replaced)
        try await Task.sleep(for: .milliseconds(100))
        #expect(entry.isRetained)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        cache.release(entry, ownerID: replacement)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(cache.entries.isEmpty)
        await fixture.finish()
    }

    /// A Herdr TUI detail passes no window, so its replacement closes the
    /// entry and attaches anew, as it always has.
    @Test func aDetailWithNoWindowClosesTheEntryItReplaces() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .seconds(300))
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID())
        let replacement = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID())
        #expect(replacement !== entry)
        #expect(!entry.isRetained)
        await cache.suspend()
        await fixture.finish()
    }

    @Test func aWindowThatEndsStartsTheRetentionOfWhatItShows() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID(), sceneID: scene)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        cache.sceneDidEnd(UUID())
        try await Task.sleep(for: .milliseconds(100))
        #expect(entry.isRetained)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        cache.sceneDidEnd(scene)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(cache.entries.isEmpty)
        await fixture.finish()
    }

    /// Going under Changes starts the five minutes; the window closing later
    /// must not start them again.
    @Test func aWindowThatEndsLeavesARunningTimerAlone() async throws {
        final class Detail {}
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .seconds(1))
        let owner = UUID()
        let scene = UUID()
        let detail = Detail()
        let entry = cache.acquire(
            agent: agent, console: fixture.console, ownerID: owner, sceneID: scene, holder: detail)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        let released = ContinuousClock.now
        cache.release(entry, ownerID: owner)
        try await Task.sleep(for: .milliseconds(900))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        cache.sceneDidEnd(scene)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(ContinuousClock.now - released < .milliseconds(1800))
        withExtendedLifetime(detail) {}
        await fixture.finish()
    }

    @Test func theFiveDefaultMinutesAreWhatTheConsoleRetainsFor() async throws {
        let fixture = try await Fixture()
        #expect(fixture.console.terminalConnections.idleTimeout == .seconds(300))
        #expect(fixture.console.agentTerminals.idleTimeout == .seconds(300))
        await fixture.finish()
    }

    private static let agentRecord = agentRecord(address: "t1")

    private static func agentRecord(address: String) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string("working"), "app": .string("claude-code")]),
            "labels": .object([:]),
        ])
    }

    @Test func aRetainedAgentGoesQuietWhenHiddenAndClosesItsChannelWhenEvicted() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = fixture.console.agentTerminals
        let owner = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: owner)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        #expect(attach.params["terminal"] == .string("t1"))
        #expect(attach.params["takeover"] == nil)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { entry.attach.terminalStatus == .live }

        cache.release(entry, ownerID: owner)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        await cache.suspend()
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(await fixture.scripted.log.filter { $0.hasPrefix("open ") }.count == 1)
        await fixture.finish()
    }

    private typealias CoreAttach = (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)

    // MARK: Shell Terminal windows

    private static func shellRecord(address: String) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
        ])
    }

    private static let shellRecord = shellRecord(address: "t1")

    @Test func aWindowThatEndsStartsTheFiveMinutesOfTheShellItShows() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: scene,
            generation: nil, runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        pool.sceneDidEnd(UUID()) { _ in true }
        pool.sceneDidEnd(scene) { _ in false }
        try await Task.sleep(for: .milliseconds(100))
        #expect(pool.entries.count == 1)

        pool.sceneDidEnd(scene) { $0 == fixture.host.id }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(pool.entries.isEmpty)
        await fixture.finish()
    }

    /// Eviction skips what a window shows, so a closed window's Shell would
    /// hold its slot for as long as the app runs.
    @Test func aWindowThatEndsGivesUpTheSlotOfTheShellItShows() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(maximumShellsPerHost: 1)
        let scene = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: scene,
            generation: nil, runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        await #expect(throws: TerminalConnectionPool.Failure.self) {
            try await pool.select(
                hostID: fixture.host.id, identity: Self.identity(2), ownerID: UUID(), sceneID: UUID(),
                generation: nil, runTerminal: fixture.runner)
        }

        pool.sceneDidEnd(scene) { _ in true }
        _ = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(2), ownerID: UUID(), sceneID: UUID(),
            generation: nil, runTerminal: fixture.runner)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        await pool.suspend()
        await fixture.finish()
    }

    /// A window SwiftUI brought back is a window again.
    @Test func aWindowThatComesBackHasNotEnded() async throws {
        let fixture = try await Fixture()
        let scene = UUID()
        #expect(!fixture.console.hasSceneEnded(nil, on: fixture.host.id))
        #expect(!fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        fixture.console.sceneDidEnd(scene)
        #expect(fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        fixture.console.sceneDidStart(scene)
        #expect(!fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        await fixture.finish()
    }

    /// One Shell channel at a time still holds on Herdr TUI: a window's end
    /// changes nothing there.
    @Test func aHerdrTUIWindowThatEndsLeavesItsShellAsItWas() async throws {
        let console = ConsoleStore(makeSession: { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "unused") },
                keepalive: nil)
        })
        let host = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        console.setHosts([host])
        let pool = console.terminalConnections
        let scene = UUID()
        let owner = UUID()
        _ = try await pool.select(
            hostID: host.id, identity: Self.identity(1), ownerID: owner, sceneID: scene,
            generation: nil, runTerminal: { _, _ in })

        console.sceneDidEnd(scene)

        #expect(!console.hasSceneEnded(scene, on: host.id))
        await #expect(throws: TerminalConnectionPool.Failure.self) {
            try await pool.select(
                hostID: host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: UUID(),
                generation: nil, runTerminal: { _, _ in })
        }
        await pool.suspend()
        console.setHosts([])
    }
}
