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
        let expected = [
            "first", AgentMonitorStore.gapMarkerText, "second",
        ].joined(separator: "\n")
        try await waitUntil("one clock tick should perform one refresh") {
            guard store.snapshot.map({ String($0.characters) }) == expected else {
                return false
            }
            return await transport.agentReadParams.count == 2
        }

        #expect(store.agentStatus == .working)
        #expect(String(try #require(store.snapshot).characters) == expected)
    }

    @Test func idleAndBackgroundStatesDoNotPoll() async throws {
        let idleTransport = ScriptedTransport()
        let idleClock = ManualAgentMonitorClock()
        let idleStore = AgentMonitorStore(target: "w1:p1", clock: idleClock) { params in
            try await idleTransport.readAgent(params)
        }
        await idleStore.open()

        #expect(await idleClock.pendingSleepCount == 0)
        // One visible snapshot plus the one idle backfill on open (#181).
        #expect(await agentReads(idleTransport, source: .visible).count == 1)
        #expect(await agentReads(idleTransport, source: .recent).count == 1)

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

        // A Working Agent never backfills, so its only read is the snapshot.
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
        let workingSnapshot = [
            "idle", AgentMonitorStore.gapMarkerText, "working",
        ].joined(separator: "\n")
        try await waitUntil("Working should surface and refresh") {
            guard
                store.agentStatus == .working,
                store.snapshot.map({ String($0.characters) }) == workingSnapshot
            else { return false }
            return await agentReads(transport, source: .visible).count == 2
        }

        await transport.setAgentText("done", target: "w1:p1")
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)))
        let doneSnapshot = [
            "idle", AgentMonitorStore.gapMarkerText, "working",
            AgentMonitorStore.gapMarkerText, "done",
        ].joined(separator: "\n")
        try await waitUntil("Done should surface and refresh") {
            guard
                store.agentStatus == .done,
                store.snapshot.map({ String($0.characters) }) == doneSnapshot
            else { return false }
            return await agentReads(transport, source: .visible).count == 3
        }

        await transport.setAgentText("blocked", target: "w1:p1")
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))
        let blockedSnapshot = [
            "idle", AgentMonitorStore.gapMarkerText, "working",
            AgentMonitorStore.gapMarkerText, "done",
            AgentMonitorStore.gapMarkerText, "blocked",
        ].joined(separator: "\n")
        try await waitUntil("Blocked should surface and refresh") {
            guard
                store.agentStatus == .blocked,
                store.snapshot.map({ String($0.characters) }) == blockedSnapshot
            else { return false }
            return await agentReads(transport, source: .visible).count == 4
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
            await agentReads(transport, source: .visible) == [
                AgentReadParams(
                    source: .visible,
                    target: "w1:p1",
                    format: .ansi,
                    stripANSI: false)
            ])
        // The idle open also backfills once (#181); the scripted window
        // equals the screen, so nothing new lands and history is exhausted.
        #expect(
            await agentReads(transport, source: .recent) == [
                AgentReadParams(
                    source: .recent,
                    target: "w1:p1",
                    format: .ansi,
                    lines: AgentMonitorStore.historyLineCount,
                    stripANSI: false)
            ])
        #expect(store.historyState == .exhausted)
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
        #expect(
            String(snapshot.characters)
                == ["before", AgentMonitorStore.gapMarkerText, "after"]
                .joined(separator: "\n"))
        #expect(await agentReads(transport, source: .visible).count == 2)
    }

    @Test func returningWhileOpenIsLoadingStillPerformsTheRefresh() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("opening", target: "w1:p1")
        // The open also backfills (#181), and the gated visible read lets
        // the scripted screen move on before that backfill executes. Pin
        // the history window to the pre-Attach screen so it stitches to
        // nothing; the return refresh alone then decides the final screen.
        // (A window disjoint from the stale tail would honestly record a
        // gap — correct store behavior, but not what this test is about.)
        await transport.setAgentHistoryText("opening", target: "w1:p1")
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
        #expect(
            String(snapshot.characters)
                == ["opening", AgentMonitorStore.gapMarkerText, "after Attach"]
                .joined(separator: "\n"))
        #expect(await agentReads(transport, source: .visible).count == 2)
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
        #expect(await agentReads(transport, source: .visible).count == 2)
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

    // MARK: History backfill (#181)

    @Test func openWhileIdleBackfillsHistoryAboveTheScreen() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("screen 1\nscreen 2\nscreen 3", target: "w1:p1")
        await transport.setAgentHistoryText(
            "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()
        await store.open()

        // The window overlaps the screen by its three lines, so only the
        // older prefix is prepended; a short read ends history immediately.
        let snapshot = try #require(store.snapshot)
        #expect(
            String(snapshot.characters) == "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3")
        #expect(store.historyState == .exhausted)
        #expect(await agentReads(transport, source: .visible).count == 1)
        #expect(await agentReads(transport, source: .recent).count == 1)
    }

    @Test func openWhileWorkingSkipsBackfillAndTopEdgeStaysHonest() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("live screen", target: "w1:p1")
        let store = AgentMonitorStore(
            target: "w1:p1", initialStatus: .working
        ) { params in
            try await transport.readAgent(params)
        }

        await store.open()

        #expect(store.historyState == .unavailable)
        #expect(await transport.agentReadParams.count == 1)

        store.topEdgeReached()

        // Working never spins and never reads: the notice is the answer.
        #expect(store.historyState == .unavailable)
        #expect(await transport.agentReadParams.count == 1)
    }

    @Test func topEdgeWhileIdleShowsLoadingThenStitchesOlderLines() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("screen 1\nscreen 2\nscreen 3", target: "w1:p1")
        let store = AgentMonitorStore(
            target: "w1:p1", initialStatus: .working
        ) { params in
            try await transport.readAgent(params)
        }
        await store.open()
        #expect(store.historyState == .unavailable)

        // Going idle refreshes the screen but does not backfill on its own.
        await store.agentStatusDidChange(.idle)
        #expect(store.historyState == .idle)

        await transport.setAgentHistoryText(
            "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3", target: "w1:p1")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentRead(using: gate)
        store.topEdgeReached()
        #expect(store.historyState == .loading)
        try await waitUntil("the backfill read should be in flight") {
            await gate.entryCount == 1
        }

        await gate.open()
        try await waitUntil("the backfill should land") {
            store.historyState == .exhausted
        }

        let snapshot = try #require(store.snapshot)
        #expect(
            String(snapshot.characters) == "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3")
        #expect(await agentReads(transport, source: .recent).count == 1)
    }

    @Test func repeatBackfillAtTheCaptureLimitEndsHistory() async throws {
        let transport = ScriptedTransport()
        let screen = (998...1000).map { "line \($0)" }.joined(separator: "\n")
        let window = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        await transport.setAgentText(screen, target: "w1:p1")
        await transport.setAgentHistoryText(window, target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        // A full-window read that added lines might have more behind it.
        #expect(store.historyState == .idle)
        #expect(String(try #require(store.snapshot).characters) == window)

        // The same window comes back: nothing new, so the limit is honest.
        store.topEdgeReached()
        try await waitUntil("the confirming read should declare the limit") {
            store.historyState == .exhausted
        }
        #expect(String(try #require(store.snapshot).characters) == window)
        #expect(await agentReads(transport, source: .recent).count == 2)
    }

    @Test func unstitchableReadInsertsAnExplicitGapMarker() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("stale a\nstale b\nstale c", target: "w1:p1")
        // The server's buffer shares not one line with the cache (restarted
        // pane, cleared scrollback): no overlap, no guessing.
        await transport.setAgentHistoryText("fresh 1\nfresh 2\nfresh 3", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        let expected = [
            "fresh 1", "fresh 2", "fresh 3",
            AgentMonitorStore.gapMarkerText,
            "stale a", "stale b", "stale c",
        ].joined(separator: "\n")
        #expect(String(try #require(store.snapshot).characters) == expected)
        #expect(store.historyState == .exhausted)
    }

    @Test func agentNotIdleSurfacesAsUnavailableNeverAnError() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("live screen", target: "w1:p1")
        await transport.setAgentHistoryReadFailure(
            HerdrAPIError(code: "agent_not_idle", message: "agent is working"))
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        // The screen loaded; only history is unavailable, and honestly so.
        #expect(store.state == .loaded)
        #expect(store.historyState == .unavailable)
        #expect(String(try #require(store.snapshot).characters) == "live screen")

        // A later top-edge hit retries the read and lands the same way.
        store.topEdgeReached()
        try await waitUntil("the retried read should settle as unavailable") {
            store.historyState == .unavailable
        }
        #expect(store.state == .loaded)
        #expect(await agentReads(transport, source: .recent).count == 2)
    }

    @Test func failedBackfillSurfacesARetryableError() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("screen 1\nscreen 2\nscreen 3", target: "w1:p1")
        await transport.setAgentHistoryReadFailure(TransportError.timedOut)
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        #expect(store.state == .loaded)
        #expect(store.historyState == .failed("The Host did not answer in time."))

        await transport.setAgentHistoryReadFailure(nil)
        await transport.setAgentHistoryText(
            "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3", target: "w1:p1")
        await store.loadEarlierHistory()

        #expect(store.historyState == .exhausted)
        #expect(
            String(try #require(store.snapshot).characters)
                == "older 1\nolder 2\nscreen 1\nscreen 2\nscreen 3")
    }

    @Test func openingOnAnEmptyScreenPaintsTheEmptyState() async throws {
        let transport = ScriptedTransport()
        // No scripted text: the visible read answers "". The first install
        // must still render, or the view loads forever.
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        #expect(store.state == .loaded)
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.characters.isEmpty)
        #expect(store.historyState == .exhausted)
    }

    @Test func backfillWaitsForAnInFlightVisibleRead() async throws {
        let transport = ScriptedTransport()
        let screen = (998...1000).map { "line \($0)" }.joined(separator: "\n")
        let window = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        await transport.setAgentText(screen, target: "w1:p1")
        await transport.setAgentHistoryText(window, target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()
        #expect(store.historyState == .idle)

        // A visible read in flight (a cadence poll or pull-to-refresh) holds
        // the shared flight; the top-edge backfill must queue behind it
        // rather than interleave and risk a spurious gap.
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentRead(using: gate)
        let refreshing = Task { await store.refresh() }
        try await waitUntil("the visible read should be in flight") {
            await gate.entryCount == 1
        }
        store.topEdgeReached()
        #expect(store.historyState == .loading)
        #expect(await agentReads(transport, source: .recent).count == 1)

        await gate.open()
        await refreshing.value
        try await waitUntil("the queued backfill should run and exhaust") {
            store.historyState == .exhausted
        }

        #expect(await agentReads(transport, source: .recent).count == 2)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == window)
        #expect(!String(snapshot.characters).contains(AgentMonitorStore.gapMarkerText))
    }

    @Test func visibleReadsExtendTheLiveTailWhileWorking() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("l1\nl2\nl3\nl4\nl5", target: "w1:p1")
        let store = AgentMonitorStore(
            target: "w1:p1", initialStatus: .working
        ) { params in
            try await transport.readAgent(params)
        }
        await store.open()

        // A scrolled screen overlaps the cached tail: only fresh lines land.
        await transport.setAgentText("l2\nl3\nl4\nl5\nl6", target: "w1:p1")
        await store.refresh()
        #expect(
            String(try #require(store.snapshot).characters) == "l1\nl2\nl3\nl4\nl5\nl6")

        // A repaint shares no overlap: a new live run is installed.
        await transport.setAgentText("n1\nn2\nn3\nn4\nn5", target: "w1:p1")
        await store.refresh()
        #expect(
            String(try #require(store.snapshot).characters)
                == [
                    "l1", "l2", "l3", "l4", "l5", "l6",
                    AgentMonitorStore.gapMarkerText,
                    "n1", "n2", "n3", "n4", "n5",
                ].joined(separator: "\n"))
    }

    @Test func liveReplacementResetsExhaustionAndAllowsAnotherBackfill() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("s1\ns2\ns3\ns4", target: "w1:p1")
        await transport.setAgentHistoryText(
            "h1\nh2\nh3\nh4\nh5\nh6\ns1\ns2\ns3\ns4", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()
        #expect(store.historyState == .exhausted)

        await transport.setAgentText("r1\nr2\nr3\nr4", target: "w1:p1")
        await store.refresh()

        #expect(store.historyState == .idle)
        let preserved = [
            "h1", "h2", "h3", "h4", "h5", "h6", "s1", "s2", "s3", "s4",
            AgentMonitorStore.gapMarkerText, "r1", "r2", "r3", "r4",
        ].joined(separator: "\n")
        #expect(String(try #require(store.snapshot).characters) == preserved)

        await transport.setAgentHistoryText(
            "new older 1\nnew older 2\nr1\nr2\nr3\nr4", target: "w1:p1")
        store.topEdgeReached()
        try await waitUntil("the replacement should allow a new backfill") {
            store.historyState == .exhausted
        }

        #expect(await agentReads(transport, source: .recent).count == 2)
        #expect(
            String(try #require(store.snapshot).characters)
                == [
                    "h1", "h2", "h3", "h4", "h5", "h6", "s1", "s2", "s3", "s4",
                    AgentMonitorStore.gapMarkerText, "new older 1", "new older 2", "r1",
                    "r2", "r3", "r4",
                ].joined(separator: "\n"))
    }

    private func agentReads(
        _ transport: ScriptedTransport,
        source: ReadSource
    ) async -> [AgentReadParams] {
        await transport.agentReadParams.filter { $0.source == source }
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
