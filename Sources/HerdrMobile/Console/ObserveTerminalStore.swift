import Foundation
import Observation

/// The Agent detail screen's Observe pipeline (#9): render the Pane's logical
/// transcript from `pane.read --format ansi --source recent-unwrapped`, then
/// use the terminal stream as a low-latency change signal. Each coalesced
/// refresh removes the remote TUI's input chrome, then replaces the local
/// SwiftTerm screen. The transport applies the phone geometry to the Agent's
/// PTY. Input belongs exclusively to the interactive Attach surface.
///
/// The store is driven by the terminal view's geometry: nothing starts until
/// the first size report (the observe command needs cols/rows), and a
/// changed size restarts the live-follow. Sequence gaps also restart the
/// stream so future change signals remain trustworthy. Observe is read-only
/// (CONTEXT.md): no input path exists here.
@MainActor
@Observable
final class ObserveTerminalStore {
    private static let initialTranscriptLines = 80
    private static let transcriptPageLines = 200
    private static let maximumTranscriptLines = 1_000

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
    private(set) var isLoadingEarlier = false
    private(set) var canLoadEarlier = true
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
    private var isAwaitingTransport = false
    private var activeTransport: (any Transport)?
    private var liveStream: TerminalFrameStream?
    private var runTask: Task<Void, Never>?
    private var transcriptRefreshTask: Task<Void, Never>?
    private var transcriptRefreshPending = false
    private var historyLoadTask: Task<Void, Never>?
    private var transcriptLineLimit = ObserveTerminalStore.initialTranscriptLines
    private var loadedTranscriptLineLimit = 0
    private var latestTranscript: String?

    init(
        target: String, transcriptRefreshInterval: Duration = .milliseconds(150),
        transport: @escaping @Sendable () async -> (any Transport)?
    ) {
        self.target = target
        self.transcriptRefreshInterval = transcriptRefreshInterval
        self.transport = transport
    }

    /// Starts a replacement pipeline with the geometry already reported by
    /// the same on-screen terminal. SwiftUI can replace its representable
    /// without another layout pass when the bounds have not changed.
    func reuseViewSize(from previous: ObserveTerminalStore) {
        guard let cols = previous.cols, let rows = previous.rows else { return }
        viewDidResize(cols: cols, rows: rows)
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
        historyLoadTask?.cancel()
        if let stream = liveStream {
            await stream.end()
        }
        // A run waiting for Console's teardown barrier owns no terminal
        // resource yet. Waiting for that run here can make the barrier wait
        // on itself during back-to-back replacements. `stopRequested` makes
        // the run exit before backfill or stream creation once its provider
        // is released.
        if !isAwaitingTransport, let task = runTask {
            await task.value
        }
        if let task = transcriptRefreshTask {
            await task.value
        }
        if let task = historyLoadTask {
            await task.value
        }
        status = .stopped
    }

    /// Expands the recent-unwrapped window when the terminal reaches the top.
    /// herdr 0.7.4 has no offset pagination and caps reads at 1,000 lines, so
    /// each accepted pull grows the window by one page until that boundary or
    /// the beginning of retained history is reached.
    @discardableResult
    func loadEarlier() -> Bool {
        guard case .live = status else { return false }
        guard let activeTransport else { return false }
        guard hasLoadedTranscript, canLoadEarlier, !isLoadingEarlier else { return false }
        guard transcriptLineLimit < Self.maximumTranscriptLines else {
            canLoadEarlier = false
            return false
        }

        let previousLimit = transcriptLineLimit
        let requestedLimit = min(
            Self.maximumTranscriptLines, previousLimit + Self.transcriptPageLines)
        transcriptLineLimit = requestedLimit
        isLoadingEarlier = true
        historyLoadTask = Task {
            await self.runHistoryLoad(
                transport: activeTransport, previousLimit: previousLimit,
                requestedLimit: requestedLimit)
        }
        return true
    }

    private func runHistoryLoad(
        transport: any Transport, previousLimit: Int, requestedLimit: Int
    ) async {
        defer {
            isLoadingEarlier = false
            historyLoadTask = nil
        }
        guard !stopRequested, !Task.isCancelled else { return }
        let succeeded = await refreshTranscript(
            transport: transport, replacing: true, requestedLines: requestedLimit)
        guard !stopRequested, !Task.isCancelled else { return }

        if !succeeded, loadedTranscriptLineLimit < requestedLimit,
            transcriptLineLimit == requestedLimit
        {
            transcriptLineLimit = previousLimit
        }
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
        defer {
            activeTransport = nil
            runTask = nil
        }
        while !stopRequested {
            activeTransport = nil
            isAwaitingTransport = true
            let currentTransport = await transport()
            isAwaitingTransport = false
            guard !stopRequested else { return }
            guard let transport = currentTransport else {
                status = .failed("The Host is not connected.")
                return
            }
            activeTransport = transport
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
                    // The server renders this frame after applying the mobile
                    // width to the Agent's PTY. Use it as a change signal,
                    // then fetch complete logical lines for local rendering.
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
    private func refreshTranscript(
        transport: any Transport, replacing: Bool, requestedLines: Int? = nil
    ) async -> Bool {
        let requestedLines = requestedLines ?? transcriptLineLimit
        guard
            let read = try? await transport.readPane(
                PaneReadParams(
                    paneID: target, source: .recentUnwrapped, format: .ansi,
                    lines: requestedLines))
        else { return false }
        guard !stopRequested else { return false }
        // An older in-flight read must not replace a larger history window
        // accepted by a later pull-to-load request.
        guard requestedLines >= transcriptLineLimit else { return false }
        let expandsHistory = replacing && loadedTranscriptLineLimit > 0
            && requestedLines > loadedTranscriptLineLimit
        loadedTranscriptLineLimit = max(loadedTranscriptLineLimit, requestedLines)
        let transcript = Self.outputOnlyTranscript(read.text)
        if expandsHistory {
            canLoadEarlier = requestedLines < Self.maximumTranscriptLines
                && latestTranscript.map {
                    Self.addsEarlierHistory(transcript, than: $0)
                } ?? true
        } else if requestedLines >= Self.maximumTranscriptLines {
            canLoadEarlier = false
        }
        latestTranscript = transcript
        // pane.read joins lines with bare newlines; a raw-mode terminal
        // needs CR+LF or the lines stair-step.
        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        var bytes = Data()
        if replacing {
            // Clear scrollback and the visible screen before painting the
            // latest snapshot, otherwise every refresh duplicates history.
            bytes.append(Data("\u{1B}[3J\u{1B}[2J\u{1B}[H".utf8))
        }
        bytes.append(Data(normalized.utf8))
        if expandsHistory {
            feed.writeHistorySnapshot(bytes)
        } else {
            feed.write(bytes)
        }
        hasLoadedTranscript = true
        return true
    }

    private static func addsEarlierHistory(_ transcript: String, than previous: String) -> Bool {
        guard !previous.isEmpty, transcript != previous else { return false }
        let previousLines = previous.components(separatedBy: "\n").map(terminalPlainText)
        let transcriptLines = transcript.components(separatedBy: "\n").map(terminalPlainText)
        let signature = Array(previousLines.prefix(8))
        guard !signature.isEmpty, transcriptLines.count >= signature.count else { return false }

        for start in 0...(transcriptLines.count - signature.count) {
            if transcriptLines[start..<(start + signature.count)].elementsEqual(signature) {
                return start > 0
            }
        }
        return false
    }

    /// herdr exposes terminal rows, not an agent-output-only stream. Remove
    /// the final interactive prompt and its footer while retaining earlier
    /// prompts from the conversation history. ANSI is preserved for the
    /// retained output; a plain-text projection is used only to find chrome.
    private static func outputOnlyTranscript(_ transcript: String) -> String {
        var lines = transcript.components(separatedBy: "\n")
        guard
            let inputStart = lines.lastIndex(where: { line in
                let plain = terminalPlainText(line).trimmingCharacters(in: .whitespaces)
                return plain == "›" || plain.hasPrefix("› ")
                    || plain == "❯" || plain.hasPrefix("❯ ")
            })
        else { return transcript }

        lines.removeSubrange(inputStart...)
        trimTrailingBlankLines(&lines)
        if let last = lines.last {
            let status = terminalPlainText(last).trimmingCharacters(in: .whitespaces)
            if status.hasPrefix("• Working (") || status.hasPrefix("• Worked for ") {
                lines.removeLast()
                trimTrailingBlankLines(&lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func trimTrailingBlankLines(_ lines: inout [String]) {
        while let last = lines.last,
            terminalPlainText(last).trimmingCharacters(in: .whitespaces).isEmpty
        {
            lines.removeLast()
        }
    }

    /// Removes CSI/OSC control sequences for matching only. The original ANSI
    /// line remains untouched when it is kept in the transcript.
    private static func terminalPlainText(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x1B else {
                if scalars[index].value != 0x0D {
                    result.append(scalars[index])
                }
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { break }
            switch scalars[index].value {
            case 0x5B:  // CSI: ESC [ ... final-byte
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if (0x40...0x7E).contains(value) { break }
                }
            case 0x5D:  // OSC: ESC ] ... BEL or ST
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B, index + 1 < scalars.count,
                        scalars[index + 1].value == 0x5C
                    {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return String(result)
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
