import Foundation
import Testing

@testable import HerdrMobile

/// Console state store (#8) against scripted transports: snapshot-then-delta
/// sync, Blocked-first sorting, membership resyncs, and snippets — protocol
/// level, no SSH.
@MainActor
@Suite("Console store")
struct ConsoleStoreTests {
    /// Reconnect fast so resync tests never wait on real backoff.
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    /// A store whose session factory routes each Host to its scripted
    /// transport; unknown Hosts fail the connect.
    private func makeStore(transports: [Host.ID: ScriptedTransport]) -> ConsoleStore {
        ConsoleStore { host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func sortBucketsRankBlockedAboveWorkingAboveTheRest() {
        #expect(AgentStatus.blocked.consoleSortBucket < AgentStatus.working.consoleSortBucket)
        #expect(AgentStatus.working.consoleSortBucket < AgentStatus.idle.consoleSortBucket)
        #expect(AgentStatus.idle.consoleSortBucket == AgentStatus.done.consoleSortBucket)
        // herdr's API has no stability guarantee: a status this build does
        // not recognize must land in the bottom bucket, not on top.
        #expect(
            AgentStatus(rawValue: "haunted").consoleSortBucket
                == AgentStatus.unknown.consoleSortBucket)
    }

    @Test func snapshotsAcrossHostsFlattenIntoOneStatusSortedList() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w1:p1", status: .idle),
                        .fixture(paneID: "w1:p2", status: .working),
                    ],
                    workspaces: [.fixture(workspaceID: "w1", label: "Proj", repoName: "proj")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w2:p1", status: .blocked, workspaceID: "w2"),
                        .fixture(paneID: "w2:p2", status: .done, workspaceID: "w2"),
                    ],
                    workspaces: [.fixture(workspaceID: "w2", label: "Api")])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("all four agents should arrive") { store.agents.count == 4 }

        // Blocked > Working > Idle/Done, flat across both Hosts.
        #expect(store.agents.map(\.agent.paneID) == ["w2:p1", "w1:p2", "w1:p1", "w2:p2"])
        #expect(store.agents.first?.hostName == "beta")
        // Workspace rides along as a context tag.
        #expect(store.agents.first?.workspaceLabel == "Api")
        #expect(store.agents.last?.workspaceLabel == "Api")
        #expect(store.agents[2].repoName == "proj")

        store.setHosts([])
    }

    @Test func unrecognizedStatusSortsIntoTheBottomBucket() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: AgentStatus(rawValue: "haunted")),
                .fixture(paneID: "w1:p2", status: .working),
                .fixture(paneID: "w1:p3", status: .unknown),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("agents should arrive") { store.agents.count == 3 }

        #expect(store.agents.first?.agent.paneID == "w1:p2")
        #expect(
            store.agents.dropFirst().map(\.agent.status)
                == [AgentStatus(rawValue: "haunted"), .unknown])

        store.setHosts([])
    }

    @Test func blockedStatusChangeSurfacesToTheTopWithinOneSecond() async throws {
        // The #8 acceptance criterion: two Hosts connected, a Blocked agent
        // reaches the top of the list within 1s of its status event.
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w2:p1", status: .idle)])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        // Wait out the pane-subscription resubscribe so the emit hits the
        // live stream that actually carries the pane subscription.
        try await waitUntil("pane subscription should be live") {
            await transports[hostB.id]?.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w2:p1")) == true
        }

        let start = ContinuousClock.now
        let emitted = await transports[hostB.id]?.emit(
            .agentStatusChanged(paneID: "w2:p1", status: .blocked))
        #expect(emitted == true)
        try await waitUntil("the Blocked agent should surface to the top") {
            store.agents.first?.agent.paneID == "w2:p1"
                && store.agents.first?.agent.status == .blocked
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "took \(elapsed)")

        store.setHosts([])
    }

    @Test func snapshotPushesPaneSubscriptionsIntoTheSession() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2"),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("resubscribe with pane ids should happen") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        let sets = await transport.capturedSubscriptions
        // First subscribe knows no panes; the post-snapshot one carries both.
        #expect(sets.first?.contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == false)
        #expect(sets.last?.contains(.pane(.agentStatusChanged, paneID: "w1:p2")) == true)
        #expect(sets.last?.contains(.global(.paneAgentDetected)) == true)

        store.setHosts([])
    }

    @Test func droppedStreamResyncsFromAFreshSnapshot() async throws {
        // Snapshot-then-delta resync: state changed while the stream was
        // down must arrive via the re-snapshot, not be waited for as events.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("initial agent should arrive") { store.agents.count == 1 }

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .blocked),
                .fixture(paneID: "w1:p9", status: .working),
            ]))
        await transport.failEventStream(.channelFailed(detail: "stream died"))

        try await waitUntil("the resync should deliver the new snapshot") {
            store.agents.map(\.agent.paneID) == ["w1:p1", "w1:p9"]
        }
        #expect(store.agents.first?.agent.status == .blocked)

        store.setHosts([])
    }

    @Test func membershipEventTriggersAResnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("initial agent should arrive") { store.agents.count == 1 }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        await transport.emit(
            HerdrEvent(
                kind: GlobalEventKind.paneAgentDetected.kind,
                data: .object(["pane_id": .string("w1:p2")])))

        try await waitUntil("the detected agent should appear via re-snapshot") {
            store.agents.count == 2
        }

        store.setHosts([])
    }

    @Test func cardsCarryTheLastOutputSnippet() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.setPaneText(
            "\n› Allow Claude to run rm -rf?\n\n  1. Yes  2. No\n", paneID: "w1:p1")
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snippet should land on the card") {
            store.agents.first?.lastOutputSnippet == "1. Yes  2. No"
        }
        let params = try #require(await transport.paneReadParams.first)
        #expect(params.source == .recent)
        #expect(params.stripANSI == true)

        store.setHosts([])
    }

    @Test func removingAHostDropsItsAgentsAndEndsItsSession() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w2:p1")])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }

        store.setHosts([hostA])

        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(store.hostStatuses[hostB.id] == nil)
        try await waitUntil("the removed Host's transport should close") {
            await transports[hostB.id]?.isClosed == true
        }

        store.setHosts([])
    }

    @Test func transportProviderHandsOutTheHostsLiveTransport() async throws {
        // The Agent detail screen (#9) runs its backfill and live-follow
        // through the Host's events-session transport, re-queried per use.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let provider = store.transportProvider(for: host.id)
        #expect(await provider() as? ScriptedTransport === transport)
        let missing = await store.transportProvider(for: UUID())()
        #expect(missing == nil)

        store.setHosts([])
    }

    @Test func workspacesExposeTheHostsSnapshotWorkspaces() async throws {
        // The new-agent picker (#12) offers the workspaces the store already
        // knows for a Host, including ones with no agents in them yet.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1", workspaceID: "w1")],
                workspaces: [
                    .fixture(workspaceID: "w2", label: "Api"),
                    .fixture(workspaceID: "w1", label: "Proj"),
                ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snapshot's workspaces should land") {
            store.workspaces(for: host.id).count == 2
        }

        // Sorted by label; a Host the store never saw offers none.
        #expect(store.workspaces(for: host.id).map(\.label) == ["Api", "Proj"])
        #expect(store.workspaces(for: host.id).map(\.id) == ["w2", "w1"])
        #expect(store.workspaces(for: UUID()).isEmpty)

        store.setHosts([])
    }

    @Test func startAgentForwardsItsParamsAndResnapshots() async throws {
        // agent.start (#12): the params reach the Host's transport, and the
        // started pane surfaces via one explicit resync rather than waiting
        // on the membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial agent should arrive") { store.agents.count == 1 }
        let snapshotsBefore = await transport.snapshotFetchCount

        // The started pane joins the next snapshot the server would report.
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:pnew", status: .working),
            ]))
        let started = try await store.startAgent(
            AgentStartParams(argv: ["claude"], name: "claude", workspaceID: "w1"), on: host.id)

        #expect(started.status == .working)
        let starts = await transport.agentStarts
        #expect(starts.map(\.argv) == [["claude"]])
        #expect(starts.first?.workspaceID == "w1")
        try await waitUntil("the resync should surface the new pane") {
            store.agents.map(\.agent.paneID) == ["w1:pnew", "w1:p1"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func startAgentThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        // No feed for this Host at all: nothing to start against.
        await #expect(throws: TransportError.self) {
            try await store.startAgent(
                AgentStartParams(argv: ["claude"], name: "claude"), on: host.id)
        }
    }

    @Test func closePaneForwardsItsTargetAndResnapshots() async throws {
        // pane.close (#13, User Story 9): the target reaches the Host's
        // transport, and the removed pane disappears via one explicit resync
        // rather than waiting on the pane.closed membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .idle),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        let snapshotsBefore = await transport.snapshotFetchCount

        // The closed pane is gone from the next snapshot the server reports.
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        try await store.closePane("w1:p2", on: host.id)

        let closed = await transport.closedPanes
        #expect(closed.map(\.paneID) == ["w1:p2"])
        try await waitUntil("the resync should drop the closed pane") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func closePaneThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        // No feed for this Host at all: nothing to close against.
        await #expect(throws: TransportError.self) {
            try await store.closePane("w1:p1", on: host.id)
        }
    }

    @Test func closePaneFailureLeavesTheAgentsUntouched() async throws {
        // The cancel/failure path must never mutate the list: a rejected
        // close propagates and leaves every agent in place.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        await transport.setCloseFailure(.timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await store.closePane("w1:p1", on: host.id)
        }
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(await transport.closedPanes.isEmpty)

        store.setHosts([])
    }

    @Test func hostStatusesExposeStalenessPerHost() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should report connected") {
            store.hostStatuses[host.id] == .connected
        }

        await store.suspend()
        try await waitUntil("the Host should report suspended") {
            store.hostStatuses[host.id] == .suspended
        }

        store.setHosts([])
    }
}
