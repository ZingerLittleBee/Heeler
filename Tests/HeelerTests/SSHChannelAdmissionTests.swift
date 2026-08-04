import Foundation
import Testing

@testable import Heeler

@Suite("SSH channel admission")
struct SSHChannelAdmissionTests {
    @Test func productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling() async throws {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.ordinaryForwarding == 8)
        #expect(limits.events == 1)
        #expect(limits.ordinarySession == 8)
        #expect(limits.attach == 1)
        #expect(limits.connection == 18)
        #expect(limits.ordinarySession + limits.attach < 10)

        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<limits.ordinarySession {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let attach = try await admission.acquire(.attach)
        #expect(await admission.snapshot().ordinarySession == 8)
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().connection == 9)
        await attach.release()
        for session in sessions {
            await session.release()
        }
    }

    @Test func sessionSaturationDoesNotBlockForwardingAdmission() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 4))
        let session = try await admission.acquire(.ordinarySession)
        let forwarding = try await admission.acquire(.ordinaryForwarding)

        #expect(await admission.snapshot() == .init(
            ordinaryForwarding: 1,
            events: 0,
            ordinarySession: 1,
            attach: 0,
            connection: 2))
        await forwarding.release()
        await session.release()
    }

    @Test func connectionCeilingBoundsForwardingAndSessionTogether() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 2,
                events: 1,
                ordinarySession: 2,
                attach: 1,
                connection: 2))
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        let session = try await admission.acquire(.ordinarySession)
        let entered = ChannelAdmissionGate()
        let waiting = Task {
            let events = try await admission.acquire(.events)
            await entered.open()
            await events.release()
        }

        await Task.yield()
        #expect(await admission.snapshot().connection == 2)
        await forwarding.release()
        await entered.waitUntilOpen()
        try await waiting.value
        await session.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func cancelledWaiterDoesNotLeakConnectionCapacity() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 1))
        let session = try await admission.acquire(.ordinarySession)
        let waiting = Task { try await admission.acquire(.ordinaryForwarding) }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiting.value
        }

        await session.release()
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        #expect(await admission.snapshot().connection == 1)
        await forwarding.release()
        #expect(await admission.snapshot().connection == 0)
    }
}

private actor ChannelAdmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }
}
