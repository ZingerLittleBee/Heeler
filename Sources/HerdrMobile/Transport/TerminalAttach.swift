import Foundation

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

/// Input riding down a live Attach session. Keystrokes and resizes share one
/// ordered stream so a geometry change can never overtake the keystrokes
/// typed before it.
enum TerminalAttachInput: Sendable, Equatable {
    case keystrokes(Data)
    case resize(cols: Int, rows: Int)
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
    private let input: AsyncStream<TerminalAttachInput>.Continuation
    private let ender: @Sendable () async -> Void

    init(
        output: AsyncThrowingStream<Data, any Error>,
        input: AsyncStream<TerminalAttachInput>.Continuation,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.output = output
        self.input = input
        self.ender = ender
    }

    /// Forwards raw keystroke bytes to the remote PTY. Fire-and-forget: a
    /// dead channel drops them, and the death surfaces on `output`.
    func send(_ keystrokes: Data) {
        guard !keystrokes.isEmpty else { return }
        input.yield(.keystrokes(keystrokes))
    }

    /// Propagates a terminal geometry change (rotation, split view) to the
    /// remote PTY via SSH window-change; no reattach needed.
    func resize(cols: Int, rows: Int) {
        input.yield(.resize(cols: cols, rows: rows))
    }

    /// Closes the terminal channel explicitly and waits for its teardown;
    /// `output` then finishes without error. Idempotent.
    func end() async {
        input.finish()
        await ender()
    }
}
