import Foundation
import Observation

/// The Attach screen's session pipeline (#11): a full interactive terminal
/// over the Host's terminal channel — raw PTY bytes into the view through a
/// `TerminalByteFeed`, keystrokes back out, geometry changes as SSH
/// window-change on the live channel.
///
/// Like Observe, nothing starts until the terminal view's first size report
/// (the PTY opens with real cols/rows). Unlike Observe, a later resize never
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
    /// The Host's current transport, re-queried per (re)attach: the events
    /// session underneath may have reconnected onto a fresh one.
    private let transport: @Sendable () async -> (any Transport)?

    private var cols: Int?
    private var rows: Int?
    private var stopRequested = false
    private var session: TerminalAttachSession?
    private var runTask: Task<Void, Never>?

    init(
        target: String, takeover: Bool = false,
        transport: @escaping @Sendable () async -> (any Transport)?
    ) {
        self.target = target
        self.takeover = takeover
        self.transport = transport
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
        session?.send(keystrokes)
    }

    /// Reattaches after the session ended remotely.
    func retry() {
        guard case .ended = status, runTask == nil else { return }
        start()
    }

    /// Ends the session by explicit close (a live exec channel ignores task
    /// cancellation, ADR 0002) and waits for the teardown. Terminal: the
    /// Attach screen creates a fresh store per visit.
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
        guard let transport = await transport() else {
            status = .ended("The Host is not connected.")
            return
        }
        guard let cols, let rows else { return }
        let session: TerminalAttachSession
        do {
            session = try await transport.attachTerminal(
                TerminalAttachRequest(target: target, takeover: takeover, cols: cols, rows: rows))
        } catch {
            guard !stopRequested else { return }
            status = .ended(Self.message(for: error))
            return
        }
        if stopRequested {
            await session.end()
            return
        }
        self.session = session
        status = .live
        if let latestCols = self.cols, let latestRows = self.rows,
            latestCols != cols || latestRows != rows
        {
            // The view resized while the channel was coming up; catch the
            // remote PTY up to the latest geometry.
            session.resize(cols: latestCols, rows: latestRows)
        }

        var failure: (any Error)?
        do {
            for try await bytes in session.output {
                feed.write(bytes)
            }
        } catch {
            failure = error
        }
        self.session = nil
        guard !stopRequested else { return }
        status = .ended(failure.map(Self.message(for:)) ?? "The session ended.")
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.terminalChannelAlreadyOpen:
            "Another terminal is already open on this Host."
        case TransportError.timedOut:
            "The Host did not answer in time."
        default:
            "The session failed: \(error)"
        }
    }
}

/// Object identity (the default `id` for classes) is the full-screen-cover
/// presentation identity: every Observe -> Attach handover mints a fresh
/// store.
extension AttachTerminalStore: Identifiable {}
