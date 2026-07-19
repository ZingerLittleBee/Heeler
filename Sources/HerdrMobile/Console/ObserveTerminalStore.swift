import Foundation
import Observation

/// The Agent detail screen's Observe pipeline (#9): render the Pane's logical
/// transcript from `pane.read --format ansi --source recent-unwrapped`, then
/// use the terminal stream as a low-latency change signal. Each coalesced
/// refresh replaces the local SwiftTerm screen, where long PC-width lines can
/// wrap to the phone instead of being cropped by a narrow server-side frame.
///
/// The store is driven by the terminal view's geometry: nothing starts until
/// the first size report (the observe command needs cols/rows), and a
/// changed size restarts the live-follow. Sequence gaps also restart the
/// stream so future change signals remain trustworthy. Observe is read-only
/// (CONTEXT.md): no input path exists here.
@MainActor
@Observable
final class ObserveTerminalStore {
    enum Status: Equatable {
        /// Waiting for the terminal view's first layout to report cols/rows.
        case waitingForSize
        /// Backfilling or opening the observe stream.
        case connecting
        /// Frames are flowing.
        case live
        /// The pipeline died; `retry()` is the way back.
        case failed(String)
        /// `stop()` was called; terminal.
        case stopped
    }

    private(set) var status: Status = .waitingForSize
    /// The byte pipe the terminal view consumes.
    let feed = TerminalByteFeed()

    private let target: String
    /// The Host's current transport, re-queried per (re)start: the events
    /// session underneath may have reconnected onto a fresh one.
    private let transport: @Sendable () async -> (any Transport)?
    private let transcriptRefreshInterval: Duration

    private var cols: Int?
    private var rows: Int?
    private var didLoadInitialTranscript = false
    private var hasLoadedTranscript = false
    private var stopRequested = false
    private var restartRequested = false
    private var liveStream: TerminalFrameStream?
    private var runTask: Task<Void, Never>?
    private var transcriptRefreshTask: Task<Void, Never>?
    private var transcriptRefreshPending = false

    init(
        target: String, transcriptRefreshInterval: Duration = .milliseconds(150),
        transport: @escaping @Sendable () async -> (any Transport)?
    ) {
        self.target = target
        self.transcriptRefreshInterval = transcriptRefreshInterval
        self.transport = transport
    }

    /// The terminal view's geometry, reported on first layout and on every
    /// change (rotation, split view). The first report starts the pipeline;
    /// a change restarts the live-follow with the new size.
    func viewDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        if runTask == nil {
            if status == .waitingForSize {
                start()
            }
            // .failed waits for retry(); .stopped is terminal.
        } else {
            requestRestart()
        }
    }

    /// Restarts the pipeline after a failure.
    func retry() {
        guard case .failed = status, runTask == nil else { return }
        start()
    }

    /// Ends the live-follow by explicit close (a live exec channel ignores
    /// task cancellation, ADR 0002) and waits for the teardown. Terminal:
    /// the detail screen creates a fresh store per visit.
    func stop() async {
        stopRequested = true
        transcriptRefreshPending = false
        transcriptRefreshTask?.cancel()
        if let stream = liveStream {
            await stream.end()
        }
        if let task = runTask {
            await task.value
        }
        if let task = transcriptRefreshTask {
            await task.value
        }
        status = .stopped
    }

    private func start() {
        status = .connecting
        runTask = Task { await self.run() }
    }

    private func requestRestart() {
        restartRequested = true
        if let stream = liveStream {
            let stream = stream
            Task { await stream.end() }
        }
    }

    /// One pipeline lifetime: backfill once, then observe/consume/restart
    /// until stopped or failed. Exactly one run loop exists at a time.
    private func run() async {
        defer { runTask = nil }
        while !stopRequested {
            guard let transport = await transport() else {
                status = .failed("The Host is not connected.")
                return
            }
            if !didLoadInitialTranscript {
                didLoadInitialTranscript = true
                _ = await refreshTranscript(transport: transport, replacing: false)
                if stopRequested { return }
            }
            // The stream below opens with the latest geometry, satisfying
            // any restart requested while no stream was live; a resize
            // racing past this point is caught by the post-live dims check.
            restartRequested = false
            guard let cols, let rows else { return }
            let stream: TerminalFrameStream
            do {
                stream = try await transport.observeTerminal(
                    TerminalObserveRequest(target: target, cols: cols, rows: rows))
            } catch {
                guard !stopRequested else { return }
                status = .failed(Self.message(for: error))
                return
            }
            if stopRequested {
                await stream.end()
                return
            }
            liveStream = stream
            status = .live
            if cols != self.cols || rows != self.rows {
                // The view resized between the size capture and the stream
                // coming up; restart straight onto the fresh geometry.
                requestRestart()
            }

            var failure: (any Error)?
            var gapDetected = false
            var lastSeq: Int?
            do {
                for try await frame in stream.frames {
                    if let lastSeq, frame.seq != lastSeq + 1 {
                        // Dropped frames leave the screen undefined and the
                        // wire has no request-repaint; a fresh stream opens
                        // with a full repaint instead.
                        gapDetected = true
                        break
                    }
                    lastSeq = frame.seq
                    // The server renders this frame at the requested mobile
                    // width by cropping an already-laid-out PC terminal. Use
                    // it as a change signal, then fetch logical lines that
                    // SwiftTerm can wrap locally.
                    if !hasLoadedTranscript {
                        // Degrade to the raw frame while pane.read is failing;
                        // the next successful transcript refresh replaces it.
                        feed.write(frame.bytes)
                    }
                    requestTranscriptRefresh(transport: transport)
                }
            } catch {
                failure = error
            }
            if gapDetected {
                await stream.end()
                restartRequested = true
            }
            liveStream = nil
            if stopRequested {
                return
            }
            if restartRequested {
                restartRequested = false
                status = .connecting
                continue
            }
            status = .failed(
                failure.map(Self.message(for:)) ?? "The observe stream ended unexpectedly.")
            return
        }
    }

    /// Coalesces frame bursts into one immediate read plus at most one read
    /// per interval. The pending bit guarantees a final refresh after output
    /// becomes quiet without opening one SSH request per frame.
    private func requestTranscriptRefresh(transport: any Transport) {
        transcriptRefreshPending = true
        guard transcriptRefreshTask == nil else { return }
        transcriptRefreshTask = Task {
            await self.runTranscriptRefreshes(transport: transport)
        }
    }

    private func runTranscriptRefreshes(transport: any Transport) async {
        defer { transcriptRefreshTask = nil }
        while !Task.isCancelled, !stopRequested, transcriptRefreshPending {
            transcriptRefreshPending = false
            _ = await refreshTranscript(transport: transport, replacing: true)
            do {
                try await Task.sleep(for: transcriptRefreshInterval)
            } catch {
                return
            }
        }
    }

    /// Reads and renders the complete logical transcript. Failure is not
    /// fatal: the stream remains live and a later frame retries the read.
    @discardableResult
    private func refreshTranscript(transport: any Transport, replacing: Bool) async -> Bool {
        guard
            let read = try? await transport.readPane(
                PaneReadParams(paneID: target, source: .recentUnwrapped, format: .ansi))
        else { return false }
        guard !stopRequested else { return false }
        // pane.read joins lines with bare newlines; a raw-mode terminal
        // needs CR+LF or the lines stair-step.
        let normalized = read.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        var bytes = Data()
        if replacing {
            // Clear scrollback and the visible screen before painting the
            // latest snapshot, otherwise every refresh duplicates history.
            bytes.append(Data("\u{1B}[3J\u{1B}[2J\u{1B}[H".utf8))
        }
        bytes.append(Data(normalized.utf8))
        feed.write(bytes)
        hasLoadedTranscript = true
        return true
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.terminalChannelAlreadyOpen:
            "Another terminal is already open on this Host."
        case TransportError.timedOut:
            "The Host did not answer in time."
        default:
            "The live view failed: \(error)"
        }
    }
}
