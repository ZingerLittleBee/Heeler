import Foundation
import Testing

@testable import Heeler

/// The Console's mosh probe: one probe per connection generation, cached
/// through reconnects, failures cached as unavailable. Kept in its own
/// suite so it can run in isolation from the store's snapshot retry
/// suites.
@MainActor
@Suite("Console mosh probe")
private struct ConsoleMoshProbeTests {
    /// Reconnect fast so the probe generation never waits on real backoff.
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private func makeStore(
        transports: [Host.ID: ScriptedTransport]
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

    @Test func probeRunsOncePerConnectionAndCachesAvailability() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        await transport.setMoshProbeAvailable(true)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        let generation = store.hostConnectionGenerations[host.id]
        try await waitUntil("the probe outcome should land") {
            store.moshProbe(for: host.id)?.available == true
        }
        #expect(store.moshProbe(for: host.id)?.generation == generation)

        // Allow any duplicate probe to surface before counting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.moshProbeCount == 1)

        store.setHosts([])
    }

    @Test func aFailedProbeCachesUnavailable() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        await transport.setMoshProbeFailure(
            TransportError.channelFailed(detail: "probe failed"))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        let generation = store.hostConnectionGenerations[host.id]
        try await waitUntil("the failed probe outcome should land") {
            store.moshProbe(for: host.id)?.available == false
        }
        #expect(store.moshProbe(for: host.id)?.generation == generation)
        #expect(
            !store.moshAvailability(
                for: host.id, generation: store.hostConnectionGenerations[host.id] ?? 0))

        store.setHosts([])
    }

    /// `invalidateMosh` marks the current generation unavailable immediately
    /// — the runner reads SSH — and the generation's own background probe
    /// cannot re-mark it available afterwards.
    @Test func invalidationMarksTheCurrentGenerationUnavailable() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        await transport.setMoshProbeAvailable(true)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the probe outcome should land") {
            store.moshProbe(for: host.id)?.available == true
        }

        store.invalidateMosh(for: host.id)
        let generation = store.hostConnectionGenerations[host.id] ?? 0
        #expect(!store.moshAvailability(for: host.id, generation: generation))

        // A slow probe completing after the invalidation must not flip the
        // Host back to mosh-available within the same generation.
        await transport.setMoshProbeAvailable(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.moshProbe(for: host.id)?.available == false)
        #expect(store.moshProbe(for: host.id)?.generation == generation)

        store.setHosts([])
    }

    // MARK: host capsule

    /// Acquires one live SSH Agent terminal on the connected Host, the way
    /// the Console detail does.
    private func connectLiveAgent(
        host: Host, transport: ScriptedTransport, store: ConsoleStore
    ) async throws -> AgentTerminalCache.Entry {
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Agent should appear") { store.agents.count == 1 }
        let agent = try #require(store.agents.first)
        let entry = store.agentTerminals.acquire(
            agent: agent, console: store,
            composer: store.composerStore(for: agent), ownerID: UUID())
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
        try await waitUntil("the session should paint live") {
            entry.attach.terminalStatus == .live
        }
        return entry
    }

    /// The capsule tap re-probes mosh and, because it is available,
    /// restarts the Host's live SSH session so the runner picks mosh.
    @Test func capsuleTapReprobesAndUpgradesTheHostsLiveSSHSessions() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setMoshProbeAvailable(true)
        let store = makeStore(transports: [host.id: transport])
        let entry = try await connectLiveAgent(
            host: host, transport: transport, store: store)
        #expect(entry.attach.lastSessionFlavor == .ssh)
        #expect(await transport.attachRequests.count == 1)
        try await waitUntil("the capsule should read available") {
            store.moshCapsuleState(for: host.id) == .available
        }

        await store.forceMoshReprobe(for: host.id)
        try await waitUntil("the live SSH session should have restarted for mosh") {
            await transport.attachRequests.count == 2
        }
        try await waitUntil("the restarted attach should open") {
            await transport.hasLiveAttachSession
        }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
        try await waitUntil("the restarted session should be live again") {
            entry.attach.terminalStatus == .live
        }
        #expect(store.moshCapsuleState(for: host.id) == .available)
        // One connect-time probe, one forced re-probe.
        #expect(await transport.moshProbeCount == 2)

        store.setHosts([])
        await store.agentTerminals.suspend()
    }

    /// A failed forced probe records unavailable and leaves the live SSH
    /// session running — the SSH fallback is silent by design.
    @Test func failedCapsuleReprobeRecordsUnavailableWithoutUpgrading() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setMoshProbeAvailable(true)
        let store = makeStore(transports: [host.id: transport])
        _ = try await connectLiveAgent(host: host, transport: transport, store: store)
        try await waitUntil("the capsule should read available") {
            store.moshCapsuleState(for: host.id) == .available
        }

        await transport.setMoshProbeFailure(
            TransportError.channelFailed(detail: "probe failed"))
        await store.forceMoshReprobe(for: host.id)
        try await waitUntil("the failed re-probe should land as unavailable") {
            store.moshCapsuleState(for: host.id) == .unavailable
        }
        #expect(await transport.attachRequests.count == 1)
        #expect(store.moshProbe(for: host.id)?.available == false)

        store.setHosts([])
        await store.agentTerminals.suspend()
    }

    /// The capsule shows the in-flight re-probe, and a tap on an offline
    /// Host is a graceful no-op.
    @Test func capsuleShowsTestingInFlightAndNoOpsOffline() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let gate = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: gate)
        let store = makeStore(transports: [host.id: transport])

        // Offline: no connection to probe over.
        #expect(store.moshCapsuleState(for: host.id) == .untested)
        await store.forceMoshReprobe(for: host.id)
        #expect(store.moshCapsuleState(for: host.id) == .untested)
        #expect(await transport.moshProbeCount == 0)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the connect-time probe should reach the gate") {
            await gate.entryCount >= 1
        }
        await store.forceMoshReprobe(for: host.id)
        try await waitUntil("the capsule should show the in-flight re-probe") {
            store.moshCapsuleState(for: host.id) == .testing
        }
        await gate.open()
        try await waitUntil("the re-probe outcome should land") {
            store.moshCapsuleState(for: host.id) == .unavailable
        }

        store.setHosts([])
    }
}
