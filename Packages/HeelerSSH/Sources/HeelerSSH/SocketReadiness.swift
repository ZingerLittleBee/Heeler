import Darwin
import Dispatch
import Foundation

struct SocketDirections: OptionSet, Sendable {
    let rawValue: Int

    static let read = SocketDirections(rawValue: 1 << 0)
    static let write = SocketDirections(rawValue: 1 << 1)
}

enum SocketReadiness {
    struct Interest: Sendable {
        let descriptor: Int32
        let directions: SocketDirections
    }

    static func wait(
        descriptor: Int32,
        directions: SocketDirections,
        until deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        watching watch: SessionActivityWatch? = nil
    ) async throws {
        try await wait(
            for: [Interest(descriptor: descriptor, directions: directions)],
            until: deadline,
            cancellable: cancellable,
            watching: watch)
    }

    /// Waits until one of `interests` is ready, the deadline passes, or the
    /// watched session takes bytes off its socket.
    ///
    /// That last clause is not a convenience. A socket source only reports an
    /// edge, and on a shared libssh2 session another operation can consume the
    /// bytes this one is waiting for before its source is even armed. The
    /// watch carries the receive count observed before the caller released the
    /// session, so an arming that already missed its bytes returns at once.
    static func wait(
        for interests: [Interest],
        until deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        watching watch: SessionActivityWatch? = nil
    ) async throws {
        let activeInterests = interests.filter { !$0.directions.isEmpty }
        guard !activeInterests.isEmpty else {
            await Task.yield()
            return
        }

        let waiter = DispatchWaiter()
        for interest in activeInterests {
            if interest.directions.contains(.read) {
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: interest.descriptor,
                    queue: DispatchQueue.global(qos: .userInitiated))
                source.setEventHandler { waiter.finish(.success(())) }
                waiter.add(source)
            }
            if interest.directions.contains(.write) {
                let source = DispatchSource.makeWriteSource(
                    fileDescriptor: interest.descriptor,
                    queue: DispatchQueue.global(qos: .userInitiated))
                source.setEventHandler { waiter.finish(.success(())) }
                waiter.add(source)
            }
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + dispatchInterval(until: deadline))
        timer.setEventHandler { waiter.finish(.failure(SSHError.timedOut)) }
        waiter.add(timer)
        waiter.activateAll()

        // Registering only once the sources are live keeps a release from the
        // session and a release from the socket on the same path. Failing to
        // register means the session already moved, so this wait has nothing
        // left to learn from the socket.
        defer { watch?.unregister(waiter) }
        if let watch, !watch.register(waiter) {
            waiter.finish(.success(()))
        }

        if cancellable {
            try await withTaskCancellationHandler {
                try await waiter.value()
            } onCancel: {
                waiter.finish(.failure(SSHError.cancelled))
            }
        } else {
            try await waiter.value()
        }
    }

    private static func dispatchInterval(
        until deadline: ContinuousClock.Instant
    ) -> DispatchTimeInterval {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return .nanoseconds(0) }
        let components = remaining.components
        let seconds = max(components.seconds, 0)
        let nanosFromAttoseconds = max(components.attoseconds, 0) / 1_000_000_000
        let total = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !total.overflow else { return .seconds(Int.max) }
        let withFraction = total.partialValue.addingReportingOverflow(nanosFromAttoseconds)
        guard !withFraction.overflow, withFraction.partialValue <= Int64(Int.max) else {
            return .seconds(Int.max)
        }
        return .nanoseconds(Int(withFraction.partialValue))
    }
}

final class DispatchWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?
    private var sources: [any DispatchSourceProtocol] = []
    private var pendingSourceCancellations = 0

    func add(_ source: any DispatchSourceProtocol) {
        lock.lock()
        pendingSourceCancellations += 1
        source.setCancelHandler { [self] in sourceDidCancel() }
        sources.append(source)
        lock.unlock()
    }

    func activateAll() {
        lock.lock()
        let currentSources = sources
        lock.unlock()
        for source in currentSources {
            source.activate()
        }
    }

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result, pendingSourceCancellations == 0 {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let currentSources = sources
        sources.removeAll()
        let continuation = pendingSourceCancellations == 0 ? self.continuation : nil
        if continuation != nil { self.continuation = nil }
        lock.unlock()

        for source in currentSources {
            source.cancel()
        }
        continuation?.resume(with: result)
    }

    private func sourceDidCancel() {
        lock.lock()
        pendingSourceCancellations -= 1
        guard
            pendingSourceCancellations == 0,
            let result,
            let continuation
        else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
