import Foundation
import Testing

@testable import Heeler

/// New Agent, New Terminal, New Workspace, Rename Workspace and Close, through
/// `ConsoleStore` and the real tmux transport over a scripted Host. The row is
/// what the user sees; the recorded script is the command tmux was given.
@MainActor
@Suite("tmux launches in the Console", .timeLimit(.minutes(1)))
struct TmuxLaunchConsoleTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())

    private func console(over tmux: ScriptedTmuxHost) -> ConsoleStore {
        ConsoleStore(
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
            })
    }

    private func started(_ tmux: ScriptedTmuxHost) async -> ConsoleStore {
        let store = console(over: tmux)
        store.setHosts([host])
        await store.resume()
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

    private func isNotRunning(_ status: EventsSessionStatus?) -> Bool {
        if case .reconnecting(_, _, .tmuxServerNotRunning(socketName: "default")) = status { return true }
        return false
    }

    /// The commands the user asked for. An environment read can follow one that
    /// changes which sessions exist; these tests are about the launch itself.
    private func commandScripts(_ tmux: ScriptedTmuxHost) async -> [String] {
        await tmux.commands.filter { !$0.contains("show-environment") }
    }

    // MARK: New Agent and New Terminal

    @Test func aNewAgentOpensADetachedWindowAndLeavesTheCurrentOne() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(sessionName: "main")])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }

        _ = try await store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0", cwd: "/work"), on: host.id)

        try await waitUntil("the new agent") { store.agents.contains { $0.agent.kind == "claude" } }
        let agent = try #require(store.agents.first { $0.agent.kind == "claude" })
        #expect(agent.agent.workspaceID == "$0")
        #expect(agent.agent.tabID != "@0")
        #expect(agent.agent.paneID != "%0")
        #expect(store.terminals.contains { $0.paneID == "%0" && $0.pane.tabID == "@0" })
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("new-window -d -t"))
        #expect(script.contains("-N -S"))
        #expect(script.contains("--session-id"))
        #expect(script.contains("'/bin/zsh' -ic"))
        #expect(!script.contains("\"$SHELL\" -lic"))
        store.setHosts([])
    }

    @Test func aNewTerminalOpensAShellWindow() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make()])
        let store = await started(tmux)
        try await waitUntil("the session") { store.terminals.contains { $0.paneID == "%0" } }

        let identity = try await store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: "$0", cwd: "/work"), on: host.id)

        try await waitUntil("the shell window") { store.terminals.contains { $0.paneID == identity.paneID } }
        let opened = try #require(store.terminals.first { $0.paneID == identity.paneID })
        #expect(opened.pane.tabID == identity.tabID)
        #expect(opened.pane.tabID != "@0")
        #expect(opened.snapshotAgentKind == nil)
        #expect(opened.pane.title == "zsh")
        #expect(store.terminals.contains { $0.paneID == "%0" })
        #expect(!store.agents.contains { $0.agent.paneID == identity.paneID })
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("new-window -d -t"))
        #expect(!script.contains(" -- "))
        store.setHosts([])
    }

    // MARK: New Workspace

    @Test func aNamedWorkspaceIsANewSession() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(sessionName: "main")])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }

        _ = try await store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "claude", cwd: "/ignored"),
            workspace: NewWorkspaceSpec(directory: "/work", label: "feature"), on: host.id)

        try await waitUntil("the named session") {
            store.workspacesByHost[host.id]?.contains { $0.label == "feature" } == true
        }
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("new-session -d -E"))
        #expect(script.contains("-s feature"))
        #expect(script.contains("-N -S"))
        store.setHosts([])
    }

    @Test func anEmptyWorkspaceNameLetsTmuxNumberIt() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(sessionName: "main")])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }

        _ = try await store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/work", label: ""), tabLabel: nil, on: host.id)

        // The sidebar lists Workspaces by label. `order` is the order tmux listed them.
        try await waitUntil("the numbered session") {
            let rows = store.workspacesByHost[host.id] ?? []
            return rows.sorted { $0.order < $1.order }.map(\.label) == ["main", "1"]
        }
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("new-session -d -E"))
        #expect(!script.contains(" -s "))
        store.setHosts([])
    }

    @Test func linuxStartsAServerThroughTheLoginShell() async throws {
        let tmux = ScriptedTmuxHost(sockets: [], kernel: "Linux")
        let store = await started(tmux)
        try await waitUntil("no server") { isNotRunning(store.hostStatuses[host.id]) }

        _ = try await store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/work"), tabLabel: nil, on: host.id)

        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("\"$SHELL\" -lic"))
        #expect(script.contains("new-session -d"))
        #expect(!script.contains("-N"))
        #expect(!script.contains("-E"))
        try await waitUntil("the started session") { store.workspacesByHost[host.id]?.isEmpty == false }
        #expect(store.hostStatuses[host.id] == .connected)
        store.setHosts([])
    }

    @Test func macosRefusesToStartAServer() async throws {
        let tmux = ScriptedTmuxHost(sockets: [], kernel: "Darwin")
        let store = await started(tmux)
        try await waitUntil("no server") { isNotRunning(store.hostStatuses[host.id]) }

        await #expect(throws: TransportError.tmuxStartOnMac) {
            try await store.createShellWorkspace(NewWorkspaceSpec(directory: "/work"), tabLabel: nil, on: host.id)
        }
        #expect(await commandScripts(tmux).isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isNotRunning(store.hostStatuses[host.id]))
        store.setHosts([])
    }

    // MARK: Rename and close

    @Test func renameWorkspaceRenamesTheSession() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(sessionName: "main")])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }

        try await store.renameWorkspace("$0", label: "renamed", on: host.id)

        try await waitUntil("the new name") { store.workspacesByHost[host.id]?.map(\.label) == ["renamed"] }
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("rename-session -t '$0' -- renamed"))
        store.setHosts([])
    }

    @Test func closingALoneAgentKillsItsWindow() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(command: "claude", arguments: ["claude"])])
        let store = await started(tmux)
        try await waitUntil("the agent") { store.agents.count == 1 }
        let agent = try #require(store.agents.first)

        try await store.closeAgent(agent)

        try await waitUntil("the window gone") { store.agents.isEmpty && store.workspacesByHost[host.id]?.isEmpty == true }
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("kill-window -t @0"))
        store.setHosts([])
    }

    @Test func closingOnePaneLeavesTheOther() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", arguments: ["claude"]),
            .make(pane: 1, paneIndex: 1, command: "zsh", arguments: ["/bin/zsh"]),
        ])
        let store = await started(tmux)
        try await waitUntil("both panes") {
            store.agents.count == 1 && store.terminals.contains { $0.paneID == "%1" }
        }
        let agent = try #require(store.agents.first)

        try await store.closeAgent(agent)

        try await waitUntil("the agent gone") { store.agents.isEmpty }
        #expect(store.terminals.contains { $0.paneID == "%1" && $0.pane.tabID == "@0" })
        #expect(store.workspacesByHost[host.id]?.map(\.label) == ["main"])
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("kill-pane -t '%0'"))
        store.setHosts([])
    }

    // MARK: Discovery

    @Test func discoveryListsClaudeAndKeepsOpenCodesVersion() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setInstalled(["claude", "opencode"], openCodeVersion: "opencode v2.2.2")
        await tmux.setPanes([.make()])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.isEmpty == false }

        let kinds = try await store.availableAgentKinds(on: host.id)
        #expect(kinds.contains(.claude))
        #expect(kinds.contains(.opencode))

        _ = try await store.startAgent(
            AgentLaunchRequest(kind: "opencode", name: "opencode", workspaceID: "$0", cwd: "/work"), on: host.id)
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains(" opencode -s "))
        store.setHosts([])
    }
}
