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
        await a.setSidebarLayout(try snapshot(sort: "spaces"))
        await b.setSidebarLayout(try snapshot(sort: "priority"))
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
        try await waitForSnapshots(store, hosts: [alpha.id, beta.id])
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
        await a.setSidebarLayout(try snapshot(sort: "priority"))
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
        await transport.setSidebarLayout(try snapshot(sort: "spaces"))
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        // Hold the layout store's own borrowed read; the Settings action now
        // also refreshes Agent metadata before reading the layout file.
        let refresh = Task {
            await store.sidebarSnapshots.refresh(transports: store, didChange: {})
        }
        await gate.waitForEntry()
        await store.suspend()
        #expect(store.sidebarSnapshots.states.isEmpty)
        await gate.open()
        await refresh.value
        #expect(store.sidebarSnapshots.states.isEmpty)
        #expect(store.rowLayout(for: host.id) == .heelerDefault)
    }

    @Test func statusEventsRefreshRecencyAndLiteralRowsWithOneCoalescedFollowUp() async throws {
        let suite = "sidebar-live-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let b = metadata(pane: "b", status: .done, sequence: 2, title: "Other task", note: "other")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 1, title: "Task A", note: "old"), b,
        ]))
        await transport.setSidebarLayout(try snapshot(sort: "priority"))
        let store = liveStore(defaults: defaults, connect: { transport })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await transport.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        #expect(store.agents.map(\.agent.paneID) == ["b", "a"])
        try store.rowLayouts.setGlobalLayout(.init(rows: [
            [.init(.terminalTitleStripped)], [.init(.custom("note")), .init(.terminalTitle)],
        ]))

        let firstRead = ScriptedTransportCallGate()
        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .working, sequence: 3, title: "In progress", note: "pending"), b,
        ]))
        await transport.gateNextSnapshot(using: firstRead)
        #expect(await transport.emit(.agentStatusChanged(paneID: "a", status: .working)))
        await firstRead.waitForEntry()
        let countAtEntry = await transport.snapshotFetchCount
        try await waitForConsole(store) { store.agents.first(where: { $0.agent.paneID == "a" })?.agent.status == .working }

        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 4, title: "Task B", note: "**literal** [link](url)"), b,
        ]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "a", status: .done)))
        try await waitForConsole(store) { store.agents.first(where: { $0.agent.paneID == "a" })?.agent.status == .done }
        #expect(await transport.snapshotFetchCount == countAtEntry)
        await firstRead.open()
        try await waitForConsole(store) { store.agents.first?.agent.stateChangeSeq == 4 }
        #expect(await transport.snapshotFetchCount == countAtEntry + 1)
        #expect(store.agents.map(\.agent.paneID) == ["a", "b"])
        let agent = try #require(store.agents.first)
        let layout = store.rowLayout(for: host.id)
        let card = AgentCardPresentation(agent: agent, layout: layout)
        #expect(card.headline == "Task B")
        #expect(card.additionalRows == ["**literal** [link](url) · ◑ Task B"])
        #expect(TerminalAgentSwitcherItem(agent: agent, pins: store.pins, layout: layout).title == "Task B")
        store.togglePin(hostID: host.id, paneID: "b")
        #expect(store.agents.first?.agent.paneID == "b")

        // The explicit Settings refresh also refreshes values when no event
        // has occurred, not just the layout file's field names.
        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 5, title: "Task C", note: "manual"), b,
        ]))
        await store.refreshSidebarLayouts()
        let refreshed = try #require(store.agents.first(where: { $0.agent.paneID == "a" }))
        #expect(AgentCardPresentation(agent: refreshed, layout: layout).headline == "Task C")
        #expect(store.agents.first?.agent.paneID == "b")
    }

    @Test func subscriptionsAddReorderedOnlyAfterCurrentProtocolSupport() {
        for version in [nil, 17, 18] as [Int?] {
            let subscriptions = HostConsoleProjection.subscriptions(paneIDs: ["a"], protocolVersion: version)
            #expect(!subscriptions.contains(.global(.workspaceReordered)))
            #expect(subscriptions.contains(.global(.workspaceMoved)))
            #expect(subscriptions.contains(.pane(.agentStatusChanged, paneID: "a")))
        }
        for version in [19, 20] {
            #expect(HostConsoleProjection.subscriptions(paneIDs: ["a"], protocolVersion: version)
                .contains(.global(.workspaceReordered)))
        }
    }

    @Test func workspaceOrderEventsRefreshSpacesOrderThroughTheSubscribedStream() async throws {
        let suite = "sidebar-order-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let a = AgentInfo.fixture(paneID: "a", workspaceID: "wa")
        let b = AgentInfo.fixture(paneID: "b", workspaceID: "wb")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [a, b], protocolVersion: 20))
        await transport.setSidebarLayout(try snapshot(sort: "spaces"))
        let store = liveStore(defaults: defaults, connect: { transport })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await transport.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        let subscriptions = try #require(await transport.capturedSubscriptions.last)
        #expect(subscriptions.contains(.global(.workspaceReordered)))
        #expect(subscriptions.contains(.global(.workspaceMoved)))
        #expect(!subscriptions.contains(.global(.paneUpdated)))
        for (kind, remote) in [(GlobalEventKind.workspaceReordered, [b, a]), (.workspaceMoved, [a, b])] {
            await transport.setSnapshot(.fixture(agents: remote, protocolVersion: 20))
            #expect(await transport.emit(HerdrEvent(kind: kind.kind, data: .object([:]))))
            try await waitForConsole(store) { store.agents.map(\.agent.paneID) == remote.map(\.paneID) }
            #expect(store.agents.map(\.snapshotOrder) == [0, 1])
        }
    }

    @Test func statusDrivenSnapshotFromAnOldConnectionCannotPublishMetadataAfterResume() async throws {
        let suite = "sidebar-generation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let old = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 1, title: "Initial", note: "old"),
        ]))
        let fresh = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 10, title: "Fresh", note: "new"),
        ]))
        await old.setSidebarLayout(try snapshot(sort: "priority"))
        await fresh.setSidebarLayout(try snapshot(sort: "priority"))
        let sequence = SequencedTransportConnector([old, fresh])
        let store = liveStore(defaults: defaults, connect: { try await sequence.connect() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await old.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        let generation = try #require(store.hostConnectionGenerations[host.id])
        let oldRead = ScriptedTransportCallGate()
        await old.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .working, sequence: 2, title: "Stale", note: "stale"),
        ]))
        await old.gateNextSnapshot(using: oldRead)
        #expect(await old.emit(.agentStatusChanged(paneID: "a", status: .working)))
        await oldRead.waitForEntry()
        await store.suspend()
        let freshRead = ScriptedTransportCallGate()
        await fresh.gateNextSnapshot(using: freshRead)
        await store.resume()
        try await waitForConsole(store) { (store.hostConnectionGenerations[host.id] ?? 0) > generation }
        await oldRead.open()
        await freshRead.waitForEntry()
        // Entering the next read proves the old response has crossed the
        // production epoch guard; it did not repopulate the empty projection.
        #expect(store.agents.isEmpty)
        await freshRead.open()
        try await waitForConsole(store) { store.agents.first?.agent.stateChangeSeq == 10 }
        #expect(store.agents.first?.agent.terminalTitleStripped == "Fresh")
        #expect(store.agents.first?.agent.tokens["note"] == "new")
    }

    private func liveStore(
        defaults: UserDefaults,
        connect: @escaping @Sendable () async throws -> any Transport
    ) -> ConsoleStore {
        ConsoleStore(pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)) {
            _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: connect, keepalive: nil)
        }
    }

    private func metadata(pane: String, status: AgentStatus, sequence: Int, title: String, note: String) -> AgentInfo {
        AgentInfo(agentStatus: status, focused: false, paneID: pane, revision: sequence,
                  tabID: "w:t1", terminalID: "term_\(pane)", workspaceID: "w", agent: "claude",
                  stateChangeSeq: sequence, terminalTitle: "◑ \(title)", terminalTitleStripped: title,
                  tokens: ["note": note])
    }

    private func waitForConsole(_ store: ConsoleStore, until ready: () -> Bool) async throws {
        while !ready() {
            try Task.checkCancellation()
            let changes = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = store.agents
                _ = store.hostConnectionGenerations
            } onChange: {
                changes.continuation.yield(())
            }
            var iterator = changes.stream.makeAsyncIterator()
            let change = await iterator.next()
            changes.continuation.finish()
            guard change != nil else { throw CancellationError() }
        }
    }

    private func snapshot(sort: String) throws -> Data {
        let data = Data("""
            {"v":1,"agent_panel_sort":"\(sort)","sidebar":{"agents":{"rows":[[{"token":"workspace"}]],"rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}}}
            """.utf8)
        _ = try #require(AgentRowLayoutSnapshot.decode(data))
        return data
    }

    private func row(_ host: Host, pane: String, status: AgentStatus, order: Int, sequence: Int = 0) -> ConsoleAgent {
        ConsoleAgent(hostID: host.id, hostName: host.displayName,
                     agent: Agent(terminalID: "t", kind: "claude", title: "", status: status,
                                  workspaceID: "w", tabID: "t", paneID: pane, cwd: "", revision: 1,
                                  stateChangeSeq: sequence),
                     workspaceLabel: nil, repositoryCheckout: nil, snapshotOrder: order)
    }

    /// Await terminal publication, then require a usable snapshot. Missing or
    /// invalid data is a diagnostic failure, never an unbounded success wait.
    private func waitForSnapshots(_ store: ConsoleStore, hosts: [Host.ID]) async throws {
        while hosts.contains(where: { id in
            switch store.sidebarSnapshots.states[id] {
            case nil, .loading: true
            default: false
            }
        }) {
            try Task.checkCancellation()
            let changes = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = store.sidebarSnapshots.states
            } onChange: {
                changes.continuation.yield(())
            }
            var iterator = changes.stream.makeAsyncIterator()
            let change = await iterator.next()
            changes.continuation.finish()
            guard change != nil else { throw CancellationError() }
        }
        for id in hosts {
            _ = try #require(store.sidebarSnapshots.snapshot(for: id), "Host must publish a valid sidebar fixture")
        }
    }
}
