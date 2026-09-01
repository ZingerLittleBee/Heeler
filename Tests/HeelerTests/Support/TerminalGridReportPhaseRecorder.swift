import Foundation

@testable import Heeler

/// The grid freeze never reached the phase the caller was waiting for. Names
/// the phase it was actually stuck in: "still deferring" (the keyboard's
/// settle signal never landed) and "still flushing" (a Ghostty callback the
/// thaw is waiting on never arrived) are different bugs, and a caller waiting
/// on resize reports alone cannot tell either from "nothing left to report".
struct GridReportPhaseNeverReachedError: Error, CustomStringConvertible {
    let expected: TerminalGridReportPhase
    let actual: TerminalGridReportPhase
    let observed: [TerminalGridReportPhase]

    var description: String {
        """
        the grid freeze never reached \(expected); still \(actual) \
        after \(observed)
        """
    }
}

/// Records a terminal's grid-freeze transitions and hands the caller the one
/// it is waiting for.
///
/// This is the barrier the freeze's own lifecycle provides: the thaw is a
/// fact the terminal publishes (``TerminalGridReportPhase``), not something to
/// be inferred from when resize reports happen to arrive. Inference is what
/// made the wait runner-speed dependent — reports are Ghostty's to send, on
/// its own thread, and a terminal whose surface never measured a grid sends
/// none at all while still thawing perfectly correctly (#263).
///
/// Transitions are buffered, so a caller that asks after the fact still gets
/// its answer, and the buffer check and the waiter's registration happen in
/// one synchronous main-actor step — a barrier that can drop the very event
/// it exists to catch is worth less than no barrier at all.
@MainActor
final class TerminalGridReportPhaseRecorder {
    private enum Wakeup: Sendable {
        case reached(TerminalGridSize?)
        case timedOut
    }

    private struct Waiter {
        let phase: TerminalGridReportPhase
        let continuation: CheckedContinuation<Wakeup, Never>
    }

    private let currentPhase: @MainActor () -> TerminalGridReportPhase
    /// Keyed so a deadline can only ever resume the wait that armed it.
    private var waiters: [UUID: Waiter] = [:]
    private var unclaimed: [(phase: TerminalGridReportPhase, forwarded: TerminalGridSize?)] = []
    /// Every transition seen, oldest first — the freeze's history, for a
    /// failure message that can say where it stopped.
    private(set) var phases: [TerminalGridReportPhase] = []
    /// Runs once, inside a wait's set-up, at the one instant that matters:
    /// after that wait has searched the history and before its waiter is
    /// registered. Whatever it publishes therefore lands in the gap between
    /// "has it happened yet?" and "wake me when it does" — by call position,
    /// not by which job an executor picks up first. That gap is where a
    /// recorder that registers from a later job loses the transition, so it
    /// is the only place a regression test can prove the loss cannot happen
    /// here. Nothing outside the recorder's own test sets this.
    var onWaitAboutToRegister: (@MainActor () -> Void)?

    init(observing terminal: HeelerTerminalView) {
        currentPhase = { [weak terminal] in terminal?.gridReportPhase ?? .live }
        terminal.onGridReportPhaseChanged = { [weak self] phase, forwarded in
            self?.record(phase, forwarded: forwarded)
        }
    }

    init(observing bridge: TerminalSessionCallbackBridge) {
        currentPhase = { [weak bridge] in bridge?.gridReportPhase ?? .live }
        bridge.onGridReportPhaseChanged = { [weak self] phase, forwarded in
            self?.record(phase, forwarded: forwarded)
        }
    }

    /// Waits for the freeze to thaw and returns the grid it forwarded to the
    /// Host, or `nil` when it had none to forward.
    @discardableResult
    func thawedGrid(within deadline: Duration = .seconds(5)) async throws -> TerminalGridSize? {
        try await forwardedGrid(reaching: .live, within: deadline)
    }

    /// Waits for `phase`. The deadline is a diagnostic bound, not a
    /// correctness window: the passing path resumes on the terminal's own
    /// transition, so only a lifecycle that stalled ever reaches it.
    @discardableResult
    func forwardedGrid(
        reaching phase: TerminalGridReportPhase,
        within deadline: Duration = .seconds(5)
    ) async throws -> TerminalGridSize? {
        let id = UUID()
        let deadlineTask = Task { @MainActor in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let waiter = self.waiters.removeValue(forKey: id)
            else { return }
            waiter.continuation.resume(returning: .timedOut)
        }
        defer { deadlineTask.cancel() }

        // Claiming the history and registering the waiter are one synchronous
        // main-actor step. Split across a suspension — a check here, a waiter
        // installed from a separate task there — a transition published in
        // between is lost twice over: `record` buffers it because no waiter is
        // registered yet, and the waiter then registers without looking at the
        // buffer again. That is a wait that hangs on an event that already
        // happened, reported as the timeout of a freeze that thawed fine.
        let wakeup = await withCheckedContinuation {
            (continuation: CheckedContinuation<Wakeup, Never>) in
            if let claimed = self.claimBuffered(phase) {
                continuation.resume(returning: .reached(claimed.forwarded))
                return
            }
            let beganWaiting = self.onWaitAboutToRegister
            self.onWaitAboutToRegister = nil
            beganWaiting?()
            self.waiters[id] = Waiter(phase: phase, continuation: continuation)
            // Registration alone is not enough, and this is the second half of
            // the same rule: a transition that landed while this wait was
            // being set up was buffered against a waiter that did not exist
            // yet. Read the buffer again from behind the registration, or that
            // transition is waited out to the deadline.
            guard let late = self.claimBuffered(phase) else { return }
            self.waiters.removeValue(forKey: id)
            continuation.resume(returning: .reached(late.forwarded))
        }

        switch wakeup {
        case .reached(let forwarded):
            return forwarded
        case .timedOut:
            throw GridReportPhaseNeverReachedError(
                expected: phase, actual: currentPhase(), observed: phases)
        }
    }

    /// Removes the earliest buffered `phase` transition and returns it, or
    /// `nil` when none was seen. The transition's own payload is optional, so
    /// the two kinds of "nothing" stay distinct: no such transition buffered
    /// at all, versus a thaw that forwarded no grid.
    private func claimBuffered(
        _ phase: TerminalGridReportPhase
    ) -> (phase: TerminalGridReportPhase, forwarded: TerminalGridSize?)? {
        guard let index = unclaimed.firstIndex(where: { $0.phase == phase }) else {
            return nil
        }
        let claimed = unclaimed[index]
        unclaimed.removeSubrange(...index)
        return claimed
    }

    private func record(_ phase: TerminalGridReportPhase, forwarded: TerminalGridSize?) {
        phases.append(phase)
        guard let id = waiters.first(where: { $0.value.phase == phase })?.key,
              let waiter = waiters.removeValue(forKey: id)
        else {
            unclaimed.append((phase, forwarded))
            return
        }
        waiter.continuation.resume(returning: .reached(forwarded))
    }
}
