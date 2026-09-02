import Foundation

/// How ``TerminalMessageJumpController/jump(_:)`` decides it has reached the
/// neighbouring user message.
///
/// The controller never inspects agent kind. Callers pick a policy when the
/// wiring is constructed.
enum TerminalMessageJumpPolicy: Equatable, Sendable {
    /// Remember the identities on screen at the press and stop when a
    /// different one appears. The walk only ever moves one way, so that new
    /// identity is the neighbour.
    case neighborAppearance

    /// A TUI that pins the current turn's prompt at the top of the viewport.
    /// That identity is already on screen at live bottom, so neighbor
    /// appearance walks past it. Walk older until the identity changes, then
    /// reverse newer in one-row steps until it returns — but only if the jump
    /// first traveled through frames that still showed it. Without that
    /// travel, the press already sat on the turn boundary and the new
    /// identity is the neighbour (repeated Up).
    case stickyPromptOvershoot
}

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
        /// Rows requested by the opening steps. Small, so a message just above
        /// the fold lands near the top of the screen instead of wherever a
        /// page-sized jump happens to drop it.
        var rowsPerStep: Int = 8
        /// How many steps stay at `rowsPerStep` before the ramp starts.
        var fineSteps: Int = 2
        /// Multiplier applied to the step size once the ramp starts. Doubling
        /// turns a crawl into a page-per-step within a few round trips, which
        /// is what makes a distant message reachable in one press.
        var stepGrowth: Int = 2
        /// Ceiling on a single step when the viewport height is unknown.
        /// A step must never exceed the viewport, or rows scroll past without
        /// ever being rendered and a message in the gap is missed. This is the
        /// conservative stand-in for a short grid.
        var maximumRowsPerStep: Int = 16
        /// Upper bound on steps in one jump.
        var maxSteps: Int = 60
        /// How long to wait for a repainted frame before treating the step as
        /// having produced nothing.
        var frameSettleTimeout: Duration = .milliseconds(600)
        /// Consecutive identical frames that mean the end was reached.
        var unchangedFramesBeforeEnd: Int = 2

        init() {}
    }

    /// - Parameters:
    ///   - policy: Walk rule for one jump. Default is neighbor appearance.
    ///   - step: Pushes one scroll step at the remote TUI. The `Int` is the
    ///     row count; the implementation is the same path a drag uses.
    ///   - visibleMessages: Stable identities of the user messages a frame
    ///     shows. Supplied by `AttachUserMessageIndex.visibleMessageKeys(_:)`.
    ///   - viewportRows: Rows the grid shows, or nil when unknown. Caps the
    ///     ramp so no row scrolls past unrendered.
    ///   - sleep: Injected so tests do not wait in real time.
    init(
        configuration: Configuration = Configuration(),
        policy: TerminalMessageJumpPolicy = .neighborAppearance,
        step: @escaping @MainActor (Direction, Int) -> Void,
        visibleMessages: @escaping @MainActor (String) -> Set<String>,
        viewportRows: @escaping @MainActor () -> Int? = { nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.configuration = configuration
        self.policy = policy
        self.step = step
        self.visibleMessages = visibleMessages
        self.viewportRows = viewportRows
        self.sleep = sleep
    }

    let configuration: Configuration
    let policy: TerminalMessageJumpPolicy
    private let step: @MainActor (Direction, Int) -> Void
    private let visibleMessages: @MainActor (String) -> Set<String>
    private let viewportRows: @MainActor () -> Int?
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Rows to request on step `index` (0-based).
    ///
    /// Flat for the first `fineSteps`, then geometric up to the ceiling. The
    /// ceiling is the live viewport when it is known — a full page is the
    /// largest step that still renders every row exactly once — and
    /// `maximumRowsPerStep` when it is not. Two rows of margin absorb a remote
    /// TUI that scrolls slightly more than it was asked for.
    func rows(forStep index: Int) -> Int {
        let ceiling: Int
        if let rows = viewportRows(), rows > 0 {
            ceiling = max(configuration.rowsPerStep, rows - 2)
        } else {
            ceiling = configuration.maximumRowsPerStep
        }
        guard index >= configuration.fineSteps, configuration.stepGrowth > 1 else {
            return min(configuration.rowsPerStep, ceiling)
        }
        var size = configuration.rowsPerStep
        for _ in 0..<(index - configuration.fineSteps + 1) {
            if size >= ceiling { break }
            size *= configuration.stepGrowth
        }
        return min(size, ceiling)
    }

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

    /// Test seam: awaited at the start of the enclosing-task cancel handler,
    /// before any wait-id check or shared-state write. Production leaves this
    /// nil. Tests hold the handler until a later jump's waiter is armed so a
    /// stale write is observable rather than assumed.
    var enclosingCancelHandlerBarrier: (@MainActor () async -> Void)?

    /// Test seam: invoked synchronously on the MainActor immediately after the
    /// cancel handler's wait-id / `cancelRequested` region — including the
    /// early-return path — so a test can observe that the poison window has
    /// actually run, not merely that a barrier actor released. Nil in production.
    var enclosingCancelHandlerDidPassPoisonWindow: (@MainActor () -> Void)?

    private enum FrameWaitResult: Equatable {
        case frame(String)
        case timedOut
        case cancelled
    }

    /// Fed from the existing viewport-text tap
    /// (`TerminalScreenView.reportViewportText`). Calling this while no jump
    /// is running is legal and cheap.
    func frameDidChange(_ text: String) {
        latestFrame = text
        guard isAwaitingFrame else { return }
        // Always keep the latest paint. A burst resumes the waiter on the first
        // call, but `waitForFrame` decides on this buffer so later paints in the
        // same turn are not discarded.
        bufferedFrame = text
        if pendingFrameWait != nil {
            resumeFrameWait(with: .frame(text))
        }
    }

    /// Moves to the neighbouring user message.
    ///
    /// Default walk (``TerminalMessageJumpPolicy/neighborAppearance``):
    /// remember which messages were already on screen when the press landed,
    /// then step until a message that was *not* among them comes into view.
    /// Because the loop only ever moves one way, a newly appearing message is
    /// necessarily the neighbour in that direction, and repeated presses walk
    /// without any extra bookkeeping.
    ///
    /// Sticky-prompt walk (``TerminalMessageJumpPolicy/stickyPromptOvershoot``)
    /// applies only when moving older: a pinned current-turn prompt is already
    /// "seen" at live bottom, so neighbor appearance would skip it. After the
    /// identity changes, the loop reverses newer in one-row steps until the
    /// original prompt returns, and never walks older again in the same jump
    /// (one overshoot, one reverse — no oscillation). Overshoot and reverse
    /// share the one ``Configuration/maxSteps`` budget; they also stop on the
    /// same unchanged-frame end and cancellation rules. Requested row counts
    /// do not bound the reverse: one step is not one observed frame.
    ///
    /// This replaced an earlier rule that stepped until *no* message matched
    /// before hunting the next one. On a phone the viewport holds tens of
    /// rows, so several consecutive messages are on screen together and that
    /// rule scrolled past all of them (verified on a live agent TUI, #268).
    func jump(_ direction: Direction) async -> Outcome {
        // Refuse reentrancy: a second call does not cancel or interleave the
        // in-flight loop. The UI gates on `isRunning`; this is the safety net.
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelRequested = false
        defer { finishRun() }

        if policy == .stickyPromptOvershoot, direction == .older {
            let entryMessages = visibleMessages(latestFrame)
            if !entryMessages.isEmpty {
                return await jumpOlderStickyPrompt(entryMessages: entryMessages)
            }
        }
        return await jumpNeighbor(direction)
    }

    /// One-row reverse after an overshoot. Actual remote movement is not
    /// knowable from the request, so reverse stays at one row and runs until
    /// the original prompt returns or the shared step/end/cancel budget fires.
    private static let stickyReverseRowsPerStep = 1

    /// Neighbor-appearance walk. Extracted so sticky overshoot can share the
    /// same frame-wait helper without changing this loop's decision rule.
    private func jumpNeighbor(_ direction: Direction) async -> Outcome {
        var seenMessages = visibleMessages(latestFrame)
        var previousFrame = latestFrame
        var unchangedCount = 0

        for index in 0..<configuration.maxSteps {
            if isCancelPending { return .cancelled }

            switch await observeStep(
                direction,
                rows: rows(forStep: index),
                previousFrame: &previousFrame,
                unchangedCount: &unchangedCount)
            {
            case .cancelled:
                return .cancelled
            case .reachedEnd:
                return .reachedEnd
            case .unchanged:
                continue
            case .moved(let text):
                let messages = visibleMessages(text)
                if !messages.subtracting(seenMessages).isEmpty {
                    return .found
                }
                seenMessages.formUnion(messages)
            }
        }
        return .exhausted
    }

    /// Older walk for a pinned current-turn prompt. See
    /// ``TerminalMessageJumpPolicy/stickyPromptOvershoot``.
    private func jumpOlderStickyPrompt(entryMessages: Set<String>) async -> Outcome {
        var previousFrame = latestFrame
        var unchangedCount = 0
        var reversing = false
        var traveledThroughEntry = false
        var olderStepIndex = 0

        for _ in 0..<configuration.maxSteps {
            if isCancelPending { return .cancelled }

            let stepDirection: Direction
            let stepRows: Int
            if reversing {
                stepDirection = .newer
                stepRows = Self.stickyReverseRowsPerStep
            } else {
                stepDirection = .older
                stepRows = rows(forStep: olderStepIndex)
                olderStepIndex += 1
            }

            switch await observeStep(
                stepDirection,
                rows: stepRows,
                previousFrame: &previousFrame,
                unchangedCount: &unchangedCount)
            {
            case .cancelled:
                return .cancelled
            case .reachedEnd:
                return .reachedEnd
            case .unchanged:
                continue
            case .moved(let text):
                let messages = visibleMessages(text)
                if reversing {
                    if !messages.isDisjoint(with: entryMessages) {
                        return .found
                    }
                    continue
                }

                let newMessages = messages.subtracting(entryMessages)
                let entryStillVisible = !messages.isDisjoint(with: entryMessages)
                if entryStillVisible {
                    if !newMessages.isEmpty {
                        return .found
                    }
                    traveledThroughEntry = true
                    continue
                }
                if messages.isEmpty {
                    continue
                }
                if traveledThroughEntry {
                    reversing = true
                    continue
                }
                return .found
            }
        }
        return .exhausted
    }

    private enum StepObservation: Equatable {
        case cancelled
        case reachedEnd
        case unchanged
        case moved(String)
    }

    /// Pushes one scroll step and classifies the resulting frame. Timeouts
    /// and identical frames count toward ``Configuration/unchangedFramesBeforeEnd``
    /// the same way in every walk.
    private func observeStep(
        _ direction: Direction,
        rows: Int,
        previousFrame: inout String,
        unchangedCount: inout Int
    ) async -> StepObservation {
        beginAwaitingFrame()
        step(direction, rows)
        switch await waitForFrame() {
        case .cancelled:
            return .cancelled
        case .timedOut:
            unchangedCount += 1
            if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                return .reachedEnd
            }
            return .unchanged
        case .frame(let text):
            if text == previousFrame {
                unchangedCount += 1
                if unchangedCount >= configuration.unchangedFramesBeforeEnd {
                    return .reachedEnd
                }
                return .unchanged
            }
            unchangedCount = 0
            previousFrame = text
            return .moved(text)
        }
    }

    /// Scrolls forward until the frame stops changing — the live bottom.
    /// Reports `.reachedEnd` on success; `visibleMessages` is not consulted.
    func returnToLive() async -> Outcome {
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelRequested = false
        defer { finishRun() }

        var previousFrame = latestFrame
        var unchangedCount = 0

        for index in 0..<configuration.maxSteps {
            if isCancelPending { return .cancelled }

            beginAwaitingFrame()
            step(.newer, rows(forStep: index))

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
            // Cancel wins over a frame that arrived before the wait armed.
            if isCancelPending { return .cancelled }
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
                if let barrier = self.enclosingCancelHandlerBarrier {
                    await barrier()
                }
                // The post-window seam must fire even when the guard returns
                // early, so a test can wait for this region to have run.
                defer { self.enclosingCancelHandlerDidPassPoisonWindow?() }
                // Establish ownership before touching shared state. A delayed
                // handler from a finished run must not set `cancelRequested` on
                // a later jump that reuses this controller.
                guard self.activeFrameWaitID == waitID else { return }
                self.cancelRequested = true
                self.resumeFrameWait(with: .cancelled)
            }
        }

        // Prefer the latest paint observed during this await. The first
        // `frameDidChange` wakes the waiter; later calls in the same burst only
        // update `bufferedFrame`, which must still decide the step.
        let resolved: FrameWaitResult
        if isCancelPending {
            // `cancel()` / task cancel wins even when a frame already resumed us.
            resolved = .cancelled
        } else if case .frame = result {
            resolved = .frame(bufferedFrame ?? latestFrame)
        } else {
            resolved = result
        }

        isAwaitingFrame = false
        bufferedFrame = nil
        if activeFrameWaitID == waitID {
            activeFrameWaitID = nil
        }
        return resolved
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
