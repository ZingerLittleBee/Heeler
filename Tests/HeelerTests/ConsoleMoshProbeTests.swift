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
}
