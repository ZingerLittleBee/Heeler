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
        /// Opening the attach channel.
        case connecting
        /// Bytes are flowing both ways.
        case live
        /// The session ended remotely (clean detach or channel death); the
        /// message is user-facing and `retry()` reattaches.
        case ended(String)
        /// `stop()` was called; terminal.
        case stopped
    }

    private(set) var status: Status = .waitingForSize
    /// The byte pipe the terminal view consumes.
    let feed = TerminalByteFeed()

    private let target: String
    private let takeover: Bool
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

    init(
        target: String, takeover: Bool = false,
        input: TerminalInputController = TerminalInputController(),
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.target = target
        self.takeover = takeover
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

    /// Reattaches after the session ended remotely.
    func retry() {
        guard case .ended = status, runTask == nil else { return }
        start()
    }

    /// Ends the session by explicit close (a live exec channel ignores task
    /// cancellation, ADR 0002) and waits for the teardown. Terminal: the
    /// The detail screen creates a fresh store after a Host reconnect.
    func stop() async {
        stopRequested = true
        if let session {
            await session.end()
        }
        if let task = runTask {
            await task.value
        }
        status = .stopped
    }

    private func start() {
        status = .connecting
        runTask = Task { await self.run() }
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
        status = .ended("The session ended.")
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
        status = .live
        if let latestCols = cols, let latestRows = rows,
            latestCols != initialCols || latestRows != initialRows
        {
            // The view resized while the channel was coming up; catch the
            // remote PTY up to the latest geometry.
            session.resize(cols: latestCols, rows: latestRows)
        }

        do {
            for try await bytes in session.output {
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
