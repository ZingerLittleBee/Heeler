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

/// How long a foreground repaint request may go unanswered before the Attach
/// screen calls the session unresponsive (#141).
///
/// The screen asks for the repaint by resizing the PTY, so its deadline has to
/// be built out of the transport's own budget for that resize rather than
/// guessed: a deadline shorter than the transport's would declare the remote
/// dead while the transport still expects the very same write to land, and the
/// transport's own failure is both later and more accurate.
enum TerminalAttachRepaintBudget {
    /// Getting one window-change onto the wire. `TerminalAttachInputQueue.pump`
    /// hands each resize to `channel.resize(timeout:)` with the transport's
    /// per-request timeout, so this is the longest the transport itself will
    /// wait before calling that write failed.
    static let windowChangeDelivery = SSHTransportSettings.defaultRequestTimeout

    /// What the answer costs on top of delivery: one round trip on a link that
    /// has just come out of suspension, the remote's SIGWINCH handling and full
    /// ratatui repaint, and up to a second of the attach reader's own poll
    /// interval (`channel.read(timeout: .seconds(1))`) before the first byte is
    /// yielded. Deliberately loose — being early costs a live session, being
    /// late costs a few seconds of a screen that was already blank.
    static let remoteAnswer: Duration = .seconds(5)

    /// The deadline the Attach screen arms when it asks for a repaint.
    static let deadline = windowChangeDelivery + remoteAnswer
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

    /// Drains the queue onto a live PTY channel until the queue finishes or
    /// the task is cancelled. Scroll batches are paced so momentum cannot
    /// monopolize the channel ahead of keystrokes.
    func pump(
        write: (Data) async throws -> Void,
        resize: (Int, Int) async throws -> Void
    ) async throws {
        while let item = await next() {
            guard !Task.isCancelled else { return }
            switch item {
            case .keystrokes(let data):
                try await write(data)
            case .scroll(let data):
                try await write(data)
                try await Task.sleep(for: Self.scrollPacingInterval)
            case .resize(let cols, let rows):
                try await resize(cols, rows)
            }
        }
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
/// Ending is explicit: call `end()`. The channel is closed by the session's
/// own teardown, which nothing else invokes — dropping the session, or
/// cancelling the task reading `output`, leaves the channel open until the
/// SSH connection closes.
final class TerminalAttachSession: Sendable {
    /// Raw PTY output in arrival order. Finishes without error when the
    /// remote attach exits cleanly (the user detached inside the TUI) or
    /// after `end()`; finishes throwing if the channel dies.
    let output: AsyncThrowingStream<Data, any Error>
    private let input: TerminalAttachInputQueue
    private let onEndStarted: @Sendable () -> Void
    private let ender: @Sendable () async -> Void

    init(
        output: AsyncThrowingStream<Data, any Error>,
        input: TerminalAttachInputQueue,
        onEndStarted: @escaping @Sendable () -> Void = {},
        ender: @escaping @Sendable () async -> Void
    ) {
        self.output = output
        self.input = input
        self.onEndStarted = onEndStarted
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
        onEndStarted()
        input.finish()
        await ender()
    }
}
