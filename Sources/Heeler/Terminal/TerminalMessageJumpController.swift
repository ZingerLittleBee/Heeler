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
/// `refs #268`.
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

    /// Most recent viewport text, including frames delivered while idle.
    private var latestFrame = ""
    /// Set by `cancel()` or task cancellation; cleared when a run finishes.
    private var cancelRequested = false

    /// Whether the current step is accepting `frameDidChange` deliveries.
    private var isAwaitingFrame = false
    /// Latest frame that arrived after `step` but before the wait armed.
    private var bufferedFrame: String?
    private var pendingFrameWait: CheckedContinuation<FrameWaitResult, Never>?
    private var activeFrameWaitID: UUID?
    private var frameTimeoutTask: Task<Void, Never>?

    private enum FrameWaitResult: Equatable {
        case frame(String)
        case timedOut
        case cancelled
    }

    /// Edge-walk phases for `jump`. Modelled explicitly so a press that starts
    /// on a matching frame walks *off* it before hunting the next match.
    private enum JumpPhase: Equatable {
        /// Entry frame already matched; keep stepping until it does not.
        case leavingMatch
        /// Looking for the next frame that satisfies `matches`.
        case seekingMatch
    }

    /// Fed from the existing viewport-text tap
    /// (`TerminalScreenView.reportViewportText`). Calling this while no jump
    /// is running is legal and cheap.
    func frameDidChange(_ text: String) {
        latestFrame = text
        guard isAwaitingFrame else { return }
        if pendingFrameWait != nil {
            resumeFrameWait(with: .frame(text))
        } else {
            // Keep only the latest — a repaint burst must not queue waiters.
            bufferedFrame = text
        }
    }

    /// Moves to the neighbouring user message.
    ///
    /// Edge semantics, which is what makes repeated presses walk: if the frame
    /// on entry already satisfies `matches`, keep stepping until it stops
    /// doing so, and only then look for the next frame that does. Always take
    /// at least one step.
    func jump(_ direction: Direction) async -> Outcome {
        // Refuse reentrancy: a second call does not cancel or interleave the
        // in-flight loop. The UI gates on `isRunning`; this is the safety net.
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelRequested = false
        defer { finishRun() }

        var phase: JumpPhase = matches(latestFrame) ? .leavingMatch : .seekingMatch
        var previousFrame = latestFrame
        var unchangedCount = 0

        for _ in 0..<configuration.maxSteps {
            if isCancelPending { return .cancelled }

            beginAwaitingFrame()
            step(direction, configuration.rowsPerStep)

            switch await waitForFrame() {
            case .cancelled:
                return .cancelled
            case .timedOut:
                unchangedCount += 1
                if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                    return .reachedEnd
                }
            case .frame(let text):
                if text == previousFrame {
                    unchangedCount += 1
                    if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                        return .reachedEnd
                    }
                } else {
                    unchangedCount = 0
                    previousFrame = text
                    switch phase {
                    case .leavingMatch:
                        if !matches(text) {
                            phase = .seekingMatch
                        }
                    case .seekingMatch:
                        if matches(text) {
                            return .found
                        }
                    }
                }
            }
        }
        return .exhausted
    }

    /// Scrolls forward until the frame stops changing — the live bottom.
    /// Reports `.reachedEnd` on success; `matches` is not consulted.
    func returnToLive() async -> Outcome {
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelRequested = false
        defer { finishRun() }

        var previousFrame = latestFrame
        var unchangedCount = 0

        for _ in 0..<configuration.maxSteps {
            if isCancelPending { return .cancelled }

            beginAwaitingFrame()
            step(.newer, configuration.rowsPerStep)

            switch await waitForFrame() {
            case .cancelled:
                return .cancelled
            case .timedOut:
                unchangedCount += 1
                if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                    return .reachedEnd
                }
            case .frame(let text):
                if text == previousFrame {
                    unchangedCount += 1
                    if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                        return .reachedEnd
                    }
                } else {
                    unchangedCount = 0
                    previousFrame = text
                }
            }
        }
        return .exhausted
    }

    /// Ends an in-flight jump. The awaiting call returns `.cancelled`.
    func cancel() {
        cancelRequested = true
        resumeFrameWait(with: .cancelled)
    }

    private var isCancelPending: Bool {
        cancelRequested || Task.isCancelled
    }

    private func finishRun() {
        isAwaitingFrame = false
        bufferedFrame = nil
        frameTimeoutTask?.cancel()
        frameTimeoutTask = nil
        // Drop a stranded waiter rather than resume it twice from defer + cancel.
        if let pending = pendingFrameWait {
            pendingFrameWait = nil
            activeFrameWaitID = nil
            pending.resume(returning: .cancelled)
        }
        activeFrameWaitID = nil
        cancelRequested = false
        isRunning = false
    }

    private func beginAwaitingFrame() {
        isAwaitingFrame = true
        bufferedFrame = nil
    }

    private func waitForFrame() async -> FrameWaitResult {
        if isCancelPending {
            isAwaitingFrame = false
            bufferedFrame = nil
            return .cancelled
        }

        if let buffered = bufferedFrame {
            bufferedFrame = nil
            isAwaitingFrame = false
            return .frame(buffered)
        }

        let waitID = UUID()
        activeFrameWaitID = waitID

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FrameWaitResult, Never>) in
                if self.isCancelPending {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let buffered = self.bufferedFrame {
                    self.bufferedFrame = nil
                    continuation.resume(returning: .frame(buffered))
                    return
                }
                // Exactly one waiter slot — replace would mean a nested wait bug.
                if let stranded = self.pendingFrameWait {
                    self.pendingFrameWait = nil
                    stranded.resume(returning: .cancelled)
                }
                self.pendingFrameWait = continuation

                self.frameTimeoutTask?.cancel()
                self.frameTimeoutTask = Task { @MainActor in
                    do {
                        try await self.sleep(self.configuration.frameSettleTimeout)
                    } catch {
                        return
                    }
                    guard self.activeFrameWaitID == waitID else { return }
                    self.resumeFrameWait(with: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelRequested = true
                guard self.activeFrameWaitID == waitID else { return }
                self.resumeFrameWait(with: .cancelled)
            }
        }

        isAwaitingFrame = false
        bufferedFrame = nil
        if activeFrameWaitID == waitID {
            activeFrameWaitID = nil
        }
        return result
    }

    /// Resumes the pending frame waiter at most once.
    private func resumeFrameWait(with result: FrameWaitResult) {
        guard let pending = pendingFrameWait else { return }
        pendingFrameWait = nil
        activeFrameWaitID = nil
        frameTimeoutTask?.cancel()
        frameTimeoutTask = nil
        pending.resume(returning: result)
    }
}
