import Foundation

/// Walks the Attach viewport between user messages by scrolling the *remote*
/// TUI and reading the frames it repaints.
///
/// Why this shape. `herdr terminal attach` puts the iOS surface on the
/// alternate screen, where libghostty keeps `max_scrollback = 0` and every
/// local scroll API is a no-op. The conversation history therefore lives only
/// inside the remote TUI's own model. It is still reachable: touch scrolling
/// already forwards SGR wheel reports to that TUI, which repaints, and the
/// repainted frame arrives as ordinary Attach output. So a jump is a loop —
/// push a scroll step, wait for the frame, look at it, repeat.
///
/// Two consequences shape the contract. The loop is **open**: the app cannot
/// learn how many rows a wheel report actually moved, only what came back, so
/// termination is decided from frame content rather than from a row count. And
/// the scroll position is **remote state**, so a jump also moves the same
/// terminal in a desktop herdr window.
///
/// See `docs/research/agent-attach-message-navigation.md`.
///
/// Contract only. `refs #268`.
@MainActor
final class TerminalMessageJumpController {
    enum Direction: Equatable {
        /// Back through the conversation, toward earlier output.
        case older
        /// Forward, toward live output.
        case newer
    }

    enum Outcome: Equatable {
        /// A frame satisfying `matches` was reached.
        case found
        /// The frame stopped changing before a match — the top of the remote
        /// TUI's history, or the live bottom.
        case reachedEnd
        /// The step budget ran out with the frame still moving.
        case exhausted
        /// `cancel()` was called, or the session went away mid-jump.
        case cancelled
    }

    struct Configuration: Equatable {
        /// Rows requested per step. Larger means fewer round trips and
        /// coarser landing.
        var rowsPerStep: Int = 6
        /// Upper bound on steps in one jump.
        var maxSteps: Int = 40
        /// How long to wait for a repainted frame before treating the step as
        /// having produced nothing.
        var frameSettleTimeout: Duration = .milliseconds(600)
        /// Consecutive identical frames that mean the end was reached.
        var unchangedFramesBeforeEnd: Int = 2

        init() {}
    }

    /// - Parameters:
    ///   - step: Pushes one scroll step at the remote TUI. The `Int` is the
    ///     row count; the implementation is the same path a drag uses.
    ///   - matches: Whether a frame carries a user message. Supplied by
    ///     `AttachUserMessageIndex.frameContainsMessage(_:)`.
    ///   - sleep: Injected so tests do not wait in real time.
    init(
        configuration: Configuration = Configuration(),
        step: @escaping @MainActor (Direction, Int) -> Void,
        matches: @escaping @MainActor (String) -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.configuration = configuration
        self.step = step
        self.matches = matches
        self.sleep = sleep
    }

    let configuration: Configuration
    private let step: @MainActor (Direction, Int) -> Void
    private let matches: @MainActor (String) -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void

    /// True between `jump`/`returnToLive` being called and returning. The UI
    /// uses it to disable its controls; a second call while running must not
    /// interleave two loops.
    private(set) var isRunning = false

    /// Fed from the existing viewport-text tap
    /// (`TerminalScreenView.reportViewportText`). Calling this while no jump
    /// is running is legal and cheap.
    func frameDidChange(_ text: String) {
        // TODO(#268): implement in package msgnav-loop.
    }

    /// Moves to the neighbouring user message.
    ///
    /// Edge semantics, which is what makes repeated presses walk: if the frame
    /// on entry already satisfies `matches`, keep stepping until it stops
    /// doing so, and only then look for the next frame that does. Always take
    /// at least one step.
    func jump(_ direction: Direction) async -> Outcome {
        // TODO(#268): implement in package msgnav-loop.
        .cancelled
    }

    /// Scrolls forward until the frame stops changing — the live bottom.
    /// Reports `.reachedEnd` on success; `matches` is not consulted.
    func returnToLive() async -> Outcome {
        // TODO(#268): implement in package msgnav-loop.
        .cancelled
    }

    /// Ends an in-flight jump. The awaiting call returns `.cancelled`.
    func cancel() {
        // TODO(#268): implement in package msgnav-loop.
    }
}
