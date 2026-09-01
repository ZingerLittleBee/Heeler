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
@MainActor
final class TerminalGridReportPhaseRecorder {
    private enum Wakeup: Sendable {
        case reached(TerminalGridSize?)
        case timedOut
    }

    private let currentPhase: @MainActor () -> TerminalGridReportPhase
    private var pending: (phase: TerminalGridReportPhase,
                          continuation: CheckedContinuation<Wakeup, Never>)?
    private var unclaimed: [(phase: TerminalGridReportPhase, forwarded: TerminalGridSize?)] = []
    /// Every transition seen, oldest first — the freeze's history, for a
    /// failure message that can say where it stopped.
    private(set) var phases: [TerminalGridReportPhase] = []

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
        if let index = unclaimed.firstIndex(where: { $0.phase == phase }) {
            let claimed = unclaimed[index]
            unclaimed.removeSubrange(...index)
            return claimed.forwarded
        }

        let waiter = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Wakeup, Never>) in
                self.pending = (phase, continuation)
            }
        }
        let deadlineTask = Task { @MainActor in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let waiting = self.pending, waiting.phase == phase
            else { return }
            self.pending = nil
            waiting.continuation.resume(returning: .timedOut)
        }
        defer { deadlineTask.cancel() }

        switch await waiter.value {
        case .reached(let forwarded):
            return forwarded
        case .timedOut:
            throw GridReportPhaseNeverReachedError(
                expected: phase, actual: currentPhase(), observed: phases)
        }
    }

    private func record(_ phase: TerminalGridReportPhase, forwarded: TerminalGridSize?) {
        phases.append(phase)
        guard let waiting = pending, waiting.phase == phase else {
            unclaimed.append((phase, forwarded))
            return
        }
        pending = nil
        waiting.continuation.resume(returning: .reached(forwarded))
    }
}
