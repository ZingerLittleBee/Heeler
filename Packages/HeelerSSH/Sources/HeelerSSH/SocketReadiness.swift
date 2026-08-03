import Darwin
import Dispatch
import Foundation

struct SocketDirections: OptionSet, Sendable {
    let rawValue: Int

    static let read = SocketDirections(rawValue: 1 << 0)
    static let write = SocketDirections(rawValue: 1 << 1)
}

enum SocketReadiness {
    static func wait(
        descriptor: Int32,
        directions: SocketDirections,
        until deadline: ContinuousClock.Instant,
        cancellable: Bool = true
    ) async throws {
        guard !directions.isEmpty else {
            await Task.yield()
            return
        }

        let waiter = DispatchWaiter()
        if directions.contains(.read) {
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { waiter.finish(.success(())) }
            waiter.add(source)
        }
        if directions.contains(.write) {
            let source = DispatchSource.makeWriteSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { waiter.finish(.success(())) }
            waiter.add(source)
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + dispatchInterval(until: deadline))
        timer.setEventHandler { waiter.finish(.failure(SSHError.timedOut)) }
        waiter.add(timer)
        waiter.activateAll()

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

private final class DispatchWaiter: @unchecked Sendable {
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
