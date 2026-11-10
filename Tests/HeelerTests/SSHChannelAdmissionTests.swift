import Foundation
import Testing

@testable import Heeler

@Suite("SSH channel admission")
struct SSHChannelAdmissionTests {
    @Test func windowsExecBackendsShareNineSessionSlots() async throws {
        let admission = SSHChannelAdmission()
        await admission.useWindowsSessionBudget()
        var leases: [SSHChannelAdmissionLease] = []
        for _ in 0..<5 { leases.append(try await admission.acquire(.attach)) }
        leases.append(try await admission.acquire(.events))
        for _ in 0..<3 { leases.append(try await admission.acquire(.ordinarySession)) }
        #expect(await admission.snapshot().connection == 9)
        let waiting = Task { try await admission.acquire(.ordinarySession) }
        await Task.yield()
        #expect(await admission.snapshot().connection == 9)
        await leases.removeLast().release()
        let next = try await waiting.value
        #expect(await admission.snapshot().connection == 9)
        await next.release()
        for lease in leases { await lease.release() }
        #expect(await admission.snapshot().connection == 0)
    }

    /// A forwarded channel takes no SSH session slot, so a core link has no
    /// exec budget: it is the one long-lived channel, as Herdr TUI's events are.
    @Test func aCoreLinkHoldsTheEventsSlotUntilItsChannelCloses() async throws {
        let admission = SSHChannelAdmission()
        let channel = try await admission.admitCoreLink { FakeCoreSocket() }
        #expect(await admission.snapshot() == .init(
            ordinaryForwarding: 0, events: 1, ordinarySession: 0, attach: 0, connection: 1))

        let next = Task { try await admission.admitCoreLink { FakeCoreSocket() } }
        await Task.yield()
        #expect(await admission.snapshot().events == 1)

        try await channel.close(timeout: .seconds(1))
        let second = try await next.value
        #expect(await admission.snapshot().events == 1)
        try await second.close(timeout: .seconds(1))
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func aCoreLinkThatCannotOpenGivesItsSlotBack() async {
        let admission = SSHChannelAdmission()
        await #expect(throws: TransportError.streamLocalOpenFailed(path: "/s")) {
            try await admission.admitCoreLink { throw TransportError.streamLocalOpenFailed(path: "/s") }
        }
        #expect(await admission.snapshot().connection == 0)
    }

    /// A tmux Host's inventory loop is one long exec among the ordinary
    /// sessions (ADR 0043), which leaves three for one-shot commands.
    @Test func aLongSessionExecHoldsOneOrdinarySessionUntilItsChannelCloses() async throws {
        let admission = SSHChannelAdmission()
        let loop = try await admission.admitSessionExec { FakeCoreSocket() }
        #expect(await admission.snapshot() == .init(
            ordinaryForwarding: 0, events: 0, ordinarySession: 1, attach: 0, connection: 1))

        var commands: [SSHChannelAdmissionLease] = []
        for _ in 0..<3 { commands.append(try await admission.acquire(.ordinarySession)) }
        let waiting = Task { try await admission.acquire(.ordinarySession) }
        await Task.yield()
        #expect(await admission.snapshot().ordinarySession == 4)

        try await loop.close(timeout: .seconds(1))
        let next = try await waiting.value
        #expect(await admission.snapshot().ordinarySession == 4)
        await next.release()
        for command in commands { await command.release() }
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func aLongSessionExecThatCannotOpenGivesItsSlotBack() async {
        let admission = SSHChannelAdmission()
        await #expect(throws: TransportError.channelFailed(detail: "refused")) {
            try await admission.admitSessionExec { throw TransportError.channelFailed(detail: "refused") }
        }
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling() async throws {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.ordinaryForwarding == 8)
        #expect(limits.events == 1)
        #expect(limits.ordinarySession == 4)
        #expect(limits.attach == 5)
        // Production `connection` restates the category sum; it is not a
        // tighter live ceiling under these four budgets (#133, ADR 0011).
        #expect(
            limits.connection
                == limits.ordinaryForwarding + limits.events
                + limits.ordinarySession + limits.attach)
        // Session categories leave headroom under sshd's default MaxSessions.
        #expect(limits.ordinarySession + limits.attach < 10)

        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<limits.ordinarySession {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let attach = try await admission.acquire(.attach)
        #expect(await admission.snapshot().ordinarySession == 4)
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().connection == 5)
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
