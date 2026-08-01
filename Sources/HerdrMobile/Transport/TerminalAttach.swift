import Foundation
import Synchronization

/// One Attach request (#11): the `herdr agent attach` target (a Pane
/// address), herdr's takeover flag, and the initial PTY geometry.
struct TerminalAttachRequest: Sendable, Equatable {
    let target: String
    let takeover: Bool
    let cols: Int
    let rows: Int

    init(target: String, takeover: Bool = false, cols: Int, rows: Int) {
        self.target = target
        self.takeover = takeover
        self.cols = cols
        self.rows = rows
    }
}

/// Input riding down a live Attach session. Keystrokes and resizes are
/// reliable, while touch scrolling is bounded and may be coalesced.
enum TerminalAttachInput: Sendable, Equatable {
    case keystrokes(Data)
    case scroll(Data)
    case resize(cols: Int, rows: Int)
}

/// The live PTY's mixed-reliability input queue.
///
/// Keystrokes and resizes are reliable and ordered. Touch scrolling is an
/// ephemeral viewport intent: keeping every momentum row under backpressure
/// only makes stale scrolling delay later keyboard input. Scroll rows are
/// therefore coalesced, bounded, and discarded as soon as a reliable key
/// arrives. The writer asks for one item only after the previous SSH write
/// completes, so priority is decided at the last useful moment.
final class TerminalAttachInputQueue: Sendable {
    static let maximumPendingScrollRows = 12
    static let maximumScrollRowsPerWrite = 3
    static let scrollPacingInterval = Duration.milliseconds(33)

    private struct PendingScroll: Sendable {
        let sequence: Data
        var rows: Int
    }

    private struct State: ~Copyable {
        var reliable: [TerminalAttachInput] = []
        var pendingScroll: PendingScroll?
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        var isFinished = false
    }

    private enum NextDecision {
        case wait
        case resume(TerminalAttachInput?)
    }

    private let state = Mutex(State())

    func send(_ keystrokes: Data) {
        guard !keystrokes.isEmpty else { return }
        enqueueReliable(.keystrokes(keystrokes), discardingPendingScroll: true)
    }

    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0 else { return }

        var resumed: (CheckedContinuation<TerminalAttachInput?, Never>, TerminalAttachInput)?
        state.withLock { state in
            guard !state.isFinished else { return }

            if let waiter = state.waiter {
                state.waiter = nil
                let deliveredRows = min(rows, Self.maximumScrollRowsPerWrite)
                let remainingRows = min(
                    rows - deliveredRows,
                    Self.maximumPendingScrollRows - deliveredRows)
                if remainingRows > 0 {
                    state.pendingScroll = PendingScroll(
                        sequence: sequence,
                        rows: remainingRows)
                }
                resumed = (waiter, .scroll(Self.repeated(sequence, count: deliveredRows)))
                return
            }

            if var pending = state.pendingScroll, pending.sequence == sequence {
                pending.rows = min(
                    Self.maximumPendingScrollRows,
                    pending.rows + rows)
                state.pendingScroll = pending
            } else {
                // A direction change makes the previous momentum stale.
                state.pendingScroll = PendingScroll(
                    sequence: sequence,
                    rows: min(rows, Self.maximumPendingScrollRows))
            }
        }
        if let resumed {
            resumed.0.resume(returning: resumed.1)
        }
    }

    func resize(cols: Int, rows: Int) {
        enqueueReliable(.resize(cols: cols, rows: rows), discardingPendingScroll: false)
    }

    func next() async -> TerminalAttachInput? {
        await withCheckedContinuation { continuation in
            let decision = state.withLock { state -> NextDecision in
                if !state.reliable.isEmpty {
                    return .resume(state.reliable.removeFirst())
                }
                if let scroll = state.pendingScroll {
                    let deliveredRows = min(scroll.rows, Self.maximumScrollRowsPerWrite)
                    let remainingRows = scroll.rows - deliveredRows
                    state.pendingScroll =
                        remainingRows > 0
                        ? PendingScroll(sequence: scroll.sequence, rows: remainingRows)
                        : nil
                    return .resume(
                        .scroll(Self.repeated(scroll.sequence, count: deliveredRows)))
                }
                if state.isFinished {
                    return .resume(nil)
                }
                precondition(state.waiter == nil, "Attach input has more than one consumer")
                state.waiter = continuation
                return .wait
            }

            if case .resume(let input) = decision {
                continuation.resume(returning: input)
            }
        }
    }

    func finish() {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            state.isFinished = true
            // Explicit shutdown still drains reliable input already accepted
            // by the session. Only ephemeral scroll momentum is abandoned.
            state.pendingScroll = nil
            waiter = state.waiter
            state.waiter = nil
        }
        waiter?.resume(returning: nil)
    }

    private func enqueueReliable(
        _ input: TerminalAttachInput,
        discardingPendingScroll: Bool
    ) {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            if discardingPendingScroll {
                state.pendingScroll = nil
            }
            if state.reliable.isEmpty, let waiting = state.waiter {
                state.waiter = nil
                waiter = waiting
            } else {
                state.reliable.append(input)
            }
        }
        waiter?.resume(returning: input)
    }

    private static func repeated(_ sequence: Data, count: Int) -> Data {
        var result = Data(capacity: sequence.count * count)
        for _ in 0..<count {
            result.append(sequence)
        }
        return result
    }
}

/// A live interactive Attach session over its Host's dedicated terminal
/// channel: raw PTY bytes out, keystrokes and window changes in. The byte
/// stream feeds the terminal emulator directly without app-level framing.
///
/// Ending is explicit: call `end()`. A live exec channel does not respond to
/// Swift task cancellation (ADR 0002), so abandoning the session without
/// `end()` leaks the channel until the SSH connection closes.
final class TerminalAttachSession: Sendable {
    /// Raw PTY output in arrival order. Finishes without error when the
    /// remote attach exits cleanly (the user detached inside the TUI) or
    /// after `end()`; finishes throwing if the channel dies.
    let output: AsyncThrowingStream<Data, any Error>
    private let input: TerminalAttachInputQueue
    private let ender: @Sendable () async -> Void

    init(
        output: AsyncThrowingStream<Data, any Error>,
        input: TerminalAttachInputQueue,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.output = output
        self.input = input
        self.ender = ender
    }

    /// Forwards raw keystroke bytes to the remote PTY. Fire-and-forget: a
    /// dead channel drops them, and the death surfaces on `output`.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// Coalesces touch-scroll rows behind at most one small in-flight batch.
    /// Pending rows are intentionally lossy so typing never waits behind old
    /// momentum after the user's intent has changed.
    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    /// Propagates a terminal geometry change (rotation, split view) to the
    /// remote PTY via SSH window-change; no reattach needed.
    func resize(cols: Int, rows: Int) {
        input.resize(cols: cols, rows: rows)
    }

    /// Closes the terminal channel explicitly and waits for its teardown;
    /// `output` then finishes without error. Idempotent.
    func end() async {
        input.finish()
        await ender()
    }
}
