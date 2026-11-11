import Foundation
import Testing

@testable import Heeler

/// What a tmux server lists, through `ConsoleStore` and the real tmux
/// transport over a scripted Host, on a device whose defaults outlive each
/// launch: sessions, windows and panes as Workspaces, Tabs and Panes, which
/// Panes are Agents, and what goes with a server instance (ADR 0043).
@MainActor
@Suite("tmux inventory in the Console", .timeLimit(.minutes(1)))
struct TmuxInventoryConsoleTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
    private let suiteName = "tmux-inventory-\(UUID().uuidString)"

    private func device() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suiteName))
    }

    /// One launch of the app: everything it remembers is read back from `defaults`.
    private func launch(
        on defaults: UserDefaults, over tmux: ScriptedTmuxHost, awaitingInventory: Bool = true,
        keepalive: KeepalivePolicy? = KeepalivePolicy(interval: .milliseconds(10)),
        settledLoopLife: Duration = .seconds(2)
    ) async throws -> ConsoleStore {
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
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
                    keepalive: keepalive, settledLoopLife: settledLoopLife)
            },
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        store.setHosts([host])
        await store.resume()
        if awaitingInventory {
            try await waitUntil("the first inventory") { store.hostsAwaitingSnapshot.isEmpty }
        }
        return store
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func panes(_ store: ConsoleStore) -> [String] {
        store.terminals.map(\.paneID)
    }

    private func agents(_ store: ConsoleStore) -> [String] {
        store.agents.map(\.agent.paneID).sorted()
    }

    /// What the next launch would read.
    private func persistedPins(on defaults: UserDefaults) -> [String] {
        PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: host.id)
    }

    private nonisolated static let claude: [String] = ["claude", "--resume"]

    // MARK: Rows and order

    @Test func sessionsWindowsAndPanesListAsWorkspacesTabsAndPanesInTmuxsOrder() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(session: 2, sessionName: "api", window: 4, windowIndex: 0, windowName: "server", pane: 6, path: "/srv/api"),
            .make(session: 2, sessionName: "api", window: 4, windowIndex: 0, windowName: "server", pane: 11, paneIndex: 1,
                  command: "claude", path: "/srv/api", arguments: Self.claude),
            .make(session: 2, sessionName: "api", window: 9, windowIndex: 3, windowName: "logs", pane: 10, command: "tail",
                  arguments: ["tail", "-f", "log"]),
            .make(session: 0, sessionName: "web", window: 0, windowIndex: 1, windowName: "editor", pane: 0, command: "vim",
                  path: "/srv/web", width: 120, height: 40, arguments: ["vim"]),
        ])
        let store = try await launch(on: try device(), over: tmux)

        #expect(store.hostStatuses[host.id] == .connected)
        // Panes in tmux's order, `%11` before `%10` where its window comes first.
        #expect(panes(store) == ["%6", "%11", "%10", "%0"])
        #expect(store.terminals.map(\.workspaceLabel) == ["api", "api", "api", "web"])
        #expect(store.terminals.map(\.tabLabel) == ["server", "server", "logs", "editor"])
        #expect(store.terminals.map(\.workspaceID) == ["$2", "$2", "$2", "$0"])
        #expect(store.terminals.map(\.tabID) == ["@4", "@4", "@9", "@0"])
        #expect(store.terminals.map(\.tabPosition) == [1, 1, 2, 1])
        #expect(store.terminals.map(\.title) == ["zsh", "claude", "tail", "vim"])
        #expect(store.terminals.map(\.cwd) == ["/srv/api", "/srv/api", "/home/dev", "/srv/web"])
        #expect(store.terminals.last?.gridColumns == 120)
        #expect(store.terminals.last?.gridRows == 40)

        let workspaces = try #require(store.workspacesByHost[host.id])
        #expect(workspaces.sorted { $0.order < $1.order }.map(\.label) == ["api", "web"])
        #expect(workspaces.sorted { $0.order < $1.order }.map(\.id) == ["$2", "$0"])

        let agent = try #require(store.agents.first)
        #expect(store.agents.count == 1)
        #expect(agent.agent.paneID == "%11")
        #expect(agent.agent.kind == "claude")
        // Its status is read by a later change.
        #expect(agent.agent.status == .unknown)
        #expect(agent.workspaceLabel == "api")
        #expect(agent.tabLabel == "server")
        #expect(agent.tabPaneCount == 2)
        #expect(agent.workspaceTabCount == 2)
        #expect(agent.directory == "/srv/api")
        store.setHosts([])
    }

    @Test func aChangeOnTheServerReachesTheConsole() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(windowName: "first")])
        let store = try await launch(on: try device(), over: tmux)
        #expect(panes(store) == ["%0"])

        // A new window, then a rename.
        await tmux.changePanes { $0.append(.make(window: 1, windowIndex: 1, windowName: "second", pane: 1)) }
        try await waitUntil("the new window") { panes(store) == ["%0", "%1"] }
        #expect(store.terminals.map(\.tabLabel) == ["first", "second"])

        await tmux.changePanes { $0[1].windowName = "build" }
        try await waitUntil("the rename") { store.terminals.map(\.tabLabel) == ["first", "build"] }

        await tmux.changePanes { panes in
            for index in panes.indices { panes[index].sessionName = "work" }
        }
        try await waitUntil("the session's new name") { store.workspacesByHost[host.id]?.map(\.label) == ["work"] }

        await tmux.changePanes { $0.removeFirst() }
        try await waitUntil("the closed window") { panes(store) == ["%1"] }
        // One loop followed all of it, on the one connection. Environment reads
        // are commands on that connection, not another probe.
        #expect(await tmux.loopLog == ["open"])
        #expect(await tmux.log.filter { $0.hasPrefix("probe") }.allSatisfy { $0 == "probe stored" })
        store.setHosts([])
        try await waitUntil("the loop's end") { await tmux.openLoops == 0 }
    }

    @Test func aHostIsAwaitedUntilItsServerHasListedItsPanes() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.failNextLoop(.channelFailed(detail: "no session left"))
        let store = try await launch(on: try device(), over: tmux, awaitingInventory: false)

        try await waitUntil("the server's answer") { store.tmuxServer(on: host.id) != nil }
        #expect(store.hostStatuses[host.id] == .connected)
        // The loop that could not start is tried again with the next ask.
        try await waitUntil("the inventory") { !store.hostsAwaitingSnapshot.contains(host.id) }
        #expect(store.terminals.isEmpty)
        #expect(await tmux.loopLog == ["open"])
        store.setHosts([])
    }

    // MARK: Shared windows and Heeler's own sessions

    @Test func aWindowSharedBySeveralSessionsShowsOnce() async throws {
        let tmux = ScriptedTmuxHost()
        // `main` and its group `main-2` share both windows, and `side` links one.
        var listed: [TmuxInventory.Pane] = []
        for (session, name) in [(1, "main"), (3, "main-2")] {
            listed.append(
                .make(session: session, sessionName: name, window: 0, windowIndex: 0, windowName: "agent", pane: 0,
                      command: "claude", arguments: Self.claude))
            listed.append(
                .make(session: session, sessionName: name, window: 1, windowIndex: 1, windowName: "shell", pane: 1))
        }
        listed.append(
            .make(session: 0, sessionName: "side", window: 5, windowIndex: 0, windowName: "own", pane: 7))
        listed.append(
            .make(session: 0, sessionName: "side", window: 1, windowIndex: 4, windowName: "shell", pane: 1))
        await tmux.setPanes(listed)
        let store = try await launch(on: try device(), over: tmux)

        // `@1` shows under `side`, the lowest id that lists it, and `@0` under `main`.
        #expect(panes(store) == ["%0", "%7", "%1"])
        #expect(store.terminals.map(\.workspaceLabel) == ["main", "side", "side"])
        #expect(agents(store) == ["%0"])
        #expect(store.agents.first?.workspaceLabel == "main")
        #expect(store.workspacesByHost[host.id]?.map(\.label).sorted() == ["main", "side"])
        store.setHosts([])
    }

    @Test func heelersOwnSessionsNeverShow() async throws {
        let tmux = ScriptedTmuxHost()
        let agent = { (session: Int, name: String, mark: String) in
            TmuxInventory.Pane.make(
                session: session, sessionName: name, window: 2, windowIndex: 0, windowName: "agent", pane: 2,
                command: "codex", attachMark: mark, arguments: ["codex"])
        }
        await tmux.setPanes([agent(1, "main", "")])
        let store = try await launch(on: try device(), over: tmux)
        #expect(panes(store) == ["%2"])

        // An Attach links the window into a session of Heeler's, with a placeholder
        // beside it, and the user renames their session meanwhile.
        await tmux.setPanes([
            agent(0, "heeler-7", "1"),
            .make(session: 0, sessionName: "heeler-7", window: 8, windowIndex: 1, windowName: "hold", pane: 9,
                  attachMark: "1"),
            agent(1, "work", ""),
        ])
        try await waitUntil("the next inventory") { store.terminals.first?.workspaceLabel == "work" }

        #expect(panes(store) == ["%2"])
        #expect(store.terminals.map(\.workspaceID) == ["$1"])
        #expect(agents(store) == ["%2"])
        #expect(store.workspacesByHost[host.id]?.map(\.label) == ["work"])
        store.setHosts([])
    }

    // MARK: The Agent rule

    @Test func aPaneIsAnAgentOnlyWhileAKnownProgramHoldsItsForeground() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "zsh", arguments: ["-zsh"]),
            // Wrappers, a `sh -c` line, an interpreter and `npx`.
            .make(pane: 1, paneIndex: 1, command: "zsh",
                  arguments: ["/bin/zsh", "-lc", "exec \"$@\"", "zsh", "claude", "--resume"]),
            .make(pane: 2, paneIndex: 2, command: "sh", arguments: ["sh", "-c", "cd /srv && exec codex"]),
            .make(pane: 3, paneIndex: 3, command: "node",
                  arguments: ["node", "/usr/lib/node_modules/@google/gemini-cli/dist/index.js"]),
            .make(pane: 4, paneIndex: 4, command: "node", arguments: ["npx", "-y", "@anthropic-ai/claude-code"]),
            // Any other program is a terminal, whatever a status says.
            .make(pane: 5, paneIndex: 5, command: "vim", status: "state=working:app=aider", arguments: ["vim"]),
            // Arguments the Host could not read leave tmux's own name for the program.
            .make(pane: 6, paneIndex: 6, command: "opencode"),
        ])
        let store = try await launch(on: try device(), over: tmux)

        #expect(panes(store) == ["%0", "%1", "%2", "%3", "%4", "%5", "%6"])
        #expect(store.terminals.map(\.agentKind) == [nil, "claude", "codex", "gemini", "claude", nil, "opencode"])
        #expect(agents(store) == ["%1", "%2", "%3", "%4", "%6"])
        #expect(store.agents.allSatisfy { $0.agent.status == .unknown })
        store.setHosts([])
    }

    @Test func anAgentEndsAtItsShellAndADeadPaneHostsNone() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", arguments: Self.claude),
            .make(window: 1, windowIndex: 1, pane: 1, command: "codex", arguments: ["codex"]),
        ])
        let store = try await launch(on: try device(), over: tmux)
        #expect(agents(store) == ["%0", "%1"])

        // Claude exits to the shell that started it: the pane stays, as a terminal.
        await tmux.changePanes {
            $0[0].command = "zsh"
            $0[0].foregroundArguments = ["-zsh"]
        }
        try await waitUntil("the shell") { agents(store) == ["%1"] }
        #expect(panes(store) == ["%0", "%1"])
        #expect(store.terminals.first?.isAgent == false)

        // Codex exits in a pane that `remain-on-exit` keeps.
        await tmux.changePanes { $0[1].isDead = true }
        try await waitUntil("the dead pane") { agents(store).isEmpty }
        #expect(panes(store) == ["%0", "%1"])

        // A shell that starts an agent again hosts one again.
        await tmux.changePanes {
            $0[0].command = "claude"
            $0[0].foregroundArguments = Self.claude
        }
        try await waitUntil("the agent again") { agents(store) == ["%0"] }
        store.setHosts([])
    }

    // MARK: A server instance

    @Test func aServerThatStopsListsNothingUntilAnotherAnswers() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(command: "claude", arguments: Self.claude)])
        let store = try await launch(on: try device(), over: tmux)
        #expect(agents(store) == ["%0"])
        #expect(store.corePin(on: host.id).admits(ScriptedTmuxHost.instance.id))

        await tmux.stopServer()
        try await waitUntil("the stopped server") {
            if case .reconnecting(_, _, .tmuxServerNotRunning) = store.hostStatuses[host.id] { true } else { false }
        }
        #expect(store.agents.isEmpty)
        #expect(store.terminals.isEmpty)
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        let next = TmuxServerInstance(pid: 9001, startTime: 1_800_000_000)
        await tmux.startServer(instance: next, panes: [.make(command: "zsh", arguments: ["-zsh"])])
        try await waitUntil("the new server's panes") { panes(store) == ["%0"] }
        #expect(store.agents.isEmpty)
        #expect(store.tmuxServer(on: host.id)?.instance == next)
        store.setHosts([])
    }

    /// The loop says its server is gone within a second, where the next ask
    /// would only find out at its interval.
    @Test func aLoopThatEndsAfterFollowingItsServerHasTheServerAskedAtOnce() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make()])
        let store = try await launch(on: try device(), over: tmux, keepalive: nil, settledLoopLife: .zero)
        #expect(panes(store) == ["%0"])

        await tmux.stopServer()
        try await waitUntil("the stopped server") {
            if case .reconnecting(_, _, .tmuxServerNotRunning) = store.hostStatuses[host.id] { true } else { false }
        }
        #expect(store.terminals.isEmpty)
        store.setHosts([])
    }

    /// A Host that ends the exec as soon as it starts is not asked in a spin.
    @Test func aLoopThatEndsAsSoonAsItStartedWaitsForTheNextAsk() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make()])
        let store = try await launch(on: try device(), over: tmux, keepalive: nil)
        #expect(panes(store) == ["%0"])

        await tmux.breakLoops(.channelFailed(detail: "killed"))
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await tmux.loopLog == ["open", "close"])
        #expect(await tmux.log.filter { $0.hasPrefix("probe") } == ["probe stored"])
        // What it listed stands until the server says otherwise.
        #expect(store.hostStatuses[host.id] == .connected)
        #expect(panes(store) == ["%0"])

        // A foreground return asks, and the next answer starts another loop.
        await store.reactivate()
        try await waitUntil("another loop") { await tmux.openLoops == 1 }
        #expect(await tmux.log.filter { $0.hasPrefix("probe") } == ["probe stored", "probe stored"])
        store.setHosts([])
    }

    @Test func aDetailOpenedOnOneInstanceHasLeftItOnceAnotherAnswers() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(command: "claude", arguments: Self.claude)])
        let store = try await launch(on: try device(), over: tmux)
        let pin = store.corePin(on: host.id)
        #expect(!store.hasLeftCore(pin, on: host.id))

        // Replaced between two asks: the same socket, the same pane id, another server.
        let next = TmuxServerInstance(pid: ScriptedTmuxHost.instance.pid, startTime: ScriptedTmuxHost.instance.startTime + 60)
        await tmux.startServer(instance: next, panes: [.make(command: "codex", arguments: ["codex"])])

        try await waitUntil("the other server's agent") { store.agents.first?.agent.kind == "codex" }
        #expect(store.hasLeftCore(pin, on: host.id))
        #expect(!store.hasLeftCore(store.corePin(on: host.id), on: host.id))
        store.setHosts([])
    }

    // MARK: Pins

    @Test func aPinStaysWithItsPaneAcrossARelaunchOnTheSameServer() async throws {
        let defaults = try device()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", arguments: Self.claude),
            .make(window: 1, windowIndex: 1, pane: 1, command: "codex", arguments: ["codex"]),
        ])
        let store = try await launch(on: defaults, over: tmux)
        store.togglePin(hostID: host.id, paneID: "%1")
        #expect(persistedPins(on: defaults) == ["%1"])
        await store.suspend()

        let relaunched = try await launch(on: defaults, over: tmux)
        defer { relaunched.setHosts([]) }
        #expect(agents(relaunched) == ["%0", "%1"])
        #expect(relaunched.pins.pinnedPaneIDs(for: host.id) == ["%1"])
        #expect(persistedPins(on: defaults) == ["%1"])
    }

    @Test func aPinGoesWhenItsPaneCloses() async throws {
        let defaults = try device()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", arguments: Self.claude),
            .make(window: 1, windowIndex: 1, pane: 1, command: "codex", arguments: ["codex"]),
        ])
        let store = try await launch(on: defaults, over: tmux)
        store.togglePin(hostID: host.id, paneID: "%0")
        store.togglePin(hostID: host.id, paneID: "%1")

        // tmux never gives a closed pane's id out again while it runs.
        await tmux.changePanes { $0.removeLast() }
        try await waitUntil("the closed pane") { agents(store) == ["%0"] }
        #expect(persistedPins(on: defaults) == ["%0"])

        // A pane that only stopped hosting an Agent keeps its Pin.
        await tmux.changePanes {
            $0[0].command = "zsh"
            $0[0].foregroundArguments = ["-zsh"]
        }
        try await waitUntil("the shell") { agents(store).isEmpty }
        #expect(persistedPins(on: defaults) == ["%0"])
        store.setHosts([])
    }

    @Test func aNewServerInstanceDropsTheOldOnesPinsThoughItsPaneIDsRepeat() async throws {
        let defaults = try device()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(pane: 0, command: "claude", arguments: Self.claude)])
        let store = try await launch(on: defaults, over: tmux)
        store.togglePin(hostID: host.id, paneID: "%0")
        #expect(persistedPins(on: defaults) == ["%0"])

        // The server restarts and its first pane is `%0` again, running another agent.
        await tmux.stopServer()
        try await waitUntil("the stopped server") { store.hostStatuses[host.id] != .connected }
        // A server that is not running says nothing of its Pins.
        #expect(persistedPins(on: defaults) == ["%0"])
        await tmux.startServer(
            instance: TmuxServerInstance(pid: 5151, startTime: 1_800_000_000),
            panes: [.make(pane: 0, command: "codex", arguments: ["codex"])])

        try await waitUntil("the new server's agent") { store.agents.first?.agent.kind == "codex" }
        #expect(persistedPins(on: defaults).isEmpty)
        #expect(store.pins.pinnedPaneIDs(for: host.id).isEmpty)
        store.setHosts([])
    }

    @Test func aServerThatRestartedWhileTheAppWasClosedDropsItsPinsAtTheNextLaunch() async throws {
        let defaults = try device()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(pane: 0, command: "claude", arguments: Self.claude)])
        let store = try await launch(on: defaults, over: tmux)
        store.togglePin(hostID: host.id, paneID: "%0")
        await store.suspend()

        await tmux.stopServer()
        await tmux.startServer(
            instance: TmuxServerInstance(pid: 5151, startTime: 1_800_000_000),
            panes: [.make(pane: 0, command: "claude", arguments: Self.claude)])

        let relaunched = try await launch(on: defaults, over: tmux)
        #expect(agents(relaunched) == ["%0"])
        #expect(persistedPins(on: defaults).isEmpty)
        #expect(relaunched.pins.pinnedPaneIDs(for: host.id).isEmpty)
        relaunched.setHosts([])
    }

    @Test func removingTheHostForgetsItsServerInstance() async throws {
        let defaults = try device()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make()])
        let store = try await launch(on: defaults, over: tmux)
        #expect(HerdrCoreHostMemory(defaults: defaults).coreID(for: host.id) == ScriptedTmuxHost.instance.id)

        // Still in the catalog: what the device remembers of it stays.
        store.setHosts([host])
        #expect(HerdrCoreHostMemory(defaults: defaults).coreID(for: host.id) == ScriptedTmuxHost.instance.id)

        store.setHosts([])
        #expect(HerdrCoreHostMemory(defaults: defaults).coreID(for: host.id) == nil)
    }
}
