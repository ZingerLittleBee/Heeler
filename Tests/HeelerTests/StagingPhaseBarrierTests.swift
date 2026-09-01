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
}
