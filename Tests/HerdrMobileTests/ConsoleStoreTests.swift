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
    private func makeStore(
        transports: [Host.ID: ScriptedTransport],
        reconnectPolicy: ReconnectPolicy = Self.fastPolicy
    ) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                reconnectPolicy: reconnectPolicy,
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

    @Test func statusChangeDuringSnapshotSurvivesTheStaleResponse() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            let paneReads = await transport.paneReadParams
            let subscriptions = await transport.capturedSubscriptions
            return paneReads.count >= 2
                && subscriptions.last?.contains(
                    .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let readsBeforeRace = await transport.paneReadParams.count
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil("the stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }

        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        try await waitUntil("the live status event should land first") {
            store.agents.first?.agent.status == .blocked
        }

        await snapshotGate.open()
        try await waitUntil("the stale snapshot response should finish applying") {
            await transport.paneReadParams.count > readsBeforeRace
        }
        #expect(store.agents.first?.agent.status == .blocked)

        store.setHosts([])
    }

    @Test func statusChangeForNewPaneDuringInitialSnapshotSurvives() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(
            transports: [host.id: transport],
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }
        #expect(store.agents.isEmpty)

        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        await transport.failEventStream(.channelFailed(detail: "test ordering barrier"))
        try await waitUntil("the status event should be consumed before the disconnect") {
            guard case .reconnecting = store.hostStatuses[host.id] else { return false }
            return true
        }

        await snapshotGate.open()
        try await waitUntil("the initial snapshot should create the Agent row") {
            store.agents.count == 1
        }
        #expect(store.agents.first?.agent.status == .blocked)

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

    @Test func forcedEventOverflowConvergesViaTheDropMarkerResync() async throws {
        // The #22 acceptance criterion: force the bounded events buffer to
        // overflow and prove the Console converges anyway. The server state
        // changes with no membership event — only ignorable noise — so the
        // drop marker's resync is the one path to the new snapshot.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let box = SessionBox()
        let store = ConsoleStore { _, subscriptions in
            let session = EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil,
                updatesBufferLimit: 2)
            Task { await box.set(session) }
            return session
        }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial agent should arrive") { store.agents.count == 1 }
        // Let the connect→snapshot→resubscribe→re-snapshot cycle settle, so
        // no in-flight resync can fetch the updated snapshot by accident.
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        try await waitUntil("the post-resubscribe resync should settle") {
            await transport.snapshotFetchCount >= 2
        }
        let session = try #require(await box.session)

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p9", status: .blocked),
            ]))
        // Flood with events the Console ignores until the bounded buffer
        // demonstrably sheds updates.
        try await waitUntil("the bounded buffer should shed updates") {
            for _ in 0..<50 {
                await transport.emit(
                    HerdrEvent(kind: PaneEventKind.scrollChanged.kind, data: .object([:])))
            }
            return await session.droppedUpdateCount > 0
        }

        try await waitUntil("the marker resync should surface the pane changed during the gap") {
            store.agents.map(\.agent.paneID) == ["w1:p9", "w1:p1"]
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

    @Test func workspaceCreationRefreshesTheNewAgentPicker() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial workspace should arrive") {
            store.workspaces(for: host.id).map(\.id) == ["w1"]
        }
        try await waitUntil("workspace creation should be subscribed") {
            await transport.capturedSubscriptions.last?.contains(.global(.workspaceCreated)) == true
        }

        await transport.setSnapshot(
            .fixture(workspaces: [
                .fixture(workspaceID: "w1", label: "Proj"),
                .fixture(workspaceID: "w2", label: "Api"),
            ]))
        await transport.emit(
            HerdrEvent(kind: GlobalEventKind.workspaceCreated.kind, data: .object([:])))

        try await waitUntil("the new workspace should appear without reconnecting") {
            store.workspaces(for: host.id).map(\.id) == ["w2", "w1"]
        }

        store.setHosts([])
    }

    @Test func snapshotFailureSurfacesAndRetriesUntilRecovery() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setSnapshotFailure(.timedOut)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the sync failure should be visible") {
            store.hostSyncErrors[host.id] != nil
        }

        await transport.setSnapshotFailure(nil)
        try await waitUntil("the retry should recover the snapshot") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
                && store.hostSyncErrors[host.id] == nil
        }
        #expect(await transport.snapshotFetchCount >= 2)

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

    @Test func blockedStatusDuringSnippetFetchSchedulesAFollowUpRead() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setPaneText("Ready", paneID: "w1:p1")
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial snapshot cycle should settle") {
            let reads = await transport.paneReadParams
            let subscriptions = await transport.capturedSubscriptions
            return reads.count >= 2
                && subscriptions.last?.contains(
                    .pane(.agentStatusChanged, paneID: "w1:p1")) == true
                && store.agents.first?.lastOutputSnippet == "Ready"
        }

        let staleReadGate = ScriptedTransportCallGate()
        await transport.setPaneText("Still working", paneID: "w1:p1")
        await transport.gateNextPaneRead(using: staleReadGate)
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .working))
                == true)
        try await waitUntil("the stale snippet read should be in flight") {
            await staleReadGate.entryCount == 1
        }

        let followUpReadGate = ScriptedTransportCallGate()
        await transport.setPaneText("Allow this command?", paneID: "w1:p1")
        await transport.gateNextPaneRead(using: followUpReadGate)
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        try await waitUntil("the Blocked status should land during the stale read") {
            store.agents.first?.agent.status == .blocked
        }
        for _ in 0..<10 { await Task.yield() }

        await staleReadGate.open()
        try await waitUntil("the Blocked refresh should start a follow-up read") {
            await followUpReadGate.entryCount == 1
        }
        await followUpReadGate.open()
        try await waitUntil("the Blocked prompt should replace the stale snippet") {
            store.agents.first?.lastOutputSnippet == "Allow this command?"
        }

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
        #expect(store.hostConnectionGenerations[hostB.id] == 0)

        store.setHosts([hostA])

        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(store.hostStatuses[hostB.id] == nil)
        #expect(store.hostConnectionGenerations[hostB.id] == nil)
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

    @Test func transportProviderWaitsForPreviousTerminalTeardown() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        let gate = TerminalTeardownGate()
        let result = TerminalTransportResult()

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        store.scheduleTerminalTeardown(for: host.id) {
            await gate.waitUntilOpen()
        }
        let provider = store.transportProvider(for: host.id)
        let request = Task {
            await result.set(await provider())
        }

        try await waitUntil("the previous teardown should start") {
            await gate.enteredCount == 1
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !result.wasSet)

        await gate.open()
        await request.value
        #expect(await result.transport as? ScriptedTransport === transport)

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
        // Agent launch (#12): the request reaches the Host's transport, and the
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
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "w1"), on: host.id)

        #expect(started.status == .working)
        let starts = await transport.agentStarts
        #expect(starts.map(\.kind) == ["claude"])
        #expect(starts.map(\.arguments) == [[]])
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
                AgentLaunchRequest(kind: "claude", name: "claude"), on: host.id)
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

    @Test func realReconnectAdvancesHostConnectionGeneration() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial subscribe cycle should settle") {
            let subscriptions = await transport.capturedSubscriptions
            return subscriptions.count >= 2
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        await transport.failEventStream(.channelFailed(detail: "connection dropped"))
        try await waitUntil("the real reconnect should advance the generation") {
            let subscriptions = await transport.capturedSubscriptions
            return subscriptions.count >= 3
                && store.hostConnectionGenerations[host.id] == 1
                && store.hostStatuses[host.id] == .connected
        }

        store.setHosts([])
    }

    @Test func subscriptionResubscribeDoesNotAdvanceConnectionGeneration() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial subscribe cycle should settle") {
            let snapshotCount = await transport.snapshotFetchCount
            let subscriptions = await transport.capturedSubscriptions
            return snapshotCount >= 2 && subscriptions.count >= 2
        }
        let snapshotsBeforeMembershipChange = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1"),
                .fixture(paneID: "w1:p2"),
            ]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil("the changed pane subscription should reconnect its event stream") {
            let subscriptions = await transport.capturedSubscriptions
            let snapshotCount = await transport.snapshotFetchCount
            return snapshotCount >= snapshotsBeforeMembershipChange + 2
                && subscriptions.last?.contains(
                    .pane(.agentStatusChanged, paneID: "w1:p2")) == true
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        store.setHosts([])
    }
}

/// Captures the session a store's factory built, so overflow tests can
/// observe its drop diagnostics.
private actor SessionBox {
    private(set) var session: EventsSession?

    func set(_ session: EventsSession) {
        self.session = session
    }
}

private actor TerminalTeardownGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func waitUntilOpen() async {
        enteredCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}

private actor TerminalTransportResult {
    private(set) var wasSet = false
    private(set) var transport: (any Transport)?

    func set(_ transport: (any Transport)?) {
        wasSet = true
        self.transport = transport
    }
}
