import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A tmux Host in the Console, through `ConsoleStore` and the real tmux
/// transport over a scripted Host: its connection states, the paths it
/// resolves, and that it offers nothing yet. `TmuxInventoryConsoleTests`
/// covers what it lists.
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
        #expect(await tmux.log.allSatisfy { $0 == "probe stored" })
        #expect(console.resolved.noted.isEmpty)
        store.setHosts([])
    }

    @Test func aTmuxHostOffersNothingYet() async throws {
        let tmux = ScriptedTmuxHost()
        let console = await started(tmux)
        let store = console.store
        try await waitUntil("the server's answer") { store.hostStatuses[host.id] == .connected }

        let offers = store.capabilities(for: host.id)
        #expect(!offers.startsAgents)
        #expect(!offers.startsTerminals)
        #expect(!offers.chat)
        #expect(!offers.uploads)
        #expect(!offers.composerSend)
        #expect(!offers.worktrees)
        #expect(!offers.closeTab)
        #expect(!offers.takeOver)
        #expect([host].offeringNewItem(listsTerminals: false, capabilities: { store.capabilities(for: $0.id) }).isEmpty)
        #expect([host].offeringNewItem(listsTerminals: true, capabilities: { store.capabilities(for: $0.id) }).isEmpty)
        await #expect(throws: TransportError.self) {
            try await store.startAgent(
                AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$1", cwd: "/work"), on: host.id)
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
        #expect(await tmux.log.allSatisfy { $0 == "probe stored" })
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

    // MARK: What a tmux Host has no part in yet

    @Test func aTmuxHostHasNoIntegrationsToShowYet() throws {
        #expect(!ServerKind.tmux.hasHostIntegrations)
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
        #expect(catalog.integratedHosts.map(\.id) == [tui.id])
        #expect(!catalog.supportsLiveActivities(for: added.id))
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
}
