import Foundation
import Observation

typealias TerminalSessionOperation =
    @MainActor @Sendable (TerminalAttachSession) async throws -> Void
typealias TerminalSessionRunner =
    @Sendable (TerminalAttachRequest, TerminalSessionHandler) async throws -> Void

struct TerminalSessionHandler: Sendable {
    private let operation: TerminalSessionOperation

    init(_ operation: @escaping TerminalSessionOperation) {
        self.operation = operation
    }

    @MainActor
    func run(_ session: TerminalAttachSession) async throws {
        try await operation(session)
    }
}

/// The Agent detail screen's session pipeline: a full interactive terminal
/// over the Host's terminal channel — raw PTY bytes into the view through a
/// `TerminalByteFeed`, keystrokes back out, geometry changes as SSH
/// window-change on the live channel.
///
/// Nothing starts until the terminal view's first size report (the PTY opens
/// with real cols/rows). A later resize never
/// restarts anything: it rides in-band, which is the whole point of the PTY.
/// One session per run; the remote attach exiting (the user detached inside
/// the TUI, the pane closed) surfaces as `.ended` with reattach offered.
@MainActor
@Observable
final class AttachTerminalStore {
    enum Status: Equatable {
        /// Waiting for the terminal view's first layout to report cols/rows.
        case waitingForSize
        /// Opening the attach channel, and waiting for the remote attach to
        /// say something. Nothing is on the terminal yet.
        case connecting
        /// The session has painted; bytes are flowing both ways.
        case live
        /// The session ended remotely (clean detach or channel death); the
        /// message is user-facing and `retry()` reattaches.
        case ended(String)
        /// `stop()` was called; terminal.
        case stopped
    }

    /// How long a session that was asked to repaint gets to answer before it
    /// is declared unresponsive.
    ///
    /// Generous on purpose. Being wrong costs the user a Reattach, and a full
    /// TUI frame over a weak link is not instant; being right is the
    /// difference between a screen that says something and one that says
    /// nothing at all.
    static let defaultLivenessProbeTimeout: Duration = .seconds(5)

    /// What the screen says when the remote never answered the repaint. The
    /// Reattach button beside it is the guidance; the message only has to
    /// stop the user from believing they are looking at a live terminal.
    static let unresponsiveMessage = "The terminal stopped responding while the app was away."

    private(set) var status: Status = .waitingForSize
    /// The byte pipe the terminal view consumes.
    let feed = TerminalByteFeed()

    private let target: String
    private let takeover: Bool
    private let livenessProbeTimeout: Duration
    private let input: TerminalInputController
    private let observeOutput: @MainActor @Sendable (Data) -> Void
    private let finishOutput: @MainActor @Sendable () -> Void
    /// Opens and owns exclusive Host terminal access for one complete run,
    /// including explicit channel teardown.
    private let runTerminal: TerminalSessionRunner

    private var cols: Int?
    private var rows: Int?
    private var stopRequested = false
    private var session: TerminalAttachSession?
    private var inputGeneration: TerminalInputController.SessionGeneration?
    private var runTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var probeGeneration: UInt64 = 0
    /// Set by a probe that went unanswered, so the ending `run()` reports
    /// what actually happened rather than the ordinary detach wording.
    private var pendingEndMessage: String?

    init(
        target: String, takeover: Bool = false,
        livenessProbeTimeout: Duration = AttachTerminalStore.defaultLivenessProbeTimeout,
        input: TerminalInputController = TerminalInputController(),
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.target = target
        self.takeover = takeover
        self.livenessProbeTimeout = livenessProbeTimeout
        self.input = input
        self.observeOutput = observeOutput
        self.finishOutput = finishOutput
        self.runTerminal = runTerminal
    }

    /// The terminal view's geometry, reported on first layout and on every
    /// change (rotation, split view, keyboard). The first report opens the
    /// session; later changes ride the live channel as window-change.
    func viewDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        if runTask == nil {
            if status == .waitingForSize {
                start()
            }
            // .ended waits for retry(); .stopped is terminal.
        } else {
            session?.resize(cols: cols, rows: rows)
        }
    }

    /// Keystrokes from the terminal view, forwarded raw. Dropped while no
    /// session is live — there is nothing to type into yet.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// The app returned to the foreground.
    ///
    /// A session that was `.live` when the app went away comes back with no
    /// way to tell a dead channel from a quiet agent. `herdr agent attach` is
    /// ratatui: it repaints on change, never on a timer, so silence is its
    /// normal steady state — and the transport's attach reader treats every
    /// read timeout as idle, so silence never ends the output stream either.
    /// `.live` draws no overlay, so the screen shows nothing, says nothing,
    /// and offers nothing to reconnect (#141).
    ///
    /// Asking the remote PTY to repaint is the one liveness signal that does
    /// not wait on the agent, and it doubles as the repair: a live TUI
    /// answers a window-change with a full frame, which is exactly what a
    /// surface that came back empty is missing. Silence past the deadline is
    /// the answer instead, and it ends the session visibly.
    func didBecomeActive() {
        guard status == .live, let session, let cols, let rows, cols > 1 else { return }
        beginProbe()
        // A window-change only reaches the remote when the size actually
        // changes, so the nudge is a shrink followed by a restore. Both ride
        // the reliable input queue, in order, on the live channel; the
        // store's own geometry is untouched, so a later real resize still
        // compares against what the view last reported.
        session.resize(cols: cols - 1, rows: rows)
        session.resize(cols: cols, rows: rows)
    }

    /// Reattaches after the session ended remotely.
    func retry() {
        guard case .ended = status, runTask == nil else { return }
        start()
    }

    /// Ends the session by explicit close (a live exec channel ignores task
    /// cancellation, ADR 0011) and waits for the teardown. Terminal: the
    /// detail screen creates a fresh store after a Host reconnect.
    ///
    /// The run task is also cancelled: before a session exists it can be
    /// queued for the Host's terminal channel, and teardown must abort that
    /// wait rather than sit behind whoever holds the channel — a stop must
    /// never depend on the channel becoming available.
    func stop() async {
        stopRequested = true
        endProbe()
        if let session {
            await session.end()
        }
        if let task = runTask {
            task.cancel()
            await task.value
        }
        status = .stopped
    }

    private func start() {
        endProbe()
        pendingEndMessage = nil
        status = .connecting
        runTask = Task { await self.run() }
    }

    /// Arms the deadline the remote has to answer a repaint request within.
    /// The generation makes a late timeout from a superseded probe harmless.
    private func beginProbe() {
        probeTask?.cancel()
        probeGeneration &+= 1
        let generation = probeGeneration
        probeTask = Task { [weak self, livenessProbeTimeout] in
            try? await Task.sleep(for: livenessProbeTimeout)
            guard !Task.isCancelled else { return }
            await self?.probeDeadlineDidPass(generation)
        }
    }

    private func endProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeGeneration &+= 1
    }

    /// Nothing came back. The channel cannot be proven, so the session ends
    /// where the user can see it instead of staying `.live` and blank. The
    /// explicit close is what makes `run()` finish and report.
    private func probeDeadlineDidPass(_ generation: UInt64) async {
        guard generation == probeGeneration, status == .live, let session else { return }
        probeTask = nil
        pendingEndMessage = Self.unresponsiveMessage
        await session.end()
    }

    /// One session lifetime: open at the current geometry, pump output until
    /// the stream ends, surface how it ended.
    private func run() async {
        defer { runTask = nil }
        guard let cols, let rows else { return }
        do {
            try await runTerminal(
                TerminalAttachRequest(
                    target: target, takeover: takeover, cols: cols, rows: rows),
                TerminalSessionHandler { [weak self] session in
                    guard let self else {
                        await session.end()
                        return
                    }
                    try await self.consume(
                        session, initialCols: cols, initialRows: rows)
                })
        } catch {
            guard !stopRequested else { return }
            status = .ended(Self.message(for: error))
            return
        }
        guard !stopRequested else { return }
        status = .ended(pendingEndMessage ?? "The session ended.")
    }

    private func consume(
        _ session: TerminalAttachSession,
        initialCols: Int,
        initialRows: Int
    ) async throws {
        defer { finishOutput() }
        if stopRequested {
            await session.end()
            return
        }
        self.session = session
        let inputGeneration = input.beginSession(
            writer: { data in session.send(data) },
            scroller: { sequence, rows in
                session.scroll(sequence, rows: rows)
            })
        self.inputGeneration = inputGeneration
        if let latestCols = cols, let latestRows = rows,
            latestCols != initialCols || latestRows != initialRows
        {
            // The view resized while the channel was coming up; catch the
            // remote PTY up to the latest geometry.
            session.resize(cols: latestCols, rows: latestRows)
        }

        do {
            for try await bytes in session.output {
                // Live when the session has something to show, not when the
                // channel opens: the transport withholds the login shell's
                // noise, so an open channel with nothing on it yet is still a
                // blank screen. "Connecting…" stays up until the remote attach
                // paints.
                if status == .connecting {
                    status = .live
                }
                // Any byte is the proof an outstanding probe was waiting for.
                if probeTask != nil { endProbe() }
                observeOutput(bytes)
                feed.write(bytes)
            }
        } catch {
            finishSession(inputGeneration)
            throw error
        }
        finishSession(inputGeneration)
    }

    private func finishSession(_ inputGeneration: TerminalInputController.SessionGeneration) {
        self.session = nil
        input.endSession(inputGeneration)
        if self.inputGeneration == inputGeneration {
            self.inputGeneration = nil
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.terminalChannelAlreadyOpen:
            "Another terminal is already open on this Host."
        case TransportError.timedOut:
            "The Host did not answer in time."
        default:
            "The session failed: \(error)"
        }
    }
}
