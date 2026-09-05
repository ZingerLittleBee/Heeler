import Foundation
import Observation
import Synchronization
import Testing

@testable import Heeler

@MainActor
@Suite("Sidebar Console integration", .timeLimit(.minutes(1)))
struct SidebarConsoleIntegrationTests {
    @Test func priorityUsesRecencyThenSnapshotOrderAndPinStillLeads() {
        let host = Host.fixture()
        let old = row(host, pane: "old", status: .done, order: 0, sequence: 1)
        let recent = row(host, pane: "recent", status: .done, order: 2, sequence: 7)
        let tied = row(host, pane: "tied", status: .done, order: 1, sequence: 7)
        let blocked = row(host, pane: "blocked", status: .blocked, order: 3, sequence: 0)
        let rows = [old, recent, tied, blocked]
        #expect(rows.consoleSorted(sortByHost: [host.id: .priority]).map(\.agent.paneID)
            == ["blocked", "tied", "recent", "old"])
        #expect(rows.consoleSorted(sortByHost: [host.id: .spaces]).map(\.agent.paneID)
            == ["old", "tied", "recent", "blocked"])
        #expect(rows.consoleSorted(sortByHost: [host.id: .spaces]) {
            $0.id == recent.id ? 0 : nil
        }.map(\.agent.paneID) == ["recent", "old", "tied", "blocked"])
    }

    @Test func mixedHostPoliciesHaveOneStableOrderAcrossInputPermutations() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let a0 = row(alpha, pane: "a0", status: .idle, order: 0)
        let a1 = row(alpha, pane: "a1", status: .blocked, order: 1)
        let b0 = row(beta, pane: "b0", status: .idle, order: 0)
        let b1 = row(beta, pane: "b1", status: .blocked, order: 1)
        let rows = [a0, a1, b0, b1]
        let policies: [Host.ID: AgentPanelSort] = [alpha.id: .spaces, beta.id: .priority]
        for a in rows.indices {
            for b in rows.indices where b != a {
                for c in rows.indices where c != a && c != b {
                    let d = rows.indices.first { $0 != a && $0 != b && $0 != c }!
                    let permutation = [rows[a], rows[b], rows[c], rows[d]]
                    #expect(permutation.consoleSorted(sortByHost: policies).map(\.agent.paneID)
                        == ["a0", "a1", "b1", "b0"])
                    #expect(permutation.consoleSorted(sortByHost: policies) {
                        $0.id == b0.id ? 0 : nil
                    }.map(\.agent.paneID) == ["b0", "a0", "a1", "b1"])
                }
            }
        }
    }

    @Test func consoleBorrowsConnectionsAndKeepsRowsSortAndGroupingIndependent() async throws {
        let suite = "sidebar-console-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let a = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "a0", status: .idle), .fixture(paneID: "a1", status: .blocked),
        ]))
        let b = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "b0", status: .idle), .fixture(paneID: "b1", status: .blocked),
        ]))
        await a.setSidebarLayout(snapshot(sort: "spaces"))
        await b.setSidebarLayout(snapshot(sort: "priority"))
        let connects = Mutex(0)
        let transports = [alpha.id: a, beta.id: b]
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { host, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: {
                connects.withLock { $0 += 1 }
                guard let transport = transports[host.id] else { throw TransportError.cancelled }
                return transport
            }, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([alpha, beta])
        await store.resume()
        await waitForSnapshots(store, hosts: [alpha.id, beta.id])
        #expect(store.agents.map(\.agent.paneID) == ["a0", "a1", "b1", "b0"])
        #expect(connects.withLock { $0 } == 2)
        let plugin = store.rowLayout(for: alpha.id)
        #expect(plugin.rowsByAgent["claude"] == [[.init(.terminalTitleStripped)]])
        let first = try #require(store.agents.first)
        #expect(AgentCardPresentation(agent: first, layout: plugin).headline == "Task")
        let observed = Mutex(false)
        withObservationTracking {
            _ = store.rowLayout(for: alpha.id)
        } onChange: {
            observed.withLock { $0 = true }
        }
        try store.rowLayouts.setGlobalLayout(AgentRowLayout(rows: [[.init(.agent)]]))
        #expect(observed.withLock { $0 })
        try store.rowLayouts.setLayout(AgentRowLayout(rows: []), for: alpha.id)
        #expect(store.rowLayout(for: alpha.id).rows.isEmpty)
        #expect(store.rowLayout(for: beta.id).rows == [[.init(.agent)]])
        #expect(store.agents.map(\.agent.paneID) == ["a0", "a1", "b1", "b0"])
        let switcher = TerminalAgentSwitcherItem(
            agent: first, pins: store.pins, layout: store.rowLayout(for: alpha.id))
        #expect(switcher.title == "claude")
        let presentation = ConsoleListPresentationStore(defaults: defaults)
        presentation.select(.grouped)
        #expect(presentation.sections(hosts: [alpha, beta], agents: store.agents).map { $0.agents.map(\.agent.paneID) }
            == [["a0", "a1"], ["b1", "b0"]])
        store.togglePin(hostID: beta.id, paneID: "b0")
        #expect(store.agents.first?.agent.paneID == "b0")
        await a.setSidebarLayout(snapshot(sort: "priority"))
        await store.refreshSidebarLayouts()
        #expect(store.agents.map(\.agent.paneID) == ["b0", "a1", "b1", "a0"])
        #expect(connects.withLock { $0 } == 2)
        #expect(store.rowLayout(for: alpha.id).rows.isEmpty)
    }

    @Test func consoleSuspensionRejectsAnInFlightSnapshot() async throws {
        let suite = "sidebar-suspend-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "p")]))
        await transport.setSidebarLayout(snapshot(sort: "spaces"))
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await waitForSnapshots(store, hosts: [host.id])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let refresh = Task { await store.refreshSidebarLayouts() }
        await gate.waitForEntry()
        await store.suspend()
        #expect(store.sidebarSnapshots.states.isEmpty)
        await gate.open()
        await refresh.value
        #expect(store.sidebarSnapshots.states.isEmpty)
        #expect(store.rowLayout(for: host.id) == .heelerDefault)
    }

    private func snapshot(sort: String) -> Data {
        Data("""
            {"v":1,"agent_panel_sort":"\(sort)","sidebar":{"agents":{"rows":[[{"token":"workspace"}]],"rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}}
            """.utf8)
    }

    private func row(_ host: Host, pane: String, status: AgentStatus, order: Int, sequence: Int = 0) -> ConsoleAgent {
        ConsoleAgent(hostID: host.id, hostName: host.displayName,
                     agent: Agent(terminalID: "t", kind: "claude", title: "", status: status,
                                  workspaceID: "w", tabID: "t", paneID: pane, cwd: "", revision: 1,
                                  stateChangeSeq: sequence),
                     workspaceLabel: nil, repositoryCheckout: nil, snapshotOrder: order)
    }

    /// Await actual observable publication; no sleeps, yields or polling.
    private func waitForSnapshots(_ store: ConsoleStore, hosts: [Host.ID]) async {
        while hosts.contains(where: { store.sidebarSnapshots.snapshot(for: $0) == nil }) {
            let changes = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = store.sidebarSnapshots.states
            } onChange: {
                changes.continuation.yield(())
            }
            for await _ in changes.stream { break }
            changes.continuation.finish()
        }
    }
}
