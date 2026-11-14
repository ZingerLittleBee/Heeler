import Foundation
import Testing

@testable import Heeler

/// Agent Status and Done per device on a tmux Host (ADR 0046), through
/// `ConsoleStore` and the real tmux transport over a scripted Host: what the
/// Agents list reads as a Pane's `@heeler-status` changes between looks.
@MainActor
@Suite("tmux Agent Status and Done", .timeLimit(.minutes(1)))
struct TmuxDoneTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
    private let viewer = UUID()
    private let window = UUID()

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "tmux-done-\(UUID().uuidString)"))
    }

    private func store(
        _ tmux: ScriptedTmuxHost, memory: HerdrCoreHostMemory = HerdrCoreHostMemory()
    ) async throws -> ConsoleStore {
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            },
            coreHostMemory: memory)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first inventory") { store.hostsAwaitingSnapshot.isEmpty }
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

    private func status(_ store: ConsoleStore, _ pane: String) -> AgentStatus? {
        store.agents.first { $0.agent.paneID == pane }?.agent.status
    }

    private func id(_ pane: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host.id, paneID: pane)
    }

    private nonisolated static func claude(
        pane: Int = 0, window: Int = 0, _ status: String
    ) -> TmuxInventory.Pane {
        .make(
            window: window, windowIndex: window, pane: pane, command: "claude", status: status,
            arguments: ["claude"])
    }

    /// The Pane `%<pane>` reports `status` from the next look on, which has
    /// been folded once its window's new name shows.
    private func report(
        _ tmux: ScriptedTmuxHost, pane: Int = 0, _ status: String, until store: ConsoleStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let mark = UUID().uuidString
        await tmux.changePanes { panes in
            guard let index = panes.firstIndex(where: { $0.paneID == "%\(pane)" }) else { return }
            panes[index].status = status
            panes[index].windowName = mark
        }
        try await waitUntil(
            "the report", { store.terminals.first { $0.paneID == "%\(pane)" }?.tabLabel == mark },
            sourceLocation: sourceLocation)
    }

    // MARK: Agent Status

    @Test func anAgentReadsItsStatusFromTheOption() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            Self.claude("state=idle:app=claude-code:turn=0:blocked=0"),
            .make(window: 1, windowIndex: 1, pane: 1, command: "codex",
                  status: "state=working:app=codex:turn=0:blocked=0", arguments: ["codex"]),
            .make(window: 2, windowIndex: 2, pane: 2, command: "pi",
                  status: "state=blocked:app=pi:kind=auth:turn=0:blocked=1", arguments: ["pi"]),
            .make(window: 3, windowIndex: 3, pane: 3, command: "omp",
                  status: "state=error:app=omp:msg=ZmFpbGVk:turn=0:blocked=0", arguments: ["omp"]),
            // Never reported, cleared, and another program's report.
            .make(window: 4, windowIndex: 4, pane: 4, command: "opencode", arguments: ["opencode"]),
            .make(window: 5, windowIndex: 5, pane: 5, command: "claude", status: "turn=0:blocked=0",
                  arguments: ["claude"]),
            .make(window: 6, windowIndex: 6, pane: 6, command: "claude",
                  status: "state=working:app=pi:turn=0:blocked=0", arguments: ["claude"]),
        ])
        let store = try await store(tmux)
        defer { store.setHosts([]) }

        #expect(status(store, "%0") == .idle)
        #expect(status(store, "%1") == .working)
        #expect(status(store, "%2") == .blocked)
        #expect(status(store, "%3") == .error)
        #expect(status(store, "%4") == .unknown)
        #expect(status(store, "%5") == .unknown)
        #expect(status(store, "%6") == .unknown)

        try await report(tmux, pane: 1, "state=blocked:app=codex:kind=permission:turn=0:blocked=1", until: store)
        #expect(status(store, "%1") == .blocked)
    }

    // MARK: Done on this device

    @Test func doneShowsForATurnThatEndedUnshownAndLeavesWhenTheAgentWorksAgain() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([Self.claude("state=working:app=claude-code:turn=0:blocked=0")])
        let store = try await store(tmux)
        defer { store.setHosts([]) }
        #expect(status(store, "%0") == .working)

        try await report(tmux, "state=done:app=claude-code:turn=1:blocked=0", until: store)
        #expect(status(store, "%0") == .done)
        // Claude Code's idle after a turn keeps it.
        try await report(tmux, "state=idle:app=claude-code:turn=1:blocked=0", until: store)
        #expect(status(store, "%0") == .done)

        try await report(tmux, "state=working:app=claude-code:turn=1:blocked=0", until: store)
        #expect(status(store, "%0") == .working)
    }

    @Test func openingTheAgentClearsDoneOnThisDeviceAndASecondDeviceStillShowsIt() async throws {
        let here = ScriptedTmuxHost()
        let there = ScriptedTmuxHost()
        for tmux in [here, there] {
            await tmux.setPanes([Self.claude("state=done:app=claude-code:turn=1:blocked=0")])
        }
        let thisDevice = try await store(here, memory: HerdrCoreHostMemory(defaults: try suite()))
        let otherDevice = try await store(there, memory: HerdrCoreHostMemory(defaults: try suite()))
        defer {
            thisDevice.setHosts([])
            otherDevice.setHosts([])
        }
        #expect(status(thisDevice, "%0") == .done)
        #expect(status(otherDevice, "%0") == .done)

        thisDevice.setAgentShown(id("%0"), viewer: viewer, scene: window)
        #expect(status(thisDevice, "%0") == .idle)
        thisDevice.setAgentShown(nil, viewer: viewer, scene: window)
        #expect(status(thisDevice, "%0") == .idle)
        #expect(status(otherDevice, "%0") == .done)

        // Two turns while nobody looked still read Done.
        try await report(here, "state=working:app=claude-code:turn=1:blocked=0", until: thisDevice)
        #expect(status(thisDevice, "%0") == .working)
        try await report(here, "state=done:app=claude-code:turn=3:blocked=0", until: thisDevice)
        #expect(status(thisDevice, "%0") == .done)
    }

    @Test func anAgentOpenAsItsTurnEndsNeverShowsDoneForThatTurn() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([Self.claude("state=working:app=claude-code:turn=0:blocked=0")])
        let store = try await store(tmux)
        defer { store.setHosts([]) }
        store.setAgentShown(id("%0"), viewer: viewer, scene: window)

        try await report(tmux, "state=done:app=claude-code:turn=1:blocked=0", until: store)
        #expect(status(store, "%0") == .idle)
        store.setAgentShown(nil, viewer: viewer, scene: window)
        #expect(status(store, "%0") == .idle)
    }

    @Test func anAgentOpenedWhileBlockedHasNotSeenTheDoneThatFollows() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([Self.claude("state=blocked:app=claude-code:kind=permission:turn=0:blocked=1")])
        let store = try await store(tmux)
        defer { store.setHosts([]) }
        store.setAgentShown(id("%0"), viewer: viewer, scene: window)
        store.setAgentShown(nil, viewer: viewer, scene: window)

        try await report(tmux, "state=done:app=claude-code:turn=1:blocked=1", until: store)
        #expect(status(store, "%0") == .done)
    }

    @Test func aProgramThatLeftTakesItsDoneWithIt() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(command: "pi", status: "state=done:app=pi:turn=2:blocked=0", arguments: ["pi"])
        ])
        let store = try await store(tmux)
        defer { store.setHosts([]) }
        #expect(status(store, "%0") == .done)

        await tmux.changePanes {
            $0[0].command = "zsh"
            $0[0].foregroundArguments = ["-zsh"]
            $0[0].status = "turn=2:blocked=0"
        }
        try await waitUntil("the shell") { store.agents.isEmpty }
        await tmux.changePanes {
            $0[0].command = "pi"
            $0[0].foregroundArguments = ["pi"]
            $0[0].status = "state=idle:app=pi:turn=2:blocked=0"
        }
        try await waitUntil("Pi again") { status(store, "%0") != nil }
        #expect(status(store, "%0") == .idle)
    }

    // MARK: Host memory

    @Test func seenMarksSurviveARelaunchAndAnUnseenTurnStaysDone() async throws {
        let defaults = try suite()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            Self.claude("state=done:app=claude-code:turn=1:blocked=0"),
            Self.claude(pane: 1, window: 1, "state=done:app=claude-code:turn=1:blocked=0"),
        ])
        let store = try await store(tmux, memory: HerdrCoreHostMemory(defaults: defaults))
        store.setAgentShown(id("%0"), viewer: viewer, scene: window)
        await store.suspend()

        let relaunched = try await self.store(tmux, memory: HerdrCoreHostMemory(defaults: defaults))
        defer { relaunched.setHosts([]) }
        #expect(status(relaunched, "%0") == .idle)
        #expect(status(relaunched, "%1") == .done)
    }

    @Test func anotherServerInstanceDropsTheOldInstancesSeenMarks() async throws {
        let defaults = try suite()
        let memory = HerdrCoreHostMemory(defaults: defaults)
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([Self.claude("state=done:app=claude-code:turn=1:blocked=0")])
        let store = try await store(tmux, memory: memory)
        defer { store.setHosts([]) }
        store.setAgentShown(id("%0"), viewer: viewer, scene: window)
        #expect(status(store, "%0") == .idle)
        #expect(memory.tmuxTurnStates(for: host.id)["%0"]?.seen != nil)

        // The same pane id and count, on a server that never saw this device,
        // while the detail stays open on the last one.
        let next = TmuxServerInstance(pid: 9001, startTime: 1_800_000_000)
        await tmux.startServer(
            instance: next, panes: [Self.claude("state=done:app=claude-code:turn=1:blocked=0")])
        try await waitUntil("the other server's Done") { status(store, "%0") == .done }
        #expect(memory.tmuxTurnStates(for: host.id)["%0"]?.seen == nil)
        // Its later turns are not seen through a detail of the last server.
        try await report(tmux, "state=done:app=claude-code:turn=2:blocked=0", until: store)
        #expect(status(store, "%0") == .done)
        #expect(memory.tmuxTurnStates(for: host.id)["%0"]?.seen == nil)
    }

    @Test func aClosedPaneTakesItsSeenMark() async throws {
        let memory = HerdrCoreHostMemory(defaults: try suite())
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            Self.claude("state=done:app=claude-code:turn=1:blocked=0"),
            Self.claude(pane: 1, window: 1, "state=idle:app=claude-code:turn=0:blocked=0"),
        ])
        let store = try await store(tmux, memory: memory)
        defer { store.setHosts([]) }
        store.setAgentShown(id("%0"), viewer: viewer, scene: window)
        #expect(memory.tmuxTurnStates(for: host.id)["%0"] != nil)

        await tmux.changePanes { $0.removeFirst() }
        try await waitUntil("the closed pane") { status(store, "%0") == nil }
        #expect(memory.tmuxTurnStates(for: host.id)["%0"] == nil)
        #expect(memory.tmuxTurnStates(for: host.id)["%1"] != nil)
    }
}
