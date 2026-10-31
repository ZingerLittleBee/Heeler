import Foundation
import Testing

@testable import Heeler

/// Done per device on a core Host (ADR 0033), through `ConsoleStore` over the
/// scripted core transport: what the Agents list reads as a real event log arrives.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreDoneTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
    private let viewer = UUID()
    private let window = UUID()

    private static func report(_ state: String, app: String) -> JSONValue {
        .object(["state": .string(state), "app": .string(app)])
    }

    private static func record(
        _ address: String, program: String, app: String, state: String?, turn: Int = 0,
        reported: Bool = true
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7), "name": .null, "reason": .null,
            "labels": .object([:]), "turn": .number(Double(turn)), "reported": .bool(reported),
            "foreground": .object([
                "pid": .number(40), "name": .string(program), "argv": .array([.string(program)]),
                "cwd": .string("/work/app"),
            ]),
            "status": state.map { report($0, app: app) } ?? .null,
        ])
    }

    private static func claude(_ address: String, state: String?, turn: Int = 0) -> JSONValue {
        record(address, program: "claude", app: "claude-code", state: state, turn: turn)
    }

    private static func subscribeResult(_ terminals: [JSONValue]) -> JSONValue {
        .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
    }

    /// The core's global event number, which only goes up.
    private final class Sequence {
        var last = 1
    }

    private let sequence = Sequence()

    private func event(_ type: String, _ terminal: String, _ data: JSONValue) -> Data {
        sequence.last += 1
        return (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence.last)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private func status(_ terminal: String, _ state: String?, app: String = "claude-code") -> Data {
        event(
            "status", terminal,
            .object([
                "status": state.map { Self.report($0, app: app) } ?? .null, "records": .object([:]),
                "reported": .bool(true),
            ]))
    }

    private func turn(_ terminal: String, _ turn: Int, state: String?) -> Data {
        event(
            "turn", terminal,
            .object(["turn": .number(Double(turn)), "state": state.map(JSONValue.string) ?? .null]))
    }

    private func title(_ terminal: String, _ title: String) -> Data {
        event("title", terminal, .object(["title": .string(title)]))
    }

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "core-done-\(UUID().uuidString)"))
    }

    private func store(
        _ transport: ScriptedCoreTransport, memory: HerdrCoreHostMemory = HerdrCoreHostMemory()
    ) async throws -> ConsoleStore {
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreHostMemory: memory)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return store
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func status(_ store: ConsoleStore, _ address: String) -> AgentStatus? {
        store.agents.first { $0.agent.paneID == address }?.agent.status
    }

    private func id(_ address: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host.id, paneID: address)
    }

    /// A turn as a core sends it: the status event, then the moved count.
    private func deliverEnd(
        _ transport: ScriptedCoreTransport, _ address: String, word: String = "done", turn: Int,
        app: String = "claude-code"
    ) async {
        await transport.deliver(status(address, word, app: app))
        await transport.deliver(self.turn(address, turn, state: word))
    }

    /// Everything before this event has been folded once its title shows.
    private func settle(
        _ transport: ScriptedCoreTransport, _ store: ConsoleStore, _ address: String
    ) async throws {
        let mark = UUID().uuidString
        await transport.deliver(title(address, mark))
        try await waitUntil("the log to arrive") {
            store.agents.first { $0.agent.paneID == address }?.agent.terminalTitle == mark
        }
    }

    // MARK: A turn this device was not showing

    @Test func doneAppearsForATurnThatEndedUnshownAndLeavesWhenTheAgentWorksAgain() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        #expect(status(store, "t1") == .working)

        await deliverEnd(transport, "t1", turn: 1)
        try await waitUntil("Done") { status(store, "t1") == .done }
        try await settle(transport, store, "t1")
        #expect(status(store, "t1") == .done)

        await transport.deliver(status("t1", "working"))
        try await waitUntil("working again") { status(store, "t1") == .working }
    }

    @Test func aMoveToIdleStaysDoneWhileAnUnseenTurnIsNotYetTakenBack() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", program: "codex", app: "codex", state: "working")
            ])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }

        await deliverEnd(transport, "t1", turn: 1, app: "codex")
        try await waitUntil("Done") { status(store, "t1") == .done }
        await transport.deliver(status("t1", "idle", app: "codex"))
        try await settle(transport, store, "t1")
        #expect(status(store, "t1") == .done)
    }

    @Test func workingToIdleEndsATurnOnlyForAProgramNotKnownToReportDone() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", program: "opencode", app: "opencode", state: "working"),
                Self.record("t2", program: "codex", app: "codex", state: "working"),
            ])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }

        await deliverEnd(transport, "t1", word: "idle", turn: 1, app: "opencode")
        await deliverEnd(transport, "t2", word: "idle", turn: 1, app: "codex")
        try await waitUntil("OpenCode's Done") { status(store, "t1") == .done }
        try await settle(transport, store, "t2")
        #expect(status(store, "t2") == .idle)
    }

    @Test func enteringBlockedShowsNoDoneAndABlockedTurnEndsAtItsDoneWithNoTurnEvent() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }

        await deliverEnd(transport, "t1", word: "blocked", turn: 1)
        try await waitUntil("Blocked") { status(store, "t1") == .blocked }
        await transport.deliver(status("t1", "done"))
        try await waitUntil("Done") { status(store, "t1") == .done }
    }

    @Test func aFinishedTurnSeenInASnapshotReadsDoneAndNotADoneWithoutATurn() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.claude("t1", state: "done", turn: 2), Self.claude("t2", state: "idle", turn: 2),
                Self.record("t3", program: "opencode", app: "opencode", state: "idle", turn: 2),
                Self.record("t4", program: "opencode", app: "opencode", state: "idle", turn: 0),
            ])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }

        #expect(status(store, "t1") == .done)
        #expect(status(store, "t2") == .idle)
        #expect(status(store, "t3") == .done)
        #expect(status(store, "t4") == .idle)
    }

    @Test func aReportFromAProgramThatLeftIsNoDoneForTheOneThatFollows() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        await deliverEnd(transport, "t1", turn: 1)
        try await waitUntil("Done") { status(store, "t1") == .done }

        let shell = JSONValue.object([
            "pid": .number(50), "name": .string("zsh"), "argv": .array([.string("zsh")]),
            "cwd": .string("/work/app"),
        ])
        await transport.deliver(event("foreground", "t1", shell))
        try await waitUntil("the Agent to end") { status(store, "t1") == nil }

        let claude = JSONValue.object([
            "pid": .number(51), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ])
        await transport.deliver(event("foreground", "t1", claude))
        try await waitUntil("another Agent") { status(store, "t1") != nil }
        #expect(status(store, "t1") == .idle)
    }

    // MARK: This device, and the next

    @Test func openingTheAgentClearsDoneOnThisDeviceAndASecondDeviceStillShowsIt() async throws {
        let log = Self.subscribeResult([Self.claude("t1", state: "working")])
        let here = ScriptedCoreTransport(subscribeResults: [log])
        let there = ScriptedCoreTransport(subscribeResults: [log])
        let thisDevice = try await store(here, memory: HerdrCoreHostMemory(defaults: try suite()))
        let otherDevice = try await store(there, memory: HerdrCoreHostMemory(defaults: try suite()))
        defer {
            thisDevice.setHosts([])
            otherDevice.setHosts([])
        }

        await deliverEnd(here, "t1", turn: 1)
        await deliverEnd(there, "t1", turn: 1)
        try await waitUntil("Done on this device") { status(thisDevice, "t1") == .done }
        try await waitUntil("Done on the other") { status(otherDevice, "t1") == .done }

        thisDevice.setAgentShown(id("t1"), viewer: viewer, scene: window)
        #expect(status(thisDevice, "t1") == .idle)
        thisDevice.setAgentShown(nil, viewer: viewer, scene: window)
        #expect(status(thisDevice, "t1") == .idle)

        try await settle(there, otherDevice, "t1")
        #expect(status(otherDevice, "t1") == .done)
    }

    @Test func anAgentOpenAsItsTurnEndsNeverShowsDoneForThatTurn() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)

        // Looked at between the status event and the count it moved, too.
        await transport.deliver(status("t1", "done"))
        try await waitUntil("the turn to end") { status(store, "t1") != .working }
        #expect(status(store, "t1") == .idle)
        await transport.deliver(turn("t1", 1, state: "done"))
        try await settle(transport, store, "t1")
        #expect(status(store, "t1") == .idle)

        // Leaving does not bring it back, and the next turn is not shown.
        store.setAgentShown(nil, viewer: viewer, scene: window)
        #expect(status(store, "t1") == .idle)
        await transport.deliver(status("t1", "working"))
        await deliverEnd(transport, "t1", turn: 2)
        try await waitUntil("the next turn's Done") { status(store, "t1") == .done }
    }

    @Test func anAgentOpenedWhileItWorksStillShowsDoneIfLeftBeforeItsTurnEnds() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }

        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        store.setAgentShown(nil, viewer: viewer, scene: window)
        await deliverEnd(transport, "t1", turn: 1)
        try await waitUntil("Done") { status(store, "t1") == .done }
    }

    @Test func anotherWindowStillShowingTheAgentKeepsItsTurnSeen() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        let otherWindow = UUID()

        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        store.setAgentShown(id("t1"), viewer: UUID(), scene: otherWindow)
        store.setAgentShown(nil, viewer: viewer, scene: window)
        await deliverEnd(transport, "t1", turn: 1)
        try await settle(transport, store, "t1")
        #expect(status(store, "t1") == .idle)
    }

    @Test func aClosedWindowNoLongerShowsItsAgent() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")])
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)

        store.sceneDidEnd(window)
        // A late update from the screen of a window that already ended.
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        await deliverEnd(transport, "t1", turn: 1)
        try await waitUntil("Done") { status(store, "t1") == .done }
    }

    @Test func anAgentOpenThroughAReconnectHasSeenTheTurnThatEndedMeanwhile() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "working")]),
            Self.subscribeResult([Self.claude("t1", state: "done", turn: 1)]),
        ])
        let store = try await store(transport)
        defer { store.setHosts([]) }
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)

        await store.suspend()
        await store.resume()
        try await waitUntil("the next snapshot") { status(store, "t1") != nil && status(store, "t1") != .working }
        #expect(status(store, "t1") == .idle)
    }

    // MARK: Host memory

    @Test func seenMarksSurviveARelaunchAndAnUnseenTurnStaysDone() async throws {
        let defaults = try suite()
        let first = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([
                Self.claude("t1", state: "working"),
                Self.record("t2", program: "opencode", app: "opencode", state: "working"),
            ])
        ])
        let store = try await store(first, memory: HerdrCoreHostMemory(defaults: defaults))
        await deliverEnd(first, "t1", turn: 1)
        await deliverEnd(first, "t2", word: "idle", turn: 1, app: "opencode")
        try await waitUntil("Done") { status(store, "t1") == .done && status(store, "t2") == .done }
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        await store.suspend()

        // A new process, with both Terminals where they were.
        let second = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([
                Self.claude("t1", state: "done", turn: 1),
                Self.record("t2", program: "opencode", app: "opencode", state: "idle", turn: 1),
            ])
        ])
        let relaunched = try await self.store(second, memory: HerdrCoreHostMemory(defaults: defaults))
        defer { relaunched.setHosts([]) }
        #expect(status(relaunched, "t1") == .idle)
        #expect(status(relaunched, "t2") == .done)
    }

    @Test func removingTheHostClearsItsSeenMarks() async throws {
        let defaults = try suite()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "done", turn: 1)])
        ])
        let store = try await store(transport, memory: HerdrCoreHostMemory(defaults: defaults))
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        #expect(status(store, "t1") == .idle)

        store.setHosts([])

        let memory = HerdrCoreHostMemory(defaults: defaults)
        #expect(memory.turnStates(for: host.id).isEmpty)
    }

    @Test func anotherCoreIDClearsTheOldCoresSeenMarks() async throws {
        let defaults = try suite()
        let first = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "done", turn: 1)])
        ])
        let store = try await store(first, memory: HerdrCoreHostMemory(defaults: defaults))
        store.setAgentShown(id("t1"), viewer: viewer, scene: window)
        #expect(status(store, "t1") == .idle)
        store.setAgentShown(nil, viewer: viewer, scene: window)
        await store.suspend()

        // The same address and count, on a core that never saw this device.
        let second = ScriptedCoreTransport(coreID: "c2", subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "done", turn: 1)])
        ])
        let replaced = try await self.store(second, memory: HerdrCoreHostMemory(defaults: defaults))
        defer { replaced.setHosts([]) }
        #expect(status(replaced, "t1") == .done)
    }

    @Test func aRemovedTerminalTakesItsSeenMark() async throws {
        let memory = HerdrCoreHostMemory(defaults: try suite())
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.claude("t1", state: "done", turn: 1)])
        ])
        let store = try await store(transport, memory: memory)
        defer { store.setHosts([]) }
        #expect(memory.turnStates(for: host.id)["t1"] != nil)

        await transport.deliver(event("removed", "t1", .object([:])))
        try await waitUntil("the Agent to go") { status(store, "t1") == nil }
        #expect(memory.turnStates(for: host.id)["t1"] == nil)
    }

    @Test func memoryFromBeforeSeenMarksStillReads() throws {
        let defaults = try suite()
        let hostID = host.id
        // A dictionary keyed by UUID encodes as a list of keys and values.
        let older = #"["\#(hostID.uuidString)",{"coreID":"c1","directories":{"t1":"/work/app"}}]"#
        defaults.set(Data(older.utf8), forKey: "herdr-core.host-memory")

        let memory = HerdrCoreHostMemory(defaults: defaults)
        #expect(memory.coreID(for: hostID) == "c1")
        #expect(memory.firstSeenDirectories(for: hostID) == ["t1": "/work/app"])
        #expect(memory.turnStates(for: hostID).isEmpty)
    }
}
