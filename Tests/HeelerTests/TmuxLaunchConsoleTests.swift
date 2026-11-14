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

    private func console(
        over tmux: ScriptedTmuxHost,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(
            initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10))
    ) -> ConsoleStore {
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
                    reconnectPolicy: reconnectPolicy,
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            })
    }

    private func started(
        _ tmux: ScriptedTmuxHost,
        host: Host? = nil,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(
            initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10))
    ) async -> ConsoleStore {
        let store = console(over: tmux, reconnectPolicy: reconnectPolicy)
        store.setHosts([host ?? self.host])
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

    @Test func globalNewAgentStartsInAnExistingWorkspaceAndKeepsItsCurrentWindow() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setInstalled(["pi"])
        await tmux.setPanes([
            .make(session: 0, sessionName: "alpha", window: 0, pane: 0, command: "bash", path: "/home/boxd/heeler-accept/repo"),
            .make(
                session: 0, sessionName: "alpha", window: 1, windowIndex: 2, pane: 1, command: "python3",
                path: "/home/boxd"),
        ])
        let store = await started(tmux)
        defer { store.setHosts([]) }
        try await waitUntil("the existing session") {
            store.workspacesByHost[host.id]?.map(\.label) == ["alpha"]
        }

        let form = StartAgentStore(
            hosts: [host],
            workspaces: { store.workspaces(for: $0) },
            existingAgentNames: { store.takenAgentNames(on: $0) },
            discoverAgentKinds: { try await store.availableAgentKinds(on: $0) },
            remoteHome: { try await store.remoteHomeDirectory(on: $0) },
            start: { params, destination, hostID in
                switch destination {
                case .existingWorkspace:
                    try await store.startAgent(params, on: hostID)
                case .newWorktree(let worktree):
                    try await store.startAgentInNewWorktree(params, worktree: worktree, on: hostID)
                case .newWorkspace(let workspace):
                    try await store.startAgentInNewWorkspace(params, workspace: workspace, on: hostID)
                }
            },
            awaitAgentVisible: { await store.waitForAgent($0) },
            isAgentListed: { id in store.agents.contains { $0.id == id } },
            programExit: { store.programExit(of: $0) },
            offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces },
            offersConnectedWorktrees: { store.capabilities(for: $0).worktrees })
        await form.discoverAgents()
        form.selectExistingWorkspace("$0")
        form.selectedAgentKind = .pi
        form.name = "accept-launched-pi"

        await form.submit()

        let startedID = ConsoleAgent.ID(hostID: host.id, paneID: "%2")
        #expect(form.state == .started(startedID))
        let launched = try #require(store.agents.first { $0.id == startedID })
        #expect(launched.agent.workspaceID == "$0")
        #expect(launched.agent.cwd == "/home/boxd/heeler-accept/repo")
        #expect(launched.agent.tabID != "@0" && launched.agent.tabID != "@1")
        #expect(store.terminals.contains { $0.paneID == "%1" && $0.pane.tabID == "@1" })
        let script = try #require(await commandScripts(tmux).last)
        #expect(script.contains("new-window -d -t '$0' -c '/home/boxd/heeler-accept/repo'"))
    }

    @Test func existingWorkspaceLaunchPrefersMarkedWorktreeAndFallsBackToHome() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(
                session: 0, sessionName: "wt", window: 0, pane: 0, command: "pi", path: "",
                worktree: "/work/wt", arguments: ["pi"]),
            .make(session: 1, sessionName: "plain", window: 1, pane: 1, command: "zsh", path: ""),
        ])
        let store = await started(tmux)
        defer { store.setHosts([]) }
        try await waitUntil("both sessions") {
            store.workspacesByHost[host.id]?.count == 2 && store.agents.count == 1
        }

        let existingAgent = try #require(store.agents.first)
        let origin = StartAgentStore.LaunchOrigin(beside: existingAgent, in: store)
        #expect(origin.cwd == "/work/wt")

        let inWorktree = try await store.startAgent(
            AgentLaunchRequest(kind: "pi", name: "pi", workspaceID: "$0"), on: host.id)
        #expect(inWorktree.cwd == "/work/wt")
        let worktreeScript = try #require(await commandScripts(tmux).last)
        #expect(worktreeScript.contains("new-window -d -t '$0' -c '/work/wt'"))

        let inHome = try await store.startAgent(
            AgentLaunchRequest(kind: "pi", name: "pi-2", workspaceID: "$1"), on: host.id)
        #expect(inHome.cwd == ScriptedTmuxHost.home)
        let homeScript = try #require(await commandScripts(tmux).last)
        #expect(homeScript.contains("new-window -d -t '$1' -c '\(ScriptedTmuxHost.home)'"))
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

    @Test func linuxNewWorkspaceWakesTheSessionDuringBackoffAndOpensItsTerminal() async throws {
        let tmux = ScriptedTmuxHost(sockets: [], kernel: "Linux")
        let longBackoff = ReconnectPolicy(initialDelay: .seconds(30), multiplier: 2, maxDelay: .seconds(30))
        let store = await started(tmux, reconnectPolicy: longBackoff)
        defer { store.setHosts([]) }
        try await waitUntil("no server") { isNotRunning(store.hostStatuses[host.id]) }

        let form = NewTerminalStore(
            hosts: [host],
            initialHostID: host.id,
            workspaces: { store.workspaces(for: $0) },
            directory: { _, _ in nil },
            remoteHome: { try await store.remoteHomeDirectory(on: $0) },
            create: { destination, hostID in
                switch destination {
                case .existing(let request):
                    try await store.createShellTerminal(request, on: hostID)
                case .newWorkspace(let workspace, let tabLabel):
                    try await store.createShellWorkspace(workspace, tabLabel: tabLabel, on: hostID)
                }
            },
            awaitTerminal: { await store.waitForTerminal($0, on: $1) },
            offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces })
        form.applyBrowsedDirectory("/work")
        form.newWorkspaceLabel = "linux-start"

        await form.submit()

        #expect(form.state == .created(ConsoleTerminal.ID(hostID: host.id, paneID: "%0")))
        #expect(store.hostStatuses[host.id] == .connected)
        #expect(store.workspacesByHost[host.id]?.map(\.label) == ["linux-start"])
    }

    @Test func linuxNewWorkspaceRecoversFromAnInstallFailureAndOpensItsTerminal() async throws {
        let tmux = ScriptedTmuxHost(version: "tmux 3.2a", sockets: [], kernel: "Linux")
        let longBackoff = ReconnectPolicy(initialDelay: .seconds(30), multiplier: 2, maxDelay: .seconds(30))
        var catalogHost = host
        let store = await started(tmux, host: catalogHost, reconnectPolicy: longBackoff)
        defer { store.setHosts([]) }
        try await waitUntil("update required") {
            store.hostStatuses[catalogHost.id] == .failed(.tmuxUpdateRequired(version: "3.2a"))
        }

        await tmux.uninstall()
        await store.retryHost(catalogHost.id)
        try await waitUntil("not installed") {
            store.hostStatuses[catalogHost.id] == .failed(.tmuxNotInstalled)
        }

        await tmux.moveExecutable(to: "/home/dev/.local/opt/tmux-3.3a/bin/tmux", version: "tmux 3.3a")
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .failure(.cancelled)), tmux: tmux)
        let onboarding = HostOnboardingStore(
            host: catalogHost,
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            noteTmuxPaths: { _, paths in
                catalogHost.tmuxPaths = paths
                store.setHosts([catalogHost])
            })
        await onboarding.runChecks()
        #expect(onboarding.isWaitingForTmuxServer)
        #expect(
            HostOnboardingCoreFollow.action(
                afterTmuxChecks: onboarding.report == .allPassed,
                isWaitingForServer: onboarding.isWaitingForTmuxServer,
                serverKind: .tmux,
                status: store.hostStatuses[catalogHost.id]) == .wakeConsole)

        // Even before a manual reconnect, New Workspace resolves the restored tmux,
        // starts the server, wakes the stopped session, and opens the terminal.
        let form = NewTerminalStore(
            hosts: [catalogHost],
            initialHostID: catalogHost.id,
            workspaces: { store.workspaces(for: $0) },
            directory: { _, _ in nil },
            remoteHome: { try await store.remoteHomeDirectory(on: $0) },
            create: { destination, hostID in
                switch destination {
                case .existing(let request):
                    try await store.createShellTerminal(request, on: hostID)
                case .newWorkspace(let workspace, let tabLabel):
                    try await store.createShellWorkspace(workspace, tabLabel: tabLabel, on: hostID)
                }
            },
            awaitTerminal: { await store.waitForTerminal($0, on: $1) },
            offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces })
        form.applyBrowsedDirectory("/home/boxd/heeler-accept/repo")
        form.newWorkspaceLabel = "linux-start"

        await form.submit()

        #expect(form.state == .created(ConsoleTerminal.ID(hostID: catalogHost.id, paneID: "%0")))
        #expect(store.hostStatuses[catalogHost.id] == .connected)
        #expect(store.hostStandingFailures[catalogHost.id] == nil)
        #expect(store.workspacesByHost[catalogHost.id]?.map(\.label) == ["linux-start"])
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

    // MARK: Heeler's Claude Code hooks (ADR 0046)

    private let dataHome = "\(ScriptedTmuxHost.home)/Library/Application Support"
    private var hookScript: String { ClaudeCodeHooks.scriptPath(dataHome: dataHome) }
    private var hookSettings: String { ClaudeCodeHooks.launchSettingsPath(dataHome: dataHome) }
    private var storedPaths: String {
        TmuxClaudeCodeHooks.storedPathsFile(dataHome: dataHome, paths: ScriptedTmuxHost.paths())
    }

    /// The last launch's program, as tmux parses the exec line's words.
    private func launchedProgram(_ tmux: ScriptedTmuxHost) async throws -> [String] {
        let script = try #require(await commandScripts(tmux).last)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("exec ") })
        let words = ScriptedTmuxHost.words(of: String(line))
        let separator = try #require(words.firstIndex(of: "--"))
        return Array(words[(separator + 1)...])
    }

    private func startedWithSession(_ tmux: ScriptedTmuxHost) async throws -> ConsoleStore {
        await tmux.setPanes([.make(sessionName: "main")])
        let store = await started(tmux)
        try await waitUntil("the session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }
        return store
    }

    private func claude(environment: [String: String] = [:]) -> AgentLaunchRequest {
        AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0", cwd: "/work", environment: environment)
    }

    @Test func aClaudeCodeAgentGetsHeelersHooksForItsLaunchAlone() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgent(claude(), on: host.id)

        #expect(Array(try await launchedProgram(tmux).suffix(2)) == ["--settings", hookSettings])
        let files = await tmux.hostFiles
        #expect(files[hookScript] == (try TmuxClaudeCodeHooks.bundledScript()))
        #expect(files[hookSettings] == ClaudeCodeHooks.launchSettings(script: hookScript))
        #expect(storedPaths == "\(dataHome)/heeler/host-helper/tmux/default/paths.json")
        let stored = try #require(files[storedPaths])
        #expect(try JSONDecoder().decode(TmuxPaths.self, from: stored) == ScriptedTmuxHost.paths())
        // Heeler's own files and nothing else: the root's settings stay as they were.
        #expect(Set(files.keys) == [hookScript, hookSettings, storedPaths])
        store.setHosts([])
    }

    @Test func aRootThatRunsTheHooksGetsNoSettings() async throws {
        let tmux = ScriptedTmuxHost()
        let settings = ClaudeCodeHooks.launchSettings(script: hookScript)
        await tmux.setHostFile("\(ScriptedTmuxHost.home)/.claude/settings.json", settings)
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgent(claude(), on: host.id)

        let program = try await launchedProgram(tmux)
        #expect(program.contains("claude"))
        #expect(!program.contains("--settings"))
        #expect(await tmux.hostFiles["\(ScriptedTmuxHost.home)/.claude/settings.json"] == settings)
        store.setHosts([])
    }

    @Test func theRootAnAccountNamesIsTheOneThatCounts() async throws {
        let tmux = ScriptedTmuxHost()
        let work = "\(ScriptedTmuxHost.home)/.claude-work"
        await tmux.setHostFile(
            "\(ScriptedTmuxHost.home)/.claude/settings.json", ClaudeCodeHooks.launchSettings(script: hookScript))
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgent(claude(environment: ["CLAUDE_CONFIG_DIR": work]), on: host.id)
        #expect(Array(try await launchedProgram(tmux).suffix(2)) == ["--settings", hookSettings])

        await tmux.setHostFile("\(work)/settings.json", ClaudeCodeHooks.launchSettings(script: hookScript))
        _ = try await store.startAgent(claude(environment: ["CLAUDE_CONFIG_DIR": work]), on: host.id)
        #expect(!(try await launchedProgram(tmux)).contains("--settings"))
        // The Host's folders are read once; the files are placed for each launch.
        #expect(await tmux.log.filter { $0 == "locate" }.count == 1)
        #expect(await tmux.log.filter { $0 == "place hook files" }.count == 2)
        store.setHosts([])
    }

    @Test func anotherProgramPlacesNothing() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgent(
            AgentLaunchRequest(kind: "codex", name: "codex", workspaceID: "$0", cwd: "/work"), on: host.id)

        #expect(try await launchedProgram(tmux).contains("codex"))
        #expect(await tmux.hostFiles.isEmpty)
        #expect(await !tmux.log.contains("place hook files"))
        store.setHosts([])
    }

    @Test func aHostThatRefusesTheFilesStillStartsClaudeCode() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.refuseHookFiles()
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgent(claude(), on: host.id)

        try await waitUntil("the new agent") { store.agents.contains { $0.agent.kind == "claude" } }
        let program = try await launchedProgram(tmux)
        #expect(program.contains("claude"))
        #expect(!program.contains("--settings"))
        store.setHosts([])
    }

    @Test func aClaudeCodeInANewWorkspaceGetsTheHooksToo() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await startedWithSession(tmux)

        _ = try await store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "claude", cwd: "/ignored"),
            workspace: NewWorkspaceSpec(directory: "/work", label: "feature"), on: host.id)

        #expect(Array(try await launchedProgram(tmux).suffix(2)) == ["--settings", hookSettings])
        store.setHosts([])
    }

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
