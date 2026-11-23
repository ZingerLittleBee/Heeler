import Darwin
import Foundation
import Testing

@testable import HeelerSSH

@Suite("Socket candidate fallback", .serialized)
struct SocketConnectorTests {
    @Test("a timed-out candidate falls back to the next address within the overall deadline")
    func timedOutCandidateFallsBackWithinOverallDeadline() async throws {
        let start = ContinuousClock.now
        let deadline = start + .seconds(12)
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.timedOut, .connected])

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: deadline,
            resolver: FixedSocketAddressResolver.twoCandidates,
            operations: fixture.operations)

        #expect(descriptor == 101)
        #expect(fixture.snapshot.openedFamilies == [AF_INET6, AF_INET])
        #expect(fixture.snapshot.waitDeadlines == [deadline, deadline])
        #expect(fixture.snapshot.closedDescriptors == [100])
        #expect(fixture.snapshot.waitDeadlines.allSatisfy { $0 <= deadline })
    }

    @Test("a blackholed first address falls back after Happy Eyeballs stagger without waiting for deadline")
    func blackholedCandidateFallsBackAfterStagger() async throws {
        let start = ContinuousClock.now
        let deadline = start + .seconds(12)
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.waitForCancellation, .connected],
            cancellationWait: CancellationWait())

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: deadline,
            resolver: FixedSocketAddressResolver.twoCandidates,
            operations: fixture.operations,
            stagger: .milliseconds(30))

        #expect(descriptor == 101)
        #expect(start.duration(to: .now) < .seconds(2))
        try await waitUntilClosed(fixture, descriptor: 100)
        #expect(fixture.snapshot.openedFamilies == [AF_INET6, AF_INET])
    }

    @Test("exhausting every candidate preserves the last connection failure without waiting for stagger")
    func allCandidatesExhausted() async {
        let start = ContinuousClock.now
        let deadline = start + .seconds(12)
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.rejected, .rejected])

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: deadline,
                resolver: FixedSocketAddressResolver.twoCandidates,
                operations: fixture.operations,
                stagger: .seconds(5))
        }

        #expect(start.duration(to: .now) < .seconds(2))
        #expect(fixture.snapshot.openedFamilies == [AF_INET6, AF_INET])
        #expect(fixture.snapshot.waitDeadlines == [deadline, deadline])
        #expect(Set(fixture.snapshot.closedDescriptors) == [100, 101])
        #expect(fixture.snapshot.waitDeadlines.allSatisfy { $0 <= deadline })
    }

    @Test("caller cancellation stops the active candidate immediately")
    func cancellationStopsWithoutTryingAnotherCandidate() async throws {
        let cancellationWait = CancellationWait()
        let fixture = ScriptedSocketFixture(
            now: ContinuousClock.now,
            outcomes: [.waitForCancellation, .connected],
            cancellationWait: cancellationWait)
        let task = Task {
            try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: ContinuousClock.now + .seconds(30),
                resolver: FixedSocketAddressResolver.twoCandidates,
                operations: fixture.operations,
                stagger: .seconds(5))
        }
        await cancellationWait.waitUntilEntered()

        task.cancel()

        await #expect(throws: SSHError.cancelled) {
            _ = try await task.value
        }
        try await waitUntilClosed(fixture, descriptor: 100)
        #expect(fixture.snapshot.openedFamilies == [AF_INET6])
        #expect(fixture.snapshot.closedDescriptors == [100])
    }

    private func waitUntilClosed(
        _ fixture: ScriptedSocketFixture, descriptor: Int32
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if fixture.snapshot.closedDescriptors.contains(descriptor) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Expected descriptor \(descriptor) to close")
    }
}

private struct FixedSocketAddressResolver: SocketAddressResolving {
    let addresses: [SocketAddress]

    static let twoCandidates = FixedSocketAddressResolver(addresses: [
        SocketAddress(
            family: AF_INET6,
            type: SOCK_STREAM,
            protocol: IPPROTO_TCP,
            bytes: Data([6])),
        SocketAddress(
            family: AF_INET,
            type: SOCK_STREAM,
            protocol: IPPROTO_TCP,
            bytes: Data([4])),
    ])

    func resolve(
        _ endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> [SocketAddress] {
        addresses
    }
}

private enum ScriptedCandidateOutcome: Sendable, Equatable {
    case timedOut
    case rejected
    case connected
    case waitForCancellation
}

private final class ScriptedSocketFixture: @unchecked Sendable {
    struct Snapshot: Equatable {
        let openedFamilies: [Int32]
        let waitDeadlines: [ContinuousClock.Instant]
        let closedDescriptors: [Int32]
    }

    private let lock = NSLock()
    private let outcomes: [ScriptedCandidateOutcome]
    private let cancellationWait: CancellationWait?
    private var currentTime: ContinuousClock.Instant
    private var openedFamilies: [Int32] = []
    private var waitDeadlines: [ContinuousClock.Instant] = []
    private var closedDescriptors: [Int32] = []

    init(
        now: ContinuousClock.Instant,
        outcomes: [ScriptedCandidateOutcome],
        cancellationWait: CancellationWait? = nil
    ) {
        currentTime = now
        self.outcomes = outcomes
        self.cancellationWait = cancellationWait
    }

    var operations: SocketConnector.Operations {
        SocketConnector.Operations(
            now: { [self] in now() },
            makeSocket: { [self] family, _, _ in openSocket(family: family) },
            setNonBlocking: { _ in true },
            beginConnection: { _, _ in .inProgress },
            waitUntilWritable: { [self] descriptor, deadline in
                try await wait(descriptor: descriptor, until: deadline)
            },
            connectionSucceeded: { [self] descriptor in
                outcome(for: descriptor) == .connected
            },
            closeSocket: { [self] descriptor in closeSocket(descriptor) })
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            openedFamilies: openedFamilies,
            waitDeadlines: waitDeadlines,
            closedDescriptors: closedDescriptors)
    }

    private func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    private func openSocket(family: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = Int32(100 + openedFamilies.count)
        openedFamilies.append(family)
        return descriptor
    }

    private func wait(
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) async throws {
        let outcome = recordWait(descriptor: descriptor, until: deadline)
        switch outcome {
        case .timedOut:
            throw SSHError.timedOut
        case .rejected, .connected:
            return
        case .waitForCancellation:
            guard let cancellationWait else { throw SSHError.connectionFailed }
            try await cancellationWait.wait()
        }
    }

    private func recordWait(
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) -> ScriptedCandidateOutcome {
        lock.lock()
        defer { lock.unlock() }
        waitDeadlines.append(deadline)
        let outcome = outcomeLocked(for: descriptor)
        if outcome == .timedOut { currentTime = deadline }
        return outcome
    }

    private func outcome(for descriptor: Int32) -> ScriptedCandidateOutcome {
        lock.lock()
        defer { lock.unlock() }
        return outcomeLocked(for: descriptor)
    }

    private func outcomeLocked(for descriptor: Int32) -> ScriptedCandidateOutcome {
        let index = Int(descriptor - 100)
        guard outcomes.indices.contains(index) else { return .rejected }
        return outcomes[index]
    }

    private func closeSocket(_ descriptor: Int32) {
        lock.lock()
        closedDescriptors.append(descriptor)
        lock.unlock()
    }
}

private final class CancellationWait: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var cancelled = false
    private var waitContinuation: CheckedContinuation<Void, any Error>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: SSHError.cancelled)
                    return
                }
                entered = true
                waitContinuation = continuation
                let entryContinuations = self.entryContinuations
                self.entryContinuations.removeAll()
                lock.unlock()
                for entryContinuation in entryContinuations {
                    entryContinuation.resume()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                entryContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let waitContinuation = self.waitContinuation
        self.waitContinuation = nil
        lock.unlock()
        waitContinuation?.resume(throwing: SSHError.cancelled)
    }
}
