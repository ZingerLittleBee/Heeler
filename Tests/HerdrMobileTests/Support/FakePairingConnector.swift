import Foundation

@testable import HerdrMobile

/// Scripted `PairingConnector` for store tests: replays the real client's
/// step callbacks up to a scripted outcome, no SSH. Outcomes are consumed
/// one per `pair` call and the last one repeats, so retry scripts read
/// naturally: `[.fails(...), .succeeds(...)]`.
final actor FakePairingConnector: PairingConnector {
    enum Outcome: Sendable {
        case succeeds(PairingResult)
        case fails(PairingCeremonyError)
    }

    private var outcomes: [Outcome]
    private var isHolding = false
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var capturedCodes: [PairingCode] = []
    private(set) var capturedDeviceKeyBlobs: [Data] = []

    init(outcomes: [Outcome]) {
        precondition(!outcomes.isEmpty, "script at least one outcome")
        self.outcomes = outcomes
    }

    /// Makes every subsequent `pair` call wait, after reporting its steps,
    /// until `release()`, so tests can observe in-flight progress state.
    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        for waiter in holdWaiters {
            waiter.resume()
        }
        holdWaiters.removeAll()
    }

    func pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: @escaping @Sendable (PairingStep) -> Void
    ) async throws -> PairingResult {
        capturedCodes.append(code)
        capturedDeviceKeyBlobs.append(deviceKey.publicKeyBlob)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        for step in Self.emittedSteps(for: outcome, code: code) {
            onStep(step)
        }
        if isHolding {
            await withCheckedContinuation { holdWaiters.append($0) }
        }
        switch outcome {
        case .succeeds(let result):
            return result
        case .fails(let error):
            throw error
        }
    }

    /// The steps the real client reports before this outcome resolves: every
    /// ceremony step that begins at or before the failing one. `authenticate`
    /// is never emitted, matching `SSHPairingConnector`, where authentication
    /// happens inside the reach connect.
    private static func emittedSteps(for outcome: Outcome, code: PairingCode) -> [PairingStep] {
        let ceremony: [PairingStep] =
            code.bootstrap == nil ? [.reach, .verify] : [.reach, .enroll, .verify]
        switch outcome {
        case .succeeds:
            return ceremony
        case .fails(let error):
            return ceremony.filter { rank($0) <= rank(error.step) }
        }
    }

    private static func rank(_ step: PairingStep) -> Int {
        PairingStep.allCases.firstIndex(of: step)!
    }
}
