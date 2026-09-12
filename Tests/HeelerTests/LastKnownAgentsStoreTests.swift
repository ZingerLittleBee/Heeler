import Foundation
import Testing

@testable import Heeler

/// Last-known Agent cache (#237): per-Host persistence, the 500-row cap,
/// fails-closed corrupt/version-mismatch loads, and the Console projection
/// rules (stale only where no live Agents; live data wins; empty-state only
/// when both are empty).
@MainActor
@Suite("Last-known agents")
struct LastKnownAgentsStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-last-known-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        hostID: UUID,
        hostName: String,
        paneID: String,
        status: AgentStatus = .working
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: hostName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: "Proj",
            repositoryCheckout: nil)
    }

    private func cachedRows(_ agents: [ConsoleAgent]) -> [LastKnownAgentsStore.CachedAgent] {
        agents.map(LastKnownAgentsStore.CachedAgent.init(from:))
    }

    @Test func replaceRoundTripsRowsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let agents = [
            consoleAgent(hostID: hostID, hostName: "alpha", paneID: "w1:p1"),
            consoleAgent(hostID: hostID, hostName: "alpha", paneID: "w1:p2", status: .idle),
        ]

        let store = LastKnownAgentsStore(defaults: defaults)
        store.replace(hostID: hostID, hostName: "alpha", rows: cachedRows(agents))

        let reloaded = LastKnownAgentsStore(defaults: defaults)
        let rows = try #require(reloaded.agentsByHost[hostID])
        #expect(rows.map(\.paneID).sorted() == ["w1:p1", "w1:p2"])
        #expect(rows.allSatisfy { $0.hostName == "alpha" })
    }

    @Test func emptyReplaceClearsTheHostEntry() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = LastKnownAgentsStore(defaults: defaults)
        let agents = [consoleAgent(hostID: hostID, hostName: "alpha", paneID: "w1:p1")]
        store.replace(hostID: hostID, hostName: "alpha", rows: cachedRows(agents))
        #expect(store.agentsByHost[hostID] != nil)

        store.replace(hostID: hostID, hostName: "alpha", rows: [])
        #expect(store.agentsByHost[hostID] == nil)
    }

    @Test func replaceCapsRowsPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = LastKnownAgentsStore(defaults: defaults)
        let agents = (0..<600).map { index in
            consoleAgent(
                hostID: hostID, hostName: "alpha", paneID: "w1:p\(index)")
        }
        store.replace(hostID: hostID, hostName: "alpha", rows: cachedRows(agents))
        #expect(store.agentsByHost[hostID]?.count == 500)
    }

    @Test func removeHostsDropsEntriesOutsideTheCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let kept = UUID()
        let dropped = UUID()
        let store = LastKnownAgentsStore(defaults: defaults)
        store.replace(
            hostID: kept, hostName: "kept",
            rows: cachedRows([consoleAgent(hostID: kept, hostName: "kept", paneID: "w1:p1")]))
        store.replace(
            hostID: dropped, hostName: "dropped",
            rows: cachedRows(
                [consoleAgent(hostID: dropped, hostName: "dropped", paneID: "w1:p1")]))

        store.removeHosts(notIn: [kept])
        #expect(store.agentsByHost[kept] != nil)
        #expect(store.agentsByHost[dropped] == nil)
    }

    @Test func corruptBlobLoadsEmpty() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(
            "not a cache blob".data(using: .utf8),
            forKey: LastKnownAgentsStore.defaultsKey)
        #expect(LastKnownAgentsStore(defaults: defaults).agentsByHost.isEmpty)
    }

    @Test func corruptBlobForOneKeyLoadsEmpty() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(
            Data([0x00, 0x01, 0x02, 0x03]),
            forKey: LastKnownAgentsStore.defaultsKey)
        #expect(LastKnownAgentsStore(defaults: defaults).agentsByHost.isEmpty)
    }

    @Test func versionMismatchLoadsEmpty() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let blob = try JSONSerialization.data(
            withJSONObject: ["version": 9999, "hosts": []])
        defaults.set(blob, forKey: LastKnownAgentsStore.defaultsKey)
        #expect(LastKnownAgentsStore(defaults: defaults).agentsByHost.isEmpty)
    }

    @Test func surfaceStaysOnRowsWhileStaleRowsRemain() {
        let staleOnly = ConsoleAgentsSurface(
            hostCount: 1,
            filteredHostName: nil,
            filteredAgentCount: 0,
            visibleIssueCount: 0,
            staleAgentCount: 2)
        #expect(staleOnly == .rows)

        let bothEmpty = ConsoleAgentsSurface(
            hostCount: 1,
            filteredHostName: nil,
            filteredAgentCount: 0,
            visibleIssueCount: 0,
            staleAgentCount: 0)
        #expect(bothEmpty == .noAgents)
    }

    /// Cold launch: the catalog is set before any snapshot arrives, so the
    /// cached row shows as stale; the authoritative empty snapshot then
    /// clears it (warm launch heals on refresh) instead of leaving a stale
    /// row beside "No Agents". `.connected` arrives before that snapshot
    /// (see `HostConsoleProjection.isAwaitingSnapshot`), so the heal is
    /// asserted only once the first snapshot has been applied.
    @Test func staleShowsBeforeSyncAndHealsOnEmptySnapshot() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha", address: "a.example")
        let stale = consoleAgent(
            hostID: host.id, hostName: "alpha", paneID: "w1:p1")
        let lastKnown = LastKnownAgentsStore(defaults: defaults)
        lastKnown.replace(hostID: host.id, hostName: "alpha", rows: cachedRows([stale]))

        let empty = ScriptedTransport(snapshot: .fixture())
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            lastKnown: lastKnown
        ) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { empty },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        store.setHosts([host])
        #expect(store.agents.isEmpty)
        #expect(store.staleAgentsByHost[host.id]?.map(\.paneID) == ["w1:p1"])

        await store.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if !store.hostsAwaitingSnapshot.contains(host.id) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.hostStatuses[host.id] == .connected)
        #expect(!store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.agents.isEmpty)
        #expect(store.staleAgentsByHost.isEmpty)
        store.setHosts([])
    }

    /// Live data wins: once the Host's snapshot carries Agents, the whole
    /// cached row set for that Host is hidden.
    @Test func liveAgentsSuppressTheStaleCache() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha", address: "a.example")
        let stale = consoleAgent(
            hostID: host.id, hostName: "alpha", paneID: "w1:cold")
        let lastKnown = LastKnownAgentsStore(defaults: defaults)
        lastKnown.replace(hostID: host.id, hostName: "alpha", rows: cachedRows([stale]))

        let live = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:live", status: .working)],
                workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            lastKnown: lastKnown
        ) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { live },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        store.setHosts([host])
        await store.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if store.agents.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.agents.map(\.agent.paneID) == ["w1:live"])
        #expect(store.staleAgentsByHost.isEmpty)
        store.setHosts([])
    }
}
