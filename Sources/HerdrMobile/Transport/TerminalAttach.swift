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

/// The handshake that separates an attach channel's two halves.
///
/// The channel is a login shell with a PTY (Citadel offers no exec-with-PTY
/// path), so before the bootstrap line can run, the shell has already printed
/// its banner and its prompt and echoed the line back. None of that belongs on
/// the terminal: it would paint for as long as the remote attach takes to come
/// up and then be wiped by the TUI's first frame — a flash of somebody else's
/// output on every attach.
///
/// So the bootstrap prints a marker of its own just before it execs attach,
/// and everything up to it is dropped. Printing it as real control bytes is
/// what makes it unambiguous: the shell's echo of the very line that prints it
/// carries the literal text `\033`, never an ESC byte, so the marker cannot
/// match its own echo. APC is the one string terminals are required to ignore,
/// which keeps a stray copy harmless.
enum AttachBootstrapHandshake {
    static let marker = Data("\u{1B}_herdr-mobile-attach\u{1B}\\".utf8)
    /// `marker` as a `printf` format. Octal throughout: the format has to
    /// survive the Host's login shell (fish included) and `/bin/sh` before
    /// printf ever sees it, and octal escapes are the portable spelling.
    static let markerPrintfFormat = "\\033_herdr-mobile-attach\\033\\134"
}

/// Holds an attach channel's output back until the bootstrap handshake lands.
///
/// The withheld bytes are buffered rather than dropped: a channel that dies
/// before the handshake (herdr missing from the Host's PATH, a login shell
/// that cannot run the bootstrap) has said everything it is ever going to say
/// in exactly that noise, so `flush()` hands it back as the diagnosis.
struct AttachBootstrapGate {
    /// A ceiling for a channel that never handshakes. The tail is what
    /// carries the failure, and it stays far longer than the marker, so a
    /// marker split across chunks still matches after a trim.
    static let maximumWithheldBytes = 8 * 1024

    private(set) var isOpen = false
    private var withheld = Data()

    /// The bytes the terminal should paint: nothing until the marker arrives,
    /// everything after it once it has.
    mutating func admit(_ bytes: Data) -> Data {
        if isOpen { return bytes }
        withheld.append(bytes)
        guard let marker = withheld.range(of: AttachBootstrapHandshake.marker) else {
            if withheld.count > Self.maximumWithheldBytes {
                withheld = Data(withheld.suffix(Self.maximumWithheldBytes))
            }
            return Data()
        }
        isOpen = true
        let session = Data(withheld[marker.upperBound...])
        withheld = Data()
        return session
    }

    /// The withheld noise, for a channel that ended before it handshook.
    /// Empty once the gate is open — by then the noise is long past.
    mutating func flush() -> Data {
        guard !isOpen else { return Data() }
        defer { withheld = Data() }
        return withheld
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
