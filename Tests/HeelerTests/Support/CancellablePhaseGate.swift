import Foundation

@testable import Heeler

/// Surfaces a staging outcome under the phase that was waiting.
enum StagingBarrierError: Error, Equatable, CustomStringConvertible {
    case finishedEarly(phase: String)
    case failed(phase: String, detail: String)
    case releasedWithoutEntry(phase: String)
    case timedOut(phase: String)

    var description: String {
        switch self {
        case .finishedEarly(let phase):
            "staging finished during \(phase) before the barrier armed"
        case .failed(let phase, let detail):
            "staging failed during \(phase): \(detail)"
        case .releasedWithoutEntry(let phase):
            "phase \(phase) was released without enterAndHold"
        case .timedOut(let phase):
            "timed out waiting for \(phase)"
        }
    }
}

enum PhaseGateError: Error, Equatable {
    /// `release()` ran before `enterAndHold()`, so this is cleanup — not entry.
    case releasedWithoutEntry
    /// The gate became terminal before the requested active-waiter count could be reached.
    case registrationThresholdUnreachable
}

/// Hold/observe gate whose stored continuations always resume via `release()`,
/// successful `enterAndHold()`, or task cancellation.
///
/// `release()` unblocks hold waiters and fails entry waiters when entry never
/// happened, so cleanup cannot be mistaken for phase entry.
actor CancellablePhaseGate {
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var holdWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Currently registered entry waiters (not a historical counter).
    private(set) var entryWaiterCount = 0
    /// Stored registration observers awaiting an active-waiter threshold.
    private(set) var registrationObserverCount = 0
    private var registrationWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    private var registrationObserverBarriers:
        [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    private var isRegistrationTerminal: Bool {
        hasEntered || isReleased
    }

    /// Suspends until at least `count` entry waiters are actively registered.
    /// Proves an active waiter before release/failure injection — not a scheduling hint.
    func waitForEntryWaiterRegistration(count: Int = 1) async throws {
        if entryWaiterCount >= count { return }
        if isRegistrationTerminal {
            throw PhaseGateError.registrationThresholdUnreachable
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if self.entryWaiterCount >= count {
                    continuation.resume()
                } else if self.hasEntered || self.isReleased {
                    continuation.resume(throwing: PhaseGateError.registrationThresholdUnreachable)
                } else {
                    self.registrationWaiters[id] = (count, continuation)
                    self.noteRegistrationObserversChanged()
                }
            }
        } onCancel: {
            Task { await self.cancelRegistrationWaiter(id) }
        }
    }

    /// Suspends until at least `count` registration observers have stored continuations.
    func waitForRegistrationObserver(count: Int = 1) async {
        if registrationObserverCount >= count { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.registrationObserverCount >= count {
                continuation.resume()
            } else {
                self.registrationObserverBarriers[id] = (count, continuation)
            }
        }
    }

    func enterAndHold() async {
        hasEntered = true
        resumeEntryWaitersSuccessfully()
        closeUnreachableRegistrationWaiters()
        if isReleased { return }
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if self.isReleased {
                        continuation.resume()
                    } else {
                        self.holdWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.resumeHoldWaiter(id, throwing: CancellationError()) }
            }
        } catch {
            return
        }
    }

    func waitUntilEntered() async throws {
        if hasEntered { return }
        if isReleased {
            throw PhaseGateError.releasedWithoutEntry
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if self.hasEntered {
                    continuation.resume()
                } else if self.isReleased {
                    continuation.resume(throwing: PhaseGateError.releasedWithoutEntry)
                } else {
                    self.entryWaiters[id] = continuation
                    self.entryWaiterCount += 1
                    self.resumeRegistrationWaitersIfReady()
                }
            }
        } onCancel: {
            Task { await self.resumeEntryWaiter(id, throwing: CancellationError()) }
        }
    }

    func release() {
        isReleased = true
        let entries = entryWaiters
        entryWaiters.removeAll()
        entryWaiterCount = 0
        for (_, waiter) in entries {
            if hasEntered {
                waiter.resume()
            } else {
                waiter.resume(throwing: PhaseGateError.releasedWithoutEntry)
            }
        }
        closeUnreachableRegistrationWaiters()
        let holds = holdWaiters
        holdWaiters.removeAll()
        for (_, waiter) in holds {
            waiter.resume()
        }
    }

    private func resumeEntryWaitersSuccessfully() {
        let waiters = entryWaiters
        entryWaiters.removeAll()
        entryWaiterCount = 0
        for (_, waiter) in waiters {
            waiter.resume()
        }
    }

    private func resumeRegistrationWaitersIfReady() {
        let ready = registrationWaiters.filter { entryWaiterCount >= $0.value.count }
        for (id, _) in ready {
            registrationWaiters.removeValue(forKey: id)
        }
        noteRegistrationObserversChanged()
        for (_, waiter) in ready {
            waiter.continuation.resume()
        }
    }

    /// Terminal gates cannot grow the active waiter set; fail observers still short of threshold.
    private func closeUnreachableRegistrationWaiters() {
        resumeRegistrationWaitersIfReady()
        let pending = registrationWaiters
        registrationWaiters.removeAll()
        noteRegistrationObserversChanged()
        for (_, waiter) in pending {
            waiter.continuation.resume(throwing: PhaseGateError.registrationThresholdUnreachable)
        }
    }

    private func noteRegistrationObserversChanged() {
        registrationObserverCount = registrationWaiters.count
        let ready = registrationObserverBarriers.filter {
            registrationObserverCount >= $0.value.count
        }
        for (id, _) in ready {
            registrationObserverBarriers.removeValue(forKey: id)
        }
        for (_, barrier) in ready {
            barrier.continuation.resume()
        }
    }

    private func cancelRegistrationWaiter(_ id: UUID) {
        guard let waiter = registrationWaiters.removeValue(forKey: id) else { return }
        noteRegistrationObserversChanged()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeEntryWaiter(_ id: UUID, throwing error: any Error) {
        guard let waiter = entryWaiters.removeValue(forKey: id) else { return }
        if entryWaiterCount > 0 {
            entryWaiterCount -= 1
        }
        waiter.resume(throwing: error)
    }

    private func resumeHoldWaiter(_ id: UUID, throwing error: any Error) {
        guard let waiter = holdWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: error)
    }
}

enum StagingFailureSignalError: Error, Equatable {
    /// The signal became terminal before the requested active-waiter count could be reached.
    case registrationThresholdUnreachable
}

/// Staging reports outcomes here from its own task body so waiters do not
/// suspend on `Task.result` after the phase has moved on.
actor StagingFailureSignal {
    private var detail: String?
    private var finishedSuccessfully = false
    private var waiters: [UUID: (phase: String, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    /// Currently registered outcome waiters (not a historical counter).
    private(set) var waiterCount = 0
    /// Stored registration observers awaiting an active-waiter threshold.
    private(set) var registrationObserverCount = 0
    private var registrationWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    private var registrationObserverBarriers:
        [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    private var isRegistrationTerminal: Bool {
        detail != nil || finishedSuccessfully
    }

    /// Suspends until at least `count` outcome waiters are actively registered.
    func waitForWaiterRegistration(count: Int = 1) async throws {
        if waiterCount >= count { return }
        if isRegistrationTerminal {
            throw StagingFailureSignalError.registrationThresholdUnreachable
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if self.waiterCount >= count {
                    continuation.resume()
                } else if self.detail != nil || self.finishedSuccessfully {
                    continuation.resume(
                        throwing: StagingFailureSignalError.registrationThresholdUnreachable)
                } else {
                    self.registrationWaiters[id] = (count, continuation)
                    self.noteRegistrationObserversChanged()
                }
            }
        } onCancel: {
            Task { await self.cancelRegistrationWaiter(id) }
        }
    }

    /// Suspends until at least `count` registration observers have stored continuations.
    func waitForRegistrationObserver(count: Int = 1) async {
        if registrationObserverCount >= count { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.registrationObserverCount >= count {
                continuation.resume()
            } else {
                self.registrationObserverBarriers[id] = (count, continuation)
            }
        }
    }

    func record(_ error: any Error) {
        let detail = String(describing: error)
        self.detail = detail
        let captured = waiters
        waiters.removeAll()
        waiterCount = 0
        for (_, waiter) in captured {
            waiter.continuation.resume(
                throwing: StagingBarrierError.failed(phase: waiter.phase, detail: detail))
        }
        closeUnreachableRegistrationWaiters()
    }

    func recordSuccess() {
        finishedSuccessfully = true
        let captured = waiters
        waiters.removeAll()
        waiterCount = 0
        for (_, waiter) in captured {
            waiter.continuation.resume(
                throwing: StagingBarrierError.finishedEarly(phase: waiter.phase))
        }
        closeUnreachableRegistrationWaiters()
    }

    func barrierErrorIfPresent(phase: String) -> StagingBarrierError? {
        if let detail {
            return .failed(phase: phase, detail: detail)
        }
        if finishedSuccessfully {
            return .finishedEarly(phase: phase)
        }
        return nil
    }

    func wait(phase: String) async throws {
        if let error = barrierErrorIfPresent(phase: phase) {
            throw error
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if let detail = self.detail {
                    continuation.resume(
                        throwing: StagingBarrierError.failed(phase: phase, detail: detail))
                } else if self.finishedSuccessfully {
                    continuation.resume(
                        throwing: StagingBarrierError.finishedEarly(phase: phase))
                } else {
                    waiters[id] = (phase, continuation)
                    waiterCount += 1
                    resumeRegistrationWaitersIfReady()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func resumeRegistrationWaitersIfReady() {
        let ready = registrationWaiters.filter { waiterCount >= $0.value.count }
        for (id, _) in ready {
            registrationWaiters.removeValue(forKey: id)
        }
        noteRegistrationObserversChanged()
        for (_, waiter) in ready {
            waiter.continuation.resume()
        }
    }

    private func closeUnreachableRegistrationWaiters() {
        resumeRegistrationWaitersIfReady()
        let pending = registrationWaiters
        registrationWaiters.removeAll()
        noteRegistrationObserversChanged()
        for (_, waiter) in pending {
            waiter.continuation.resume(
                throwing: StagingFailureSignalError.registrationThresholdUnreachable)
        }
    }

    private func noteRegistrationObserversChanged() {
        registrationObserverCount = registrationWaiters.count
        let ready = registrationObserverBarriers.filter {
            registrationObserverCount >= $0.value.count
        }
        for (id, _) in ready {
            registrationObserverBarriers.removeValue(forKey: id)
        }
        for (_, barrier) in ready {
            barrier.continuation.resume()
        }
    }

    private func cancelRegistrationWaiter(_ id: UUID) {
        guard let waiter = registrationWaiters.removeValue(forKey: id) else { return }
        noteRegistrationObserversChanged()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        if waiterCount > 0 {
            waiterCount -= 1
        }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Races phase entry against a staging outcome and a wall-clock deadline.
enum StagingPhaseWait {
    static func awaitEntry(
        _ phase: String,
        gate: CancellablePhaseGate,
        failures: StagingFailureSignal,
        timeout: Duration = .seconds(15)
    ) async throws {
        do {
            try await AsyncDeadline.run(
                for: timeout,
                onTimeout: {
                    await gate.release()
                }
            ) {
                try await raceEntry(phase, gate: gate, failures: failures)
            }
        } catch AsyncDeadlineError.timedOut {
            if let error = await failures.barrierErrorIfPresent(phase: phase) {
                throw error
            }
            throw StagingBarrierError.timedOut(phase: phase)
        }
    }

    private static func raceEntry(
        _ phase: String,
        gate: CancellablePhaseGate,
        failures: StagingFailureSignal
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await gate.waitUntilEntered()
                    return true
                } catch PhaseGateError.releasedWithoutEntry {
                    return false
                }
            }
            group.addTask {
                try await failures.wait(phase: phase)
                // `wait` only resumes by throwing.
                return false
            }
            let entered = try await group.next()!
            group.cancelAll()
            if entered {
                return
            }
            // `record` / `recordSuccess` always run before `release` in the
            // staging task, so a cleanup wake must observe that outcome here.
            if let error = await failures.barrierErrorIfPresent(phase: phase) {
                throw error
            }
            throw StagingBarrierError.releasedWithoutEntry(phase: phase)
        }
    }
}
