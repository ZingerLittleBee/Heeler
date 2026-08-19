import Foundation
import Observation
import Synchronization
import Testing

@testable import Heeler

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
    /// transport; unknown Hosts fail the connect. Pins default to an isolated
    /// suite so leftover `UserDefaults.standard` data cannot reorder the list.
    private func makeStore(
        transports: [Host.ID: ScriptedTransport],
        reconnectPolicy: ReconnectPolicy = Self.fastPolicy,
        pins: PinnedAgentsStore? = nil
    ) -> ConsoleStore {
        let resolvedPins =
            pins
            ?? PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "hm-console-pins-\(UUID().uuidString)")
                    ?? .standard)
        return ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), pins: resolvedPins
        ) { host, subscriptions in
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

    private func consoleAgent(
        hostID: UUID,
        hostName: String,
        paneID: String,
        status: AgentStatus,
        workspaceLabel: String? = "Proj"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: hostName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: workspaceLabel,
            repoName: nil)
    }

    private func makePinDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
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

    @Test func sortBucketsRankBlockedThenDoneThenWorkingThenIdle() {
        #expect(AgentStatus.blocked.consoleSortBucket < AgentStatus.done.consoleSortBucket)
        #expect(AgentStatus.done.consoleSortBucket < AgentStatus.working.consoleSortBucket)
        #expect(AgentStatus.working.consoleSortBucket < AgentStatus.idle.consoleSortBucket)
        #expect(AgentStatus.idle.consoleSortBucket < AgentStatus.unknown.consoleSortBucket)
        // herdr's API has no stability guarantee: a status this build does
        // not recognize must land in the bottom bucket, not on top.
        #expect(
            AgentStatus(rawValue: "haunted").consoleSortBucket
                == AgentStatus.unknown.consoleSortBucket)
    }

    @Test func consoleSortedPutsPinnedAgentsFirstByRank() {
        let hostA = UUID()
        let hostB = UUID()
        let idle = consoleAgent(
            hostID: hostA, hostName: "alpha", paneID: "w1:p1", status: .idle)
        let working = consoleAgent(
            hostID: hostA, hostName: "alpha", paneID: "w1:p2", status: .working)
        let blocked = consoleAgent(
            hostID: hostB, hostName: "beta", paneID: "w2:p1", status: .blocked)
        let done = consoleAgent(
            hostID: hostB, hostName: "beta", paneID: "w2:p2", status: .done)
        let agents = [idle, working, blocked, done]
        // Unpinned order is blocked > done > working > idle.
        #expect(agents.consoleSorted().map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])

        // idle pinned first (rank 1), working pinned more recently (rank 0).
        // Unpinned blocked/done keep their relative order.
        let ranks: [ConsoleAgent.ID: Int] = [idle.id: 1, working.id: 0]
        #expect(
            agents.consoleSorted { ranks[$0.id] }.map(\.agent.paneID)
                == ["w1:p2", "w1:p1", "w2:p1", "w2:p2"])
    }

    @Test func consoleSortedLeavesUnpinnedTiebreaksUnchanged() {
        let hostA = UUID()
        let hostB = UUID()
        // Same status: Host name, then host id, then workspace, then pane id.
        let laterName = consoleAgent(
            hostID: hostA, hostName: "zeta", paneID: "w1:p1", status: .working)
        let earlierName = consoleAgent(
            hostID: hostB, hostName: "alpha", paneID: "w2:p1", status: .working)
        let unpinned = [laterName, earlierName].consoleSorted()
        #expect(unpinned.map(\.agent.paneID) == ["w2:p1", "w1:p1"])

        let ranks: [ConsoleAgent.ID: Int] = [laterName.id: 0]
        let pinned = [laterName, earlierName].consoleSorted { ranks[$0.id] }
        #expect(pinned.map(\.agent.paneID) == ["w1:p1", "w2:p1"])
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

        // Blocked > Done > Working > Idle, flat across both Hosts.
        #expect(store.agents.map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])
        #expect(store.agents.first?.hostName == "beta")
        // Workspace rides along as a context tag.
        #expect(store.agents.first?.workspaceLabel == "Api")
        #expect(store.agents[1].workspaceLabel == "Api")
        #expect(store.agents.last?.repoName == "proj")

        store.setHosts([])
    }

    @Test func togglePinResortsThePublishedListImmediately() async throws {
        let (defaults, cleanup) = try makePinDefaults()
        defer { cleanup() }
        let pins = PinnedAgentsStore(defaults: defaults)
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w1:p1", status: .idle),
                        .fixture(paneID: "w1:p2", status: .working),
                    ],
                    workspaces: [.fixture(workspaceID: "w1", label: "Proj")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w2:p1", status: .blocked, workspaceID: "w2"),
                        .fixture(paneID: "w2:p2", status: .done, workspaceID: "w2"),
                    ],
                    workspaces: [.fixture(workspaceID: "w2", label: "Api")])),
        ]
        let store = makeStore(transports: transports, pins: pins)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("all four agents should arrive") { store.agents.count == 4 }
        #expect(store.agents.map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])

        // Pin the idle agent first, then the working one: working is rank 0.
        store.togglePin(hostID: hostA.id, paneID: "w1:p1")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1", "w2:p1", "w2:p2", "w1:p2"])

        store.togglePin(hostID: hostA.id, paneID: "w1:p2")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p2", "w1:p1", "w2:p1", "w2:p2"])

        store.togglePin(hostID: hostA.id, paneID: "w1:p2")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1", "w2:p1", "w2:p2", "w1:p2"])

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

    @Test func disconnectDuringInitialSnapshotConvergesFromAFreshSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }
        #expect(store.agents.isEmpty)

        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.failEventStream(.channelFailed(detail: "test ordering barrier"))
        try await waitUntil("the Host should disconnect before the stale snapshot returns") {
            guard case .reconnecting = store.hostStatuses[host.id] else { return false }
            return true
        }
        #expect(store.agents.isEmpty)

        await snapshotGate.open()
        try await waitUntil("the reconnect should apply a fresh snapshot") {
            store.hostStatuses[host.id] == .connected
                && store.agents.first?.agent.status == .blocked
        }

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

    @Test func disconnectedHostRemovesItsStaleAgentsImmediately() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial agent should arrive") { store.agents.count == 1 }

        await transport.failEventStream(.channelFailed(detail: "Host went offline"))
        try await waitUntil("the Host should report its disconnected state") {
            guard case .reconnecting = store.hostStatuses[host.id] else { return false }
            return true
        }

        #expect(store.agents.isEmpty)

        store.setHosts([])
    }

    @Test func staleSnapshotCannotRestoreAgentsAfterTheHostDisconnects() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial snapshot cycle should settle") {
            await transport.snapshotFetchCount >= 2
        }

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("the stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }

        await transport.failEventStream(.channelFailed(detail: "Host went offline"))
        try await waitUntil("the Host should report its disconnected state") {
            guard case .reconnecting = store.hostStatuses[host.id] else { return false }
            return true
        }
        await snapshotGate.open()
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.agents.isEmpty)

        store.setHosts([])
    }

    @Test func unknownAgentStatusResnapshotsAndRemovesAReleasedAgent() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        await transport.setSnapshot(.fixture())
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .unknown))
                == true)

        try await waitUntil(
            "the exited Agent should disappear through a fresh snapshot",
            timeout: .seconds(1)
        ) {
            store.agents.isEmpty
        }

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
        let pickerRefreshObserved = Mutex(false)
        withObservationTracking {
            _ = store.workspaces(for: host.id)
        } onChange: {
            pickerRefreshObserved.withLock { $0 = true }
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
        #expect(pickerRefreshObserved.withLock { $0 })

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

    @Test func terminalRunnerOpensTheHostsLiveTransport() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await transport.attachRequests == [request])

        let missing = store.terminalRunner(for: UUID())
        await #expect(throws: TransportError.self) {
            try await missing(request, TerminalSessionHandler { _ in })
        }

        store.setHosts([])
    }

    @Test func terminalRunnerWaitsForPreviousTerminalTeardown() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        let gate = TerminalTeardownGate()
        let result = TerminalOperationResult()
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let first = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await gate.waitUntilOpen()
                })
        }
        try await waitUntil("the first terminal should open") {
            await transport.attachRequests.count == 1
        }
        let second = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await result.set()
                })
        }

        try await waitUntil("the previous teardown should start") {
            await gate.enteredCount == 1
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !result.wasSet)
        #expect(await transport.attachRequests.count == 1)

        await gate.open()
        try await first.value
        try await second.value
        #expect(await result.wasSet)
        #expect(await transport.attachRequests.count == 2)

        store.setHosts([])
    }

    @Test func cancellingQueuedTerminalDoesNotLeakExclusiveAccess() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        let gate = TerminalTeardownGate()
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let first = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await gate.waitUntilOpen()
                })
        }
        try await waitUntil("the first terminal should open") {
            await transport.attachRequests.count == 1
        }

        let cancelled = Task {
            try await runner(request, TerminalSessionHandler { _ in })
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await gate.open()
        try await first.value
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await transport.attachRequests.count == 2)

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

    @Test func availableAgentKindsUseTheSelectedHostsLiveTransport() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport()
        await transport.setAvailableAgentKinds([.codex, .opencode])
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let kinds = try await store.availableAgentKinds(on: host.id)
        #expect(kinds == [.codex, .opencode])
        #expect(await transport.agentDiscoveryCount == 1)

        store.setHosts([])
    }

    @Test func availableAgentKindsRejectAnUnknownHost() async {
        let store = makeStore(transports: [:])

        await #expect(throws: TransportError.self) {
            _ = try await store.availableAgentKinds(on: UUID())
        }
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

    @Test func startAgentInNewWorktreeForwardsTheSpecAndResnapshots() async throws {
        // The fresh-worktree launch (#97) rides the same machinery: the
        // request/spec pair reaches the Host's transport, and the started
        // pane surfaces via one explicit resync.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let snapshotsBefore = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "wt1:pnew", status: .working, workspaceID: "wt1")]))
        let started = try await store.startAgentInNewWorktree(
            AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"),
            worktree: WorktreeSpec(branch: "task/fix-97", base: "origin/main"),
            on: host.id)

        #expect(started.workspaceID == "wt1")
        let starts = await transport.worktreeStarts
        #expect(starts.map { $0.request.workspaceID } == ["w1"])
        #expect(
            starts.map { $0.worktree }
                == [WorktreeSpec(branch: "task/fix-97", base: "origin/main")])
        try await waitUntil("the resync should surface the new pane") {
            store.agents.map(\.agent.paneID) == ["wt1:pnew"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func waitForAgentReturnsOnceTheResyncSurfacesThePane() async throws {
        // The new-agent flow opens the started pane's terminal; the wait
        // bridges the gap between the start RPC and the resync that makes
        // the Console row exist.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:pnew", status: .working)]))
        _ = try await store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "w1"), on: host.id)
        await store.waitForAgent(ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew"))

        #expect(store.agents.map(\.agent.paneID) == ["w1:pnew"])

        store.setHosts([])
    }

    @Test func waitForAgentGivesUpAfterItsTimeout() async {
        let store = makeStore(transports: [:])
        let ghost = ConsoleAgent.ID(hostID: Host.fixture().id, paneID: "w1:ghost")

        // Never reported; the wait must return on its own rather than hang.
        await store.waitForAgent(ghost, timeout: .milliseconds(120))

        #expect(store.agents.isEmpty)
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

    @Test func renameAgentForwardsItsParamsAndResnapshots() async throws {
        // agent.rename (#98): the params reach the Host's transport, and the
        // new name lands via one explicit resync — pane.updated is not a
        // resync trigger (it fires on every terminal-title change), so the
        // post-RPC resync is what surfaces the rename.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }
        let snapshotsBefore = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle, name: "reviewer")]))
        try await store.renameAgent("w1:p1", name: "reviewer", on: host.id)

        let renames = await transport.agentRenames
        #expect(renames == [AgentRenameParams(target: "w1:p1", name: "reviewer")])
        try await waitUntil("the resync should surface the new name") {
            store.agents.map(\.agent.displayName) == ["reviewer"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func renameAgentForwardsANilNameAsTheClear() async throws {
        // A nil name clears the custom name back to the detected kind
        // (verified live against herdr 0.7.5); the transport must see the
        // nil, not an empty string.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle, name: "reviewer")
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") {
            store.agents.map(\.agent.displayName) == ["reviewer"]
        }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        try await store.renameAgent("w1:p1", name: nil, on: host.id)

        let renames = await transport.agentRenames
        #expect(renames == [AgentRenameParams(target: "w1:p1", name: nil)])
        try await waitUntil("the resync should fall back to the detected kind") {
            store.agents.map(\.agent.displayName) == ["claude"]
        }

        store.setHosts([])
    }

    @Test func renameWorkspaceForwardsItsParamsAndResnapshots() async throws {
        // workspace.rename (#98): the params reach the Host's transport and
        // the relabeled workspace lands via one explicit resync rather than
        // waiting on the workspace.renamed membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(workspaces: [.fixture(workspaceID: "w1", label: "Old")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the workspace should arrive") {
            store.workspaces(for: host.id).map(\.label) == ["Old"]
        }

        await transport.setSnapshot(
            .fixture(workspaces: [.fixture(workspaceID: "w1", label: "New")]))
        try await store.renameWorkspace("w1", label: "New", on: host.id)

        let renames = await transport.workspaceRenames
        #expect(renames == [WorkspaceRenameParams(label: "New", workspaceID: "w1")])
        try await waitUntil("the resync should surface the new label") {
            store.workspaces(for: host.id).map(\.label) == ["New"]
        }

        store.setHosts([])
    }

    @Test func renamesThrowWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        await #expect(throws: TransportError.self) {
            try await store.renameAgent("w1:p1", name: "x", on: host.id)
        }
        await #expect(throws: TransportError.self) {
            try await store.renameWorkspace("w1", label: "x", on: host.id)
        }
    }

    @Test func renameFailurePropagatesAndLeavesTheAgentsUntouched() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        await transport.setRenameFailure(.timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await store.renameAgent("w1:p1", name: "x", on: host.id)
        }
        #expect(store.agents.map(\.agent.displayName) == ["claude"])
        #expect(await transport.agentRenames.isEmpty)

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
        try await waitUntil("the Host should publish its ping latency") {
            store.hostLatencies[host.id] != nil
        }

        await store.suspend()
        try await waitUntil("the Host should report suspended") {
            store.hostStatuses[host.id] == .suspended
        }

        store.setHosts([])
        #expect(store.hostLatencies.isEmpty)
    }

    @Test func resumedHostStaysLoadingUntilItsReplacementSnapshotLands() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial Agent should arrive") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
        }
        #expect(!store.hostsAwaitingSnapshot.contains(host.id))

        await store.suspend()
        try await waitUntil("suspension should invalidate the old snapshot") {
            store.hostStatuses[host.id] == .suspended && store.agents.isEmpty
        }
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await store.resume()
        try await waitUntil("the replacement snapshot should be in flight") {
            let snapshotEntered = await snapshotGate.entryCount == 1
            return store.hostStatuses[host.id] == .connected && snapshotEntered
        }

        #expect(store.agents.isEmpty)
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await snapshotGate.open()
        try await waitUntil("the replacement snapshot should restore the Agent") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }

        store.setHosts([])
    }

    @Test func retryHostReconnectsOnlyTheRequestedFailedHost() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transportA = ScriptedTransport(snapshot: .fixture())
        let transportB = ScriptedTransport(snapshot: .fixture())
        let queues = [
            hostA.id: ConnectionAttemptQueue([
                .failure(.authenticationFailed),
                .success(transportA),
            ]),
            hostB.id: ConnectionAttemptQueue([
                .failure(.authenticationFailed),
                .success(transportB),
            ]),
        ]
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = queues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both Hosts should stop on authentication failure") {
            store.hostStatuses[hostA.id] == .failed(.authenticationFailed)
                && store.hostStatuses[hostB.id] == .failed(.authenticationFailed)
        }

        await store.retryHost(hostA.id)
        try await waitUntil("only the requested Host should reconnect") {
            store.hostStatuses[hostA.id] == .connected
        }

        #expect(store.hostStatuses[hostB.id] == .failed(.authenticationFailed))
        #expect(await queues[hostA.id]?.attemptCount == 2)
        #expect(await queues[hostB.id]?.attemptCount == 1)
        #expect(await transportB.capturedSubscriptions.isEmpty)

        store.setHosts([])
    }

    @Test func retryHostRestartsOnlyTheRequestedConnectedHost() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let queues = [
            hostA.id: ConnectionAttemptQueue([
                .success(ScriptedTransport(snapshot: .fixture())),
                .success(ScriptedTransport(snapshot: .fixture())),
            ]),
            hostB.id: ConnectionAttemptQueue([
                .success(ScriptedTransport(snapshot: .fixture())),
            ]),
        ]
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = queues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both Hosts should connect") {
            store.hostStatuses[hostA.id] == .connected
                && store.hostStatuses[hostB.id] == .connected
        }

        await store.retryHost(hostA.id)
        try await waitUntil("the requested Host should start a new connection") {
            await queues[hostA.id]?.attemptCount == 2
        }

        #expect(await queues[hostB.id]?.attemptCount == 1)

        store.setHosts([])
    }

    @Test func eventChannelReconnectReusesHostConnectionGeneration() async throws {
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
        try await waitUntil("the event channel should reconnect on the same transport") {
            let subscriptions = await transport.capturedSubscriptions
            return subscriptions.count >= 3
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

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

    /// A store whose session factory hands each Host the next transport in
    /// its scripted sequence, so tests can drive SSH-level replacement.
    private func makeStore(transportQueues: [Host.ID: TransportQueue]) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = transportQueues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    @Test func transportReplacementAdvancesHostConnectionGeneration() async throws {
        // The one path that must advance the projected generation: the SSH
        // connection dies and the session installs a replacement Transport.
        // This is the detail screen's only automatic-reattach trigger.
        let host = Host.fixture()
        let first = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let second = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(
            transportQueues: [host.id: TransportQueue([first, second])])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first transport should connect") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        // Kill the SSH connection outright: the stream ends and
        // `isConnected` flips false, so the reconnect must replace the
        // Transport instead of resubscribing on it.
        try await first.close()
        try await waitUntil("the replacement transport should connect") {
            let resubscribed = await second.capturedSubscriptions.isEmpty == false
            return resubscribed && store.hostStatuses[host.id] == .connected
        }
        try await waitUntil("the projected generation should advance") {
            store.hostConnectionGenerations[host.id] == 1
        }

        store.setHosts([])
    }

    @Test func terminalRunnerAndImageStagerSurviveAHostEdit() async throws {
        // The Attach screen holds its runner and stager for its whole
        // lifetime. Editing the Host replaces the projection and ends its
        // session; a call through the old handles must resolve the live
        // projection instead of staying bound to the ended session.
        let host = Host.fixture(name: "alpha")
        let first = ScriptedTransport(snapshot: .fixture())
        let second = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(
            transportQueues: [host.id: TransportQueue([first, second])])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first transport should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let runner = store.terminalRunner(for: host.id)
        let stager = store.imageStager(for: host.id)

        var edited = host
        edited.name = "alpha (renamed)"
        store.setHosts([edited])
        try await waitUntil("the replacement projection should connect") {
            let resubscribed = await second.capturedSubscriptions.isEmpty == false
            return resubscribed && store.hostStatuses[host.id] == .connected
        }

        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await second.attachRequests == [request])
        #expect(await first.attachRequests.isEmpty)

        let prepared = PreparedImage(
            fileURL: URL(fileURLWithPath: "/tmp/attach-test.jpg"),
            format: .jpeg, pixelWidth: 16, pixelHeight: 16, byteCount: 128)
        await second.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/tmp/staged/attach-test.jpg"))])
        let staged = try await stager(prepared, AttachmentStageProgressReporter { _ in })
        #expect(staged.path == "/tmp/staged/attach-test.jpg")
        #expect(await second.stageRequests.count == 1)
        #expect(await first.stageRequests.isEmpty)

        store.setHosts([])
    }
}

/// Hands out scripted transports in order, one per `connect`, so tests can
/// drive SSH-level replacement deterministically.
private actor TransportQueue {
    private var remaining: [ScriptedTransport]

    init(_ transports: [ScriptedTransport]) {
        remaining = transports
    }

    func next() throws -> ScriptedTransport {
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "transport queue exhausted")
        }
        return remaining.removeFirst()
    }
}

/// Scripts both failed and successful connection attempts for manual retry
/// tests while recording exactly which Host was retried.
private actor ConnectionAttemptQueue {
    private var remaining: [Result<ScriptedTransport, TransportError>]
    private(set) var attemptCount = 0

    init(_ attempts: [Result<ScriptedTransport, TransportError>]) {
        remaining = attempts
    }

    func next() throws -> ScriptedTransport {
        attemptCount += 1
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "connection queue exhausted")
        }
        return try remaining.removeFirst().get()
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

private actor TerminalOperationResult {
    private(set) var wasSet = false

    func set() {
        wasSet = true
    }
}
