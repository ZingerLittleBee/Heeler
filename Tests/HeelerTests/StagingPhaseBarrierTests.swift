import Foundation
import Testing

@testable import Heeler

@Suite("Staging phase barriers")
struct StagingPhaseBarrierTests {
    @Test("release without enter fails entry waiters instead of succeeding")
    func releaseWithoutEnterFailsEntryWaiters() async throws {
        let gate = CancellablePhaseGate()
        let waiter = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration()
        await gate.release()
        await #expect(throws: PhaseGateError.releasedWithoutEntry) {
            try await waiter.value
        }
    }

    @Test("staging failure wins when it races cleanup release")
    func stagingFailureWinsOverCleanupRelease() async throws {
        let gate = CancellablePhaseGate()
        let failures = StagingFailureSignal()
        let phase = "remote staging setup"

        let wait = Task {
            try await StagingPhaseWait.awaitEntry(
                phase,
                gate: gate,
                failures: failures,
                timeout: .seconds(2))
        }
        try await gate.waitForEntryWaiterRegistration()
        try await failures.waitForWaiterRegistration()

        // Production order: record the outcome, then release gates.
        await failures.record(AttachmentStagingError.remoteTemporaryDirectoryFailed)
        await gate.release()

        await #expect(throws: StagingBarrierError.failed(
            phase: phase,
            detail: String(describing: AttachmentStagingError.remoteTemporaryDirectoryFailed))
        ) {
            try await wait.value
        }
    }

    @Test("successful staging finish wins when it races cleanup release")
    func stagingSuccessWinsOverCleanupRelease() async throws {
        let gate = CancellablePhaseGate()
        let failures = StagingFailureSignal()
        let phase = "severe-profile payload backpressure"

        let wait = Task {
            try await StagingPhaseWait.awaitEntry(
                phase,
                gate: gate,
                failures: failures,
                timeout: .seconds(2))
        }
        try await gate.waitForEntryWaiterRegistration()
        try await failures.waitForWaiterRegistration()

        await failures.recordSuccess()
        await gate.release()

        await #expect(throws: StagingBarrierError.finishedEarly(phase: phase)) {
            try await wait.value
        }
    }

    @Test("missing phase entry times out without treating release as entry")
    func missingPhaseEntryTimesOut() async throws {
        let gate = CancellablePhaseGate()
        let failures = StagingFailureSignal()
        let phase = "severe-profile payload backpressure"

        await #expect(throws: StagingBarrierError.timedOut(phase: phase)) {
            try await StagingPhaseWait.awaitEntry(
                phase,
                gate: gate,
                failures: failures,
                timeout: .milliseconds(50))
        }
    }

    @Test("real enterAndHold still satisfies the phase waiter")
    func enterAndHoldSatisfiesPhaseWaiter() async throws {
        let gate = CancellablePhaseGate()
        let failures = StagingFailureSignal()
        let phase = "remote staging setup"

        let wait = Task {
            try await StagingPhaseWait.awaitEntry(
                phase,
                gate: gate,
                failures: failures,
                timeout: .seconds(2))
        }
        try await gate.waitForEntryWaiterRegistration()
        let hold = Task {
            await gate.enterAndHold()
        }

        try await wait.value
        await gate.release()
        await hold.value
    }

    @Test("entry waiter registration tracks the active count")
    func entryWaiterRegistrationTracksActiveCount() async throws {
        let gate = CancellablePhaseGate()
        #expect(await gate.entryWaiterCount == 0)

        let waiter = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration(count: 1)
        #expect(await gate.entryWaiterCount == 1)

        await gate.release()
        await #expect(throws: PhaseGateError.releasedWithoutEntry) {
            try await waiter.value
        }
        #expect(await gate.entryWaiterCount == 0)
    }

    @Test("registration waits for a new active waiter after cancellation")
    func registrationWaitsForNewActiveWaiterAfterCancellation() async throws {
        let gate = CancellablePhaseGate()
        let first = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration(count: 1)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await gate.entryWaiterCount == 0)

        let second = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration(count: 1)
        #expect(await gate.entryWaiterCount == 1)

        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await gate.entryWaiterCount == 0)
    }

    @Test("entry registration observer cancellation resumes once")
    func entryRegistrationObserverCancellationResumesOnce() async throws {
        let gate = CancellablePhaseGate()
        let observer = Task {
            try await gate.waitForEntryWaiterRegistration(count: 1)
        }
        await gate.waitForRegistrationObserver(count: 1)
        #expect(await gate.registrationObserverCount == 1)

        observer.cancel()
        await #expect(throws: CancellationError.self) {
            try await observer.value
        }
        #expect(await gate.registrationObserverCount == 0)
    }

    @Test("phase gate fails registration observers when released before threshold")
    func phaseGateFailsRegistrationBeforeThresholdOnRelease() async throws {
        let gate = CancellablePhaseGate()
        let waiter = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration(count: 1)

        let observer = Task {
            try await gate.waitForEntryWaiterRegistration(count: 2)
        }
        await gate.waitForRegistrationObserver(count: 1)
        #expect(await gate.registrationObserverCount == 1)

        await gate.release()

        await #expect(throws: PhaseGateError.registrationThresholdUnreachable) {
            try await observer.value
        }
        #expect(await gate.registrationObserverCount == 0)
        await #expect(throws: PhaseGateError.releasedWithoutEntry) {
            try await waiter.value
        }
    }

    @Test("phase gate fails registration observers when entered before threshold")
    func phaseGateFailsRegistrationBeforeThresholdOnEnter() async throws {
        let gate = CancellablePhaseGate()
        let waiter = Task {
            try await gate.waitUntilEntered()
        }
        try await gate.waitForEntryWaiterRegistration(count: 1)

        let observer = Task {
            try await gate.waitForEntryWaiterRegistration(count: 2)
        }
        await gate.waitForRegistrationObserver(count: 1)
        #expect(await gate.registrationObserverCount == 1)

        let hold = Task {
            await gate.enterAndHold()
        }

        try await waiter.value
        await #expect(throws: PhaseGateError.registrationThresholdUnreachable) {
            try await observer.value
        }
        #expect(await gate.registrationObserverCount == 0)
        await gate.release()
        await hold.value
    }

    @Test("failure signal registration tracks the active count")
    func failureSignalRegistrationTracksActiveCount() async throws {
        let failures = StagingFailureSignal()
        #expect(await failures.waiterCount == 0)

        let waiter = Task {
            try await failures.wait(phase: "remote staging setup")
        }
        try await failures.waitForWaiterRegistration(count: 1)
        #expect(await failures.waiterCount == 1)

        await failures.recordSuccess()
        await #expect(throws: StagingBarrierError.finishedEarly(phase: "remote staging setup")) {
            try await waiter.value
        }
        #expect(await failures.waiterCount == 0)
    }

    @Test("failure signal registration waits for a new active waiter after cancellation")
    func failureSignalRegistrationWaitsAfterCancellation() async throws {
        let failures = StagingFailureSignal()
        let first = Task {
            try await failures.wait(phase: "remote staging setup")
        }
        try await failures.waitForWaiterRegistration(count: 1)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await failures.waiterCount == 0)

        let second = Task {
            try await failures.wait(phase: "remote staging setup")
        }
        try await failures.waitForWaiterRegistration(count: 1)
        #expect(await failures.waiterCount == 1)

        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await failures.waiterCount == 0)
    }

    @Test("failure signal registration observer cancellation resumes once")
    func failureSignalRegistrationObserverCancellationResumesOnce() async throws {
        let failures = StagingFailureSignal()
        let observer = Task {
            try await failures.waitForWaiterRegistration(count: 1)
        }
        await failures.waitForRegistrationObserver(count: 1)
        #expect(await failures.registrationObserverCount == 1)

        observer.cancel()
        await #expect(throws: CancellationError.self) {
            try await observer.value
        }
        #expect(await failures.registrationObserverCount == 0)
    }

    @Test("failure signal fails registration observers when recorded before threshold")
    func failureSignalFailsRegistrationBeforeThresholdOnRecord() async throws {
        let failures = StagingFailureSignal()
        let waiter = Task {
            try await failures.wait(phase: "remote staging setup")
        }
        try await failures.waitForWaiterRegistration(count: 1)

        let observer = Task {
            try await failures.waitForWaiterRegistration(count: 2)
        }
        await failures.waitForRegistrationObserver(count: 1)
        #expect(await failures.registrationObserverCount == 1)

        await failures.record(AttachmentStagingError.remoteTemporaryDirectoryFailed)

        await #expect(throws: StagingFailureSignalError.registrationThresholdUnreachable) {
            try await observer.value
        }
        #expect(await failures.registrationObserverCount == 0)
        await #expect(throws: StagingBarrierError.failed(
            phase: "remote staging setup",
            detail: String(describing: AttachmentStagingError.remoteTemporaryDirectoryFailed))
        ) {
            try await waiter.value
        }
    }

    @Test("failure signal fails registration observers when success arrives before threshold")
    func failureSignalFailsRegistrationBeforeThresholdOnSuccess() async throws {
        let failures = StagingFailureSignal()
        let waiter = Task {
            try await failures.wait(phase: "severe-profile payload backpressure")
        }
        try await failures.waitForWaiterRegistration(count: 1)

        let observer = Task {
            try await failures.waitForWaiterRegistration(count: 2)
        }
        await failures.waitForRegistrationObserver(count: 1)
        #expect(await failures.registrationObserverCount == 1)

        await failures.recordSuccess()

        await #expect(throws: StagingFailureSignalError.registrationThresholdUnreachable) {
            try await observer.value
        }
        #expect(await failures.registrationObserverCount == 0)
        await #expect(throws: StagingBarrierError.finishedEarly(
            phase: "severe-profile payload backpressure")
        ) {
            try await waiter.value
        }
    }
}
