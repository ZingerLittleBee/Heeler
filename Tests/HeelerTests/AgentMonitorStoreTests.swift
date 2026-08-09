import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Monitor store")
struct AgentMonitorStoreTests {
    @Test func workingForegroundPollsEveryInjectedClockTick() async throws {
        let transport = ScriptedTransport()
        let clock = ManualAgentMonitorClock()
        await transport.setAgentText("first", target: "w1:p1")
        let store = AgentMonitorStore(
            target: "w1:p1", initialStatus: .working, clock: clock
        ) { params in
            try await transport.readAgent(params)
        }

        await store.open()
        try await waitUntil("the cadence should be sleeping") {
            await clock.pendingSleepCount == 1
        }
        await transport.setAgentText("second", target: "w1:p1")
        #expect(await clock.advance() == .seconds(2))
        try await waitUntil("one clock tick should perform one refresh") {
            guard store.snapshot.map({ String($0.characters) }) == "second" else {
                return false
            }
            return await transport.agentReadParams.count == 2
        }

        #expect(store.agentStatus == .working)
        #expect(String(try #require(store.snapshot).characters) == "second")
    }

    @Test func idleAndBackgroundStatesDoNotPoll() async throws {
        let idleTransport = ScriptedTransport()
        let idleClock = ManualAgentMonitorClock()
        let idleStore = AgentMonitorStore(target: "w1:p1", clock: idleClock) { params in
            try await idleTransport.readAgent(params)
        }
        await idleStore.open()

        #expect(await idleClock.pendingSleepCount == 0)
        #expect(await idleTransport.agentReadParams.count == 1)

        let workingTransport = ScriptedTransport()
        let workingClock = ManualAgentMonitorClock()
        let workingStore = AgentMonitorStore(
            target: "w1:p2", initialStatus: .working, clock: workingClock
        ) { params in
            try await workingTransport.readAgent(params)
        }
        await workingStore.open()
        try await waitUntil("Working should schedule its cadence") {
            await workingClock.pendingSleepCount == 1
        }
        workingStore.setForeground(false)
        try await waitUntil("backgrounding should cancel the cadence") {
            await workingClock.pendingSleepCount == 0
        }

        #expect(await workingTransport.agentReadParams.count == 1)
    }

    @Test func scriptedStatusPushesRefreshAndSurfaceWithoutPollingTerminalStates() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        await transport.setAgentText("idle", target: "w1:p1")
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 1,
                    maxDelay: .milliseconds(10)),
                keepalive: nil)
        }
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Agent snapshot should arrive") {
            console.agents.count == 1
        }
        let id = try #require(console.agents.first?.id)
        let clock = ManualAgentMonitorClock()
        let store = AgentMonitorStore(
            target: "w1:p1",
            initialStatus: .idle,
            clock: clock,
            statusUpdates: console.agentStatusUpdates(for: id)
        ) { params in
            try await transport.readAgent(params)
        }
        await store.open()
        try await waitUntil("the pane-scoped status subscription should be live") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        await transport.setAgentText("working", target: "w1:p1")
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .working)))
        try await waitUntil("Working should surface and refresh") {
            guard
                store.agentStatus == .working,
                store.snapshot.map({ String($0.characters) }) == "working"
            else { return false }
            return await transport.agentReadParams.count == 2
        }

        await transport.setAgentText("done", target: "w1:p1")
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)))
        try await waitUntil("Done should surface and refresh") {
            guard
                store.agentStatus == .done,
                store.snapshot.map({ String($0.characters) }) == "done"
            else { return false }
            return await transport.agentReadParams.count == 3
        }

        await transport.setAgentText("blocked", target: "w1:p1")
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))
        try await waitUntil("Blocked should surface and refresh") {
            guard
                store.agentStatus == .blocked,
                store.snapshot.map({ String($0.characters) }) == "blocked"
            else { return false }
            return await transport.agentReadParams.count == 4
        }
        try await waitUntil("Blocked should cancel the cadence") {
            await clock.pendingSleepCount == 0
        }
        console.setHosts([])
    }

    @Test func eventStreamFailureSurfacesDegradationAndResubscribes() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentText("working", target: "w1:p1")
        let console = makeConsole(host: host, transport: transport)
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Agent and pane subscription should settle") {
            guard console.agents.count == 1 else { return false }
            return await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        let id = try #require(console.agents.first?.id)
        let store = AgentMonitorStore(
            target: "w1:p1",
            initialStatus: .working,
            clock: ManualAgentMonitorClock(),
            statusUpdates: console.agentStatusUpdates(for: id)
        ) { params in
            try await transport.readAgent(params)
        }
        await store.open()
        try await waitUntil("live status updates should initially be available") {
            store.liveUpdatesAvailable
        }

        let reconnectGate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: reconnectGate)
        await transport.failEventStream(.channelFailed(detail: "events stream dropped"))

        try await waitUntil("the Monitor should expose the events outage") {
            !store.liveUpdatesAvailable
        }
        let subscriptionsBeforeRecovery = await transport.capturedSubscriptions.count
        #expect(subscriptionsBeforeRecovery >= 3)

        await reconnectGate.open()
        try await waitUntil("the pane status subscription should be re-established") {
            guard store.liveUpdatesAvailable else { return false }
            return await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        console.setHosts([])
    }

    @Test func deadPaneReconnectDropsItsSubscriptionAndDegradesGracefully() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let console = makeConsole(host: host, transport: transport)
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the original pane subscription should settle") {
            guard console.agents.count == 1 else { return false }
            return await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        let id = try #require(console.agents.first?.id)
        let store = AgentMonitorStore(
            target: "w1:p1",
            initialStatus: .working,
            clock: ManualAgentMonitorClock(),
            statusUpdates: console.agentStatusUpdates(for: id)
        ) { params in
            try await transport.readAgent(params)
        }
        await store.open()
        let subscriptionsBeforeFailure = await transport.capturedSubscriptions.count

        await transport.setSnapshot(.fixture(agents: []))
        await transport.setMissingPanes(["w1:p1"])
        await transport.failEventStream(.channelFailed(detail: "connection dropped"))

        try await waitUntil("the Host should recover without the dead Agent") {
            console.hostStatuses[host.id] == .connected
                && console.agents.isEmpty
                && !store.liveUpdatesAvailable
        }
        let subscriptions = await transport.capturedSubscriptions
        let recoverySubscriptions = Array(
            subscriptions.dropFirst(subscriptionsBeforeFailure))
        #expect(!recoverySubscriptions.isEmpty)
        #expect(
            recoverySubscriptions.allSatisfy {
                !$0.contains(.pane(.agentStatusChanged, paneID: "w1:p1"))
            })

        console.setHosts([])
    }

    @Test func scrolledOutputFreezesWithPillWhilePinnedOutputFollows() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("one", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()

        store.setBottomPinned(false)
        await transport.setAgentText("two", target: "w1:p1")
        await store.refresh()
        #expect(store.hasNewOutput)
        #expect(!store.isBottomPinned)

        store.jumpToLatestOutput()
        #expect(!store.hasNewOutput)
        #expect(store.isBottomPinned)

        await transport.setAgentText("three", target: "w1:p1")
        await store.refresh()
        #expect(!store.hasNewOutput)
        #expect(store.isBottomPinned)
    }

    @Test func unchangedTextDoesNotSignalNewOutput() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("same", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()
        let initialChange = store.contentChangeCount
        store.setBottomPinned(false)

        // Scripted reads report revision 0, like herdr 0.8.0. Only text is
        // compared, so another response with the same bytes is not output.
        await store.refresh()

        #expect(store.contentChangeCount == initialChange)
        #expect(!store.hasNewOutput)
    }

    @Test func openingFetchesOneVisibleANSISnapshot() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("plain \u{1B}[31mred\u{1B}[0m", target: "w1:p1")
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AgentMonitorStore(target: "w1:p1", now: { capturedAt }) { params in
            try await transport.readAgent(params)
        }

        await store.open()
        await store.open()

        #expect(store.state == .loaded)
        #expect(store.capturedAt == capturedAt)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "plain red")
        #expect(
            await transport.agentReadParams == [
                AgentReadParams(
                    source: .visible,
                    target: "w1:p1",
                    format: .ansi,
                    stripANSI: false)
            ])
    }

    @Test func returningFromAttachRefreshesExactlyOnce() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("before", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()

        await transport.setAgentText("after", target: "w1:p1")
        store.attachDidOpen()
        await store.refreshOnReturn()
        await store.refreshOnReturn()

        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func returningWhileOpenIsLoadingStillPerformsTheRefresh() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("opening", target: "w1:p1")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentRead(using: gate)
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        let opening = Task { await store.open() }
        try await waitUntil("the opening read should be in flight") {
            await gate.entryCount == 1
        }
        await transport.setAgentText("after Attach", target: "w1:p1")
        store.attachDidOpen()
        let returning = Task { await store.refreshOnReturn() }

        await gate.open()
        await opening.value
        await returning.value

        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after Attach")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func failedOpenSurfacesTheServerErrorAndRetryRecovers() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentReadFailure(
            HerdrAPIError(code: "agent_not_idle", message: "agent is working"))
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        #expect(store.state == .failed("herdr rejected the snapshot: agent is working"))
        #expect(store.snapshot == nil)

        await transport.setAgentReadFailure(nil)
        await transport.setAgentText("recovered", target: "w1:p1")
        await store.retry()

        #expect(store.state == .loaded)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "recovered")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func failedReturnKeepsTheLastSnapshotAndItsFreshness() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("known screen", target: "w1:p1")
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AgentMonitorStore(target: "w1:p1", now: { capturedAt }) { params in
            try await transport.readAgent(params)
        }
        await store.open()

        await transport.setAgentReadFailure(TransportError.timedOut)
        store.attachDidOpen()
        await store.refreshOnReturn()

        #expect(store.state == .failed("The Host did not answer in time."))
        #expect(store.capturedAt == capturedAt)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "known screen")
    }

    @Test func sendDeliversControlKeysAndRefreshesTheSnapshot() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("before", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentText("after ctrl+c", target: "w1:p1")
        await store.send(.interrupt)

        #expect(store.sendError == nil)
        #expect(store.isSendingKey == false)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after ctrl+c")
        #expect(
            await transport.agentSendKeysParams == [
                AgentSendKeysParams(keys: ["ctrl+c"], target: "w1:p1")
            ])
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func sendFailureSurfacesWithoutRefreshing() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("known screen", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentSendKeysFailure(
            HerdrAPIError(code: "invalid_key", message: "unsupported key foo"))
        await store.send(.enter)

        #expect(store.sendError == "herdr rejected the key: unsupported key foo")
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "known screen")
        #expect(await transport.agentSendKeysParams.isEmpty)
        #expect(await transport.agentReadParams.count == 1)
    }

    @Test func successfulSendClearsAPriorSendError() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("screen", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentSendKeysFailure(TransportError.timedOut)
        await store.send(.escape)
        #expect(store.sendError == "The Host did not answer in time.")

        await transport.setAgentSendKeysFailure(nil)
        await transport.setAgentText("dismissed", target: "w1:p1")
        await store.send(.escape)

        #expect(store.sendError == nil)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "dismissed")
        #expect(
            await transport.agentSendKeysParams == [
                AgentSendKeysParams(keys: ["esc"], target: "w1:p1")
            ])
    }

    @Test func controlKeySpellingsMatchHerdrContract() {
        // Load-bearing spellings verified live on herdr 0.8.0 (CLAUDE.md):
        // enter/esc/ctrl+c accepted; ctrl-c rejected with invalid_key.
        #expect(MonitorControlKey.enter.keys == ["enter"])
        #expect(MonitorControlKey.escape.keys == ["esc"])
        #expect(MonitorControlKey.interrupt.keys == ["ctrl+c"])
        #expect(MonitorControlKey.interrupt.keys != ["ctrl-c"])
        #expect(MonitorControlKey.up.keys == ["up"])
        #expect(MonitorControlKey.down.keys == ["down"])
        #expect(MonitorControlKey.left.keys == ["left"])
        #expect(MonitorControlKey.right.keys == ["right"])

        for key in MonitorControlKey.allCases {
            #expect(!key.keys.isEmpty)
            #expect(key.keys.allSatisfy { !$0.isEmpty })
            #expect(key.label != nil || key.systemImage != nil)
            // Negative contract: herdr rejects hyphenated `ctrl-…` spellings
            // with `invalid_key` (verified live on 0.8.0); only `ctrl+c` /
            // `C-c` are accepted. Pin the whole prefix so a future key
            // (⌃D, ⌃Z, …) cannot regress into the trap.
            for spelling in key.keys {
                #expect(
                    !spelling.lowercased().hasPrefix("ctrl-"),
                    "\(key.rawValue) must not use hyphenated ctrl- form \(spelling)")
            }
        }
    }

    private func makeStore(
        transport: ScriptedTransport,
        target: String = "w1:p1",
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AgentMonitorStore {
        AgentMonitorStore(
            target: target,
            now: now,
            read: { params in try await transport.readAgent(params) },
            sendKeys: { params in try await transport.sendAgentKeys(params) })
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        #expect(await condition(), comment)
    }

    private func makeConsole(host: Host, transport: ScriptedTransport) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .zero) { requestedHost, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard requestedHost.id == host.id else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .zero, multiplier: 1, maxDelay: .zero),
                keepalive: nil)
        }
    }
}

private actor ManualAgentMonitorClock: AgentMonitorClock {
    private struct Sleeper {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var sleepers: [Sleeper] = []

    var pendingSleepCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(
                        Sleeper(id: id, duration: duration, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() -> Duration? {
        guard !sleepers.isEmpty else { return nil }
        let sleeper = sleepers.removeFirst()
        sleeper.continuation.resume()
        return sleeper.duration
    }

    private func cancel(id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
