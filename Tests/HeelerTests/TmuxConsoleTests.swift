import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A tmux Host in the Console, through `ConsoleStore` and the real tmux
/// transport over a scripted Host: its connection states, the paths it
/// resolves, and what it offers. `TmuxInventoryConsoleTests` covers what it
/// lists, and `TmuxLaunchConsoleTests` covers starting, renaming and closing.
@MainActor
@Suite("tmux Host in the Console", .timeLimit(.minutes(1)))
struct TmuxConsoleTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())

    private final class Dials: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func note() { count.withLock { $0 += 1 } }
    }

    private struct Console {
        let store: ConsoleStore
        let dials: Dials
        let resolved: ResolvedPaths
    }

    @MainActor
    private final class ResolvedPaths {
        var noted: [TmuxPaths] = []
    }

    /// A Console over `tmux`, asking again every few milliseconds.
    private func console(over tmux: ScriptedTmuxHost) -> Console {
        let dials = Dials()
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
                        dials.note()
                        return await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            })
        let resolved = ResolvedPaths()
        store.onTmuxPathsResolved = { _, paths in resolved.noted.append(paths) }
        return Console(store: store, dials: dials, resolved: resolved)
    }

    private func started(_ tmux: ScriptedTmuxHost, host: Host? = nil) async -> Console {
        let console = console(over: tmux)
        console.store.setHosts([host ?? self.host])
        await console.store.resume()
        return console
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

    // MARK: Connected

    @Test func aTmuxHostConnectsOnItsStoredPaths() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store

        try await waitUntil("the server's answer") { !store.hostsAwaitingSnapshot.contains(host.id) }

        #expect(store.hostStatuses[host.id] == .connected)
        #expect(store.hostLatencies[host.id] != nil)
        #expect(store.agents.isEmpty)
        #expect(store.terminals.isEmpty)
        #expect(store.workspacesByHost[host.id] == [])
        #expect(store.hostStandingFailures[host.id] == nil)
        // The stored paths answered: no login shell, and nothing for the catalog.
        #expect(await tmux.log.filter { $0.hasPrefix("probe") }.allSatisfy { $0 == "probe stored" })
        #expect(await tmux.log.contains { $0.hasPrefix("probe") })
        #expect(console.resolved.noted.isEmpty)
        store.setHosts([])
    }

    @Test func aTmuxHostOffersLaunchesRenameAndClose() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        let offers = store.capabilities(for: host.id)
        #expect(offers.startsAgents)
        #expect(offers.startsTerminals)
        #expect(offers.renamesWorkspaces)
        #expect(offers.closeTab)
        #expect(offers.namesCreatedWorkspaces)
        #expect(offers.namesNewWorkspaces)
        #expect(!offers.tabNames)
        #expect(!offers.renameAgent)
        #expect(!offers.takeOver)
        #expect(!offers.chat)
        #expect(!offers.uploads)
        #expect(offers.composerSend)
        #expect(offers.worktrees)
        #expect([host].offeringNewItem(listsTerminals: false, capabilities: { store.capabilities(for: $0.id) }) == [host])
        #expect([host].offeringNewItem(listsTerminals: true, capabilities: { store.capabilities(for: $0.id) }) == [host])
        await #expect(throws: TransportError.self) {
            try await store.renameAgent("%0", name: "renamed", on: host.id)
        }
        store.setHosts([])
    }

    // MARK: No server, an old tmux, no tmux

    @Test func aHostWithNoServerKeepsAskingOnOneConnectionAndConnectsOnceOneStarts() async throws {
        let tmux = ScriptedTmuxHost(sockets: [])
        let console = await started(tmux)
        let store = console.store

        try await waitUntil("no server to read") { isNotRunning(store.hostStatuses[host.id]) }
        #expect(store.hostStandingFailures[host.id] == nil)
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        // The login shell is asked once, then only the stored paths.
        try await waitUntil("a few more asks") { console.dials.value == 1 }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
        let log = await tmux.log
        #expect(log.filter { $0 == "probe login" }.count == 1)
        #expect(!log.contains("close"))
        #expect(console.dials.value == 1)

        await tmux.startServer()

        try await waitUntil("the started server") { store.hostStatuses[host.id] == .connected }
        #expect(console.dials.value == 1)
        store.setHosts([])
    }

    @Test func aServerThatStopsReadsNotRunningUntilItIsBack() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        await tmux.stopServer()
        try await waitUntil("the stopped server") { isNotRunning(store.hostStatuses[host.id]) }
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await tmux.startServer(instance: TmuxServerInstance(pid: 9001, startTime: 1_800_000_000))
        try await waitUntil("the new server") { store.hostStatuses[host.id] == .connected }
        #expect(store.tmuxServer(on: host.id)?.instance == TmuxServerInstance(pid: 9001, startTime: 1_800_000_000))
        store.setHosts([])
    }

    @Test func aServerReplacedBetweenTwoAsksIsAnotherServer() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.tmuxServer(on: host.id) != nil }
        #expect(store.tmuxServer(on: host.id)?.instance == ScriptedTmuxHost.instance)

        let next = TmuxServerInstance(pid: 77, startTime: 1_800_000_500)
        await tmux.startServer(instance: next)

        try await waitUntil("the other server") { store.tmuxServer(on: host.id)?.instance == next }
        #expect(store.hostStatuses[host.id] == .connected)
        store.setHosts([])
    }

    @Test func anOldTmuxStopsAtUpdateRequiredWithItsVersion() async throws {
        let tmux = ScriptedTmuxHost(version: "tmux 3.2a")
        let console = await started(tmux)
        let store = console.store

        try await waitUntil("the old tmux") { store.hostStatuses[host.id] == .failed(.tmuxUpdateRequired(version: "3.2a")) }

        #expect(store.hostStandingFailures[host.id] == .tmuxUpdateRequired(version: "3.2a"))
        let row = HostRowPresentation(
            host: host, status: store.hostStatuses[host.id],
            standingFailure: store.hostStandingFailures[host.id], latency: nil)
        #expect(row.detail == "Update required")
        #expect(row.group == .cannotConnect)
        store.setHosts([])
    }

    @Test func aHostWithoutTmuxStopsAtNotInstalledAndARetryFindsOneInstalledSince() async throws {
        let tmux = ScriptedTmuxHost(executable: nil)
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("no tmux") { store.hostStatuses[host.id] == .failed(.tmuxNotInstalled) }

        await tmux.moveExecutable(to: "/usr/local/bin/tmux")
        await store.retryHost(host.id)

        try await waitUntil("the installed tmux") { store.hostStatuses[host.id] == .connected }
        #expect(store.tmuxServer(on: host.id)?.paths.executable == "/usr/local/bin/tmux")
        store.setHosts([])
    }

    @Test func eachStateReadsInTheHostsList() {
        let notRunning = HostRowPresentation(
            host: host,
            status: .reconnecting(
                attempt: 3, delay: .seconds(4), failure: .tmuxServerNotRunning(socketName: "default")),
            standingFailure: nil, latency: nil)
        #expect(notRunning.detail.contains("No tmux server running"))
        #expect(notRunning.serverKind == "tmux")

        let missing = HostRowPresentation(
            host: host, status: .failed(.tmuxNotInstalled), standingFailure: .tmuxNotInstalled, latency: nil)
        #expect(missing.detail == "tmux is not installed")

        var named = host
        named.sessionName = "work"
        let connected = HostRowPresentation(
            host: named, status: .connected, standingFailure: nil, latency: .milliseconds(12))
        #expect(connected.detail.hasSuffix("socket work"))
        let unnamed = HostRowPresentation(
            host: host, status: .connected, standingFailure: nil, latency: .milliseconds(12))
        #expect(unnamed.detail == host.connectionSummary)
    }

    // MARK: Paths

    @Test func pathsAConnectionResolvesGoToTheCatalogAndCostNoReconnect() async throws {
        let tmux = ScriptedTmuxHost()
        var bare = host
        bare.tmuxPaths = nil
        let console = await started(tmux, host: bare)
        let store = console.store

        try await waitUntil("the resolved paths") { !console.resolved.noted.isEmpty }
        #expect(console.resolved.noted == [ScriptedTmuxHost.paths()])
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        // The catalog stores them, and hands the Host back with them.
        store.setHosts([host])
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(console.dials.value == 1)
        #expect(store.hostStatuses[host.id] == .connected)
        #expect(console.resolved.noted.count == 1)
        store.setHosts([])
    }

    @Test func pathsHostDetailResolvedCostNoReconnectEither() async throws {
        let tmux = ScriptedTmuxHost()
        var bare = host
        bare.tmuxPaths = nil
        // Host detail's checks resolved and stored them before the Console's did.
        let console = console(over: tmux)
        console.store.setHosts([bare])
        console.store.setHosts([host])
        await console.store.resume()
        let store = console.store

        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        #expect(console.dials.value == 1)
        #expect(await tmux.log.filter { $0.hasPrefix("probe") }.allSatisfy { $0 == "probe stored" })
        #expect(console.resolved.noted.isEmpty)
        store.setHosts([])
    }

    @Test func aTmuxThatMovedIsFoundAgainAndStored() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        await tmux.moveExecutable(to: "/usr/local/bin/tmux")

        try await waitUntil("the moved tmux") { !console.resolved.noted.isEmpty }
        let moved = try #require(TmuxPaths(executable: "/usr/local/bin/tmux", socket: ScriptedTmuxHost.socketPath()))
        #expect(console.resolved.noted == [moved])
        try await waitUntil("the server's answer") { store.tmuxServer(on: host.id)?.paths == moved }
        #expect(console.dials.value == 1)
        store.setHosts([])
    }

    @Test func anotherSocketNameIsAnotherConnection() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["default", "work"])
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        var renamed = host
        renamed.sessionName = "work"
        store.setHosts([renamed])

        try await waitUntil("the other socket's server") {
            store.tmuxServer(on: host.id)?.paths == ScriptedTmuxHost.paths("work")
        }
        #expect(console.dials.value == 2)
        store.setHosts([])
    }

    // MARK: Lifecycle

    @Test func suspendingClosesTheConnectionAndResumingDialsAgain() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        await store.suspend()
        try await waitUntil("the suspension") { store.hostStatuses[host.id] == .suspended }
        #expect(await tmux.log.last == "close")
        #expect(store.tmuxServer(on: host.id) == nil)

        await store.resume()
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }
        #expect(console.dials.value == 2)
        store.setHosts([])
    }

    @Test func aConnectionThatFailsIsRetriedAndOneThatCannotWorkStops() async throws {
        let failures = Mutex<[TransportError]>([.sshUnreachable(detail: "refused"), .authenticationFailed])
        let store = ConsoleStore(
            makeTmuxSession: { _ in
                TmuxHostSession(
                    storedPaths: nil,
                    connect: { _ in
                        throw failures.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: nil)
            })
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the failure that cannot be retried") {
            store.hostStatuses[host.id] == .failed(.authenticationFailed)
        }
        #expect(store.hostStandingFailures[host.id] == .authenticationFailed)
        store.setHosts([])
    }

    // MARK: Host integrations

    @Test func aTmuxHostJoinsUsageAccountsAndLiveActivities() throws {
        #expect(ServerKind.tmux.hasHostIntegrations)
        #expect(ServerKind.herdrTUI.hasHostIntegrations)
        #expect(ServerKind.herdrCore.hasHostIntegrations)
        #expect(!ServerKind.unconfirmed.hasHostIntegrations)

        let suite = "tmux-console-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let tui = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        try catalog.add(tui)
        var added = Host(address: "mac.example", username: "dev", serverKind: .unconfirmed)
        try catalog.add(added)
        added = try catalog.confirmServerKind(.tmux, for: added.id)

        #expect(catalog.consoleHosts.map(\.id) == [tui.id, added.id])
        #expect(catalog.integratedHosts.map(\.id) == [tui.id, added.id])
        #expect(catalog.supportsLiveActivities(for: added.id))
        #expect(catalog.supportsLiveActivities(for: tui.id))
    }

    @Test func hostDetailFollowsTheConsoleReadingTheServer() {
        typealias Follow = HostOnboardingCoreFollow
        let notRunning = EventsSessionStatus.reconnecting(
            attempt: 2, delay: .seconds(2), failure: .tmuxServerNotRunning(socketName: "default"))
        #expect(Follow.reading(notRunning) == .notRunning)

        func action(_ reading: Follow.Reading, passed: Bool, waits: Bool) -> Follow.Action {
            Follow.action(
                afterConsoleReads: reading, serverKind: .tmux, phase: .finished, coreStart: .idle,
                reportPassed: passed, offersStart: waits)
        }
        // Checks that passed read a server that has since stopped.
        #expect(action(.notRunning, passed: true, waits: false) == .runChecks)
        // Checks that found no server read one that has since started.
        #expect(action(.connected, passed: false, waits: true) == .runChecks)
        #expect(action(.connected, passed: true, waits: false) == .none)
        #expect(action(.notRunning, passed: false, waits: true) == .none)
    }

    // MARK: Unknown status explanations and Grok Build's edit

    @Test func unknownAgentsExplainTheirStatusAndOfferGrokBuildsEdit() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, processID: 900, command: "codex", hasPipe: true, pipeMark: "", arguments: ["codex"]),
            .make(pane: 1, processID: 1000, command: "grok", arguments: ["grok"]),
            .make(
                pane: 2, processID: 1100, command: "claude",
                status: "state=idle:app=claude-code:turn=1:blocked=0", arguments: ["claude"]),
        ])
        await tmux.setProcessEnvironment([:], forProcess: 1000, name: "zsh")
        await tmux.setProcessEnvironment(["GROK_HOME": "/opt/grok"], forProcess: 2000, name: "grok", parent: 1000)

        let console = await started(tmux)
        let store = console.store
        defer { store.setHosts([]) }
        try await waitUntil("the server's inventory") { !store.hostsAwaitingSnapshot.contains(host.id) }

        let pipedID = ConsoleAgent.ID(hostID: host.id, paneID: "%0")
        let grokID = ConsoleAgent.ID(hostID: host.id, paneID: "%1")
        let claudeID = ConsoleAgent.ID(hostID: host.id, paneID: "%2")

        let piped = try #require(store.coreStatusExplanations[pipedID])
        #expect(
            piped.text
                == "Codex has no status because this Pane already has a pipe-pane of your own, which Heeler leaves alone.")
        #expect(!piped.offersGrokBuildEdit)
        #expect(store.grokBuildEditFlow(for: piped, on: host.id) == nil)
        #expect(store.coreStatusExplanations[claudeID] == nil)

        let grok = try #require(store.coreStatusExplanations[grokID])
        #expect(grok.offersGrokBuildEdit)
        let flow = try #require(store.grokBuildEditFlow(for: grok, on: host.id))

        await flow.review()
        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)")
            return
        }
        #expect(change.path == "/opt/grok/config.toml")
        #expect(await tmux.hostFiles["/opt/grok/config.toml"] == nil)

        await flow.accept()
        #expect(
            await tmux.hostFiles["/opt/grok/config.toml"]
                == Data("[ui.notifications]\nprogram_status = \"on\"\n".utf8))
        let applied = try #require(store.harnessEdits.edits(on: host.id).first)
        #expect(applied.path == "/opt/grok/config.toml")

        await store.harnessEditFlow(for: applied, on: host.id).undo()
        #expect(await tmux.hostFiles["/opt/grok/config.toml"] == nil)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)

        await tmux.changePanes { panes in
            panes[1].status = "state=idle:app=grok-build:turn=0:blocked=0"
        }
        try await waitUntil("Grok Build's reported status") {
            store.coreStatusExplanations[grokID] == nil
        }
    }

    @Test func grokBuildsEditReadsDefaultHomeOrRefusesWhenEnvironmentCannotBeRead() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, processID: 1200, command: "grok", arguments: ["grok"]),
            .make(pane: 1, processID: 1300, command: "grok", arguments: ["grok"]),
        ])
        await tmux.setProcessEnvironment([:], forProcess: 1200, name: "grok")
        // In `%1`, Grok Build exited back to zsh before the user reviewed the edit.
        await tmux.setProcessEnvironment([:], forProcess: 1300, name: "zsh")

        let console = await started(tmux)
        let store = console.store
        defer { store.setHosts([]) }
        try await waitUntil("the server's inventory") { !store.hostsAwaitingSnapshot.contains(host.id) }

        let directFlow = store.grokBuildEditFlow(on: host.id, process: 1200)
        await directFlow.review()
        guard case .review(let directChange) = directFlow.phase else {
            Issue.record("expected a review, got \(directFlow.phase)")
            return
        }
        #expect(directChange.path == "\(ScriptedTmuxHost.home)/.grok/config.toml")

        let exitedFlow = store.grokBuildEditFlow(on: host.id, process: 1300)
        await exitedFlow.review()
        #expect(
            exitedFlow.phase
                == .failed(
                    "Heeler couldn't read this Agent's environment, so it can't tell which file to change. Nothing was written."))

        await tmux.makeProcessEnvironmentUnavailable(forProcess: 1200)
        let unreadableFlow = store.grokBuildEditFlow(on: host.id, process: 1200)
        await unreadableFlow.review()
        #expect(
            unreadableFlow.phase
                == .failed(
                    "Heeler couldn't read this Agent's environment, so it can't tell which file to change. Nothing was written."))
        #expect(await tmux.hostFiles.isEmpty)
    }

    @Test func resolvingMovedTmuxPathsUpdatesStoredHelperPathsOnlyWherePresent() async throws {
        let movedPaths = try #require(
            TmuxPaths(executable: "/usr/local/bin/tmux", socket: ScriptedTmuxHost.socketPath("default")))
        let pathsFile = "\(ScriptedTmuxHost.home)/Library/Application Support/heeler/host-helper/tmux/default/paths.json"

        // Without the Helper or placed hooks, resolving moved paths writes nothing.
        let cleanTmux = ScriptedTmuxHost()
        await cleanTmux.moveExecutable(to: "/usr/local/bin/tmux")
        let cleanConsole = await started(cleanTmux)
        defer { cleanConsole.store.setHosts([]) }
        try await waitUntil("the moved paths in the catalog") {
            cleanConsole.resolved.noted == [movedPaths]
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cleanTmux.helper.files[pathsFile] == nil)

        // With the Helper installed, resolving moved paths updates `paths.json`.
        let helperTmux = ScriptedTmuxHost()
        await helperTmux.helper.installApp()
        await helperTmux.moveExecutable(to: "/usr/local/bin/tmux")
        let helperConsole = await started(helperTmux)
        defer { helperConsole.store.setHosts([]) }
        for _ in 0..<500 {
            if await helperTmux.helper.files[pathsFile]?.contents == TmuxClaudeCodeHooks.storedPaths(movedPaths) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await helperTmux.helper.files[pathsFile]?.contents == TmuxClaudeCodeHooks.storedPaths(movedPaths))
    }
}
