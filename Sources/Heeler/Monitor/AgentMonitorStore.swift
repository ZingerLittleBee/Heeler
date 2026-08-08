import Foundation
import Observation
import SwiftUI

protocol AgentMonitorClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousAgentMonitorClock: AgentMonitorClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Owns Monitor's adaptive live mirror and its local scrollback. Status
/// pushes trigger one refresh; only a Working Agent in a foreground view
/// also receives cadence refreshes. History is served from the in-memory
/// cache and backfilled through `agent.read` only while the Agent is idle.
@MainActor
@Observable
final class AgentMonitorStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Where the scrollback stands relative to herdr's capture limit. herdr
    /// has no history cursor, so "more history" is only ever one `recent`
    /// read away; the states exist to make that read honest.
    enum HistoryState: Equatable {
        /// No load in flight; reaching the top of the cache may fetch more.
        case idle
        /// An idle backfill read is in flight — the one loading state in
        /// Monitor.
        case loading
        /// The Agent is working, or herdr answered `agent_not_idle`:
        /// history is honestly unavailable, never a spinner.
        case unavailable
        /// The oldest capturable content is already cached.
        case exhausted
        /// The backfill read itself failed; retryable from the marker.
        case failed(String)
    }

    static let refreshCadence: Duration = .seconds(2)
    /// herdr caps every read at 1000 lines; ask for the whole window.
    static let historyLineCount = 1000
    /// The in-content marker for a region that could not be captured or
    /// reconciled. Tests assert on this copy.
    static let gapMarkerText = "— gap: content not captured —"

    private(set) var state: State = .idle
    private(set) var snapshot: AttributedString?
    private(set) var capturedAt: Date?
    private(set) var agentStatus: AgentStatus
    private(set) var liveUpdatesAvailable = true
    private(set) var historyState: HistoryState = .idle
    private(set) var contentChangeCount: UInt64 = 0
    private(set) var isBottomPinned = true
    private(set) var hasNewOutput = false

    private let target: String
    private let now: @Sendable () -> Date
    private let clock: any AgentMonitorClock
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private let read: @Sendable (AgentReadParams) async throws -> PaneReadResult
    @ObservationIgnored private var history = AgentMonitorHistory()
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var isMonitorVisible = true
    @ObservationIgnored private var needsRefreshAfterAttach = false
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var isBackfilling = false
    @ObservationIgnored private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var backfillWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any AgentMonitorClock = ContinuousAgentMonitorClock(),
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        read: @escaping @Sendable (AgentReadParams) async throws -> PaneReadResult
    ) {
        self.target = target
        agentStatus = initialStatus
        self.now = now
        self.clock = clock
        self.statusUpdates = statusUpdates
        self.read = read
    }

    deinit {
        pollingTask?.cancel()
        statusTask?.cancel()
    }

    /// Fetches exactly once for this Monitor instance, backfills history
    /// once when the Agent is not working, then starts the status-driven
    /// state machine. SwiftUI may re-run its task when Attach pops, so the
    /// return refresh has its own explicit path.
    func open() async {
        guard !hasOpened else { return }
        hasOpened = true
        consumeStatusUpdates()
        await fetch()
        reconcilePolling()
        // A cold cache backfills once on open so scrolling up is served
        // from local lines from the first paint. A Working Agent skips the
        // read entirely; the top of the cache says why instead.
        await loadEarlierHistory()
    }

    func setForeground(_ isForeground: Bool) {
        guard self.isForeground != isForeground else { return }
        self.isForeground = isForeground
        reconcilePolling()
    }

    /// The reusable status seam consumed by Monitor now and Composer in #182.
    /// Every real transition refreshes once, including terminal states; only
    /// Working continues into the cadence loop.
    func agentStatusDidChange(_ status: AgentStatus) async {
        guard agentStatus != status else { return }
        agentStatus = status
        if status == .working {
            // History cannot be captured while the Agent works. An
            // in-flight backfill resolves itself: herdr answers
            // `agent_not_idle`, which lands as unavailability below.
            if historyState != .loading, historyState != .exhausted {
                historyState = .unavailable
            }
        } else if historyState == .unavailable {
            historyState = .idle
        }
        stopPolling()
        guard hasOpened, isMonitorVisible, liveUpdatesAvailable else { return }
        await waitForCurrentFetch()
        await fetch()
        reconcilePolling()
    }

    func setBottomPinned(_ isPinned: Bool) {
        isBottomPinned = isPinned
        if isPinned {
            hasNewOutput = false
        }
    }

    func jumpToLatestOutput() {
        setBottomPinned(true)
    }

    /// Pull-to-refresh is always available, even when adaptive polling is off.
    func refresh() async {
        await waitForCurrentFetch()
        await fetch()
    }

    /// Records a user-initiated Attach push. Repeated destination lifecycle
    /// callbacks still collapse to one refresh when navigation returns.
    func attachDidOpen() {
        needsRefreshAfterAttach = true
        isMonitorVisible = false
        stopPolling()
    }

    /// Refreshes once after Attach closes, then consumes the pending marker.
    func refreshOnReturn() async {
        guard needsRefreshAfterAttach else { return }
        needsRefreshAfterAttach = false
        isMonitorVisible = true
        await refresh()
        reconcilePolling()
    }

    func retry() async {
        await refresh()
    }

    /// The view reports the scroll reaching the top of the cache. An idle
    /// Agent gets one backfill with a visible loading state; a working Agent
    /// gets the honest unavailability notice instead of a spinner.
    func topEdgeReached() {
        guard hasOpened, liveUpdatesAvailable else { return }
        guard agentStatus != .working else {
            if historyState != .exhausted {
                historyState = .unavailable
            }
            return
        }
        switch historyState {
        case .idle, .unavailable, .failed:
            // Set synchronously so a geometry re-fire before the task steps
            // cannot double-fire the read.
            historyState = .loading
            Task { await self.loadEarlierHistory() }
        case .loading, .exhausted:
            break
        }
    }

    /// One backfill read. herdr exposes no history cursor, so this reads
    /// the server's newest lines (capped at `historyLineCount`) and
    /// overlap-stitches them onto the cache; a stitch that finds no shared
    /// content records an explicit gap instead of guessing. Also the retry
    /// path for a failed backfill.
    func loadEarlierHistory() async {
        guard hasOpened else { return }
        // Visible reads and backfills share one flight: a top-edge hit
        // during a cadence poll must not interleave two reads, or the
        // backfill could stitch against a tail the poll just replaced and
        // record a spurious gap. The wait runs before the flag is set, so
        // a fetch holding its own flag never waits back on this one.
        await waitForCurrentFetch()
        guard !isBackfilling else { return }
        guard agentStatus != .working else {
            if historyState != .exhausted {
                historyState = .unavailable
            }
            return
        }
        guard historyState != .exhausted else { return }
        isBackfilling = true
        historyState = .loading
        defer { finishBackfill() }
        do {
            let result = try await read(
                AgentReadParams(
                    source: .recent,
                    target: target,
                    format: .ansi,
                    lines: Self.historyLineCount,
                    stripANSI: false))
            let outcome = history.stitchBackfill(result.text)
            if outcome.newLines > 0 || outcome.insertedGap {
                renderSnapshot()
                contentChangeCount &+= 1
            }
            capturedAt = now()
            // The capture limit is reached when the server had fewer lines
            // than the cap (that was everything) or when the read added
            // nothing (the window is already fully cached).
            let returnedLines = AgentMonitorHistory.splitLines(result.text).count
            historyState =
                returnedLines < Self.historyLineCount || outcome.newLines == 0
                ? .exhausted : .idle
        } catch let error as HerdrAPIError where error.code == "agent_not_idle" {
            // History is capturable only while the Agent is idle; a racing
            // status push makes this honest unavailability, never an error.
            historyState = .unavailable
        } catch is CancellationError {
            historyState = .idle
        } catch {
            historyState = .failed(Self.message(for: error))
        }
    }

    private func consumeStatusUpdates() {
        guard statusTask == nil, let statusUpdates else { return }
        statusTask = Task { [weak self] in
            for await update in statusUpdates {
                guard !Task.isCancelled, let self else { return }
                await self.liveUpdateDidChange(update)
            }
        }
    }

    private func liveUpdateDidChange(_ update: ConsoleStore.AgentStatusUpdate) async {
        let availabilityWasRestored = !liveUpdatesAvailable && update.liveUpdatesAvailable
        liveUpdatesAvailable = update.liveUpdatesAvailable
        if !liveUpdatesAvailable {
            stopPolling()
        }
        if let status = update.status, status != agentStatus {
            await agentStatusDidChange(status)
            return
        }
        guard availabilityWasRestored, hasOpened, isMonitorVisible else {
            reconcilePolling()
            return
        }
        await refresh()
        reconcilePolling()
    }

    private func reconcilePolling() {
        guard
            hasOpened,
            isForeground,
            isMonitorVisible,
            liveUpdatesAvailable,
            agentStatus == .working
        else {
            stopPolling()
            return
        }
        guard pollingTask == nil else { return }
        let clock = clock
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.refreshCadence)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.pollOnceIfNeeded()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnceIfNeeded() async {
        guard
            isForeground, isMonitorVisible, liveUpdatesAvailable,
            agentStatus == .working
        else { return }
        await waitForCurrentFetch()
        guard
            isForeground, isMonitorVisible, liveUpdatesAvailable,
            agentStatus == .working
        else { return }
        await fetch()
    }

    private func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        if snapshot == nil {
            state = .loading
        }
        defer { finishFetch() }
        // The other half of the shared flight: a poll that fires while a
        // backfill reads waits for it rather than interleaving on the wire.
        await waitForCurrentBackfill()

        do {
            let result = try await read(
                AgentReadParams(
                    source: .visible,
                    target: target,
                    format: .ansi,
                    stripANSI: false))
            applyVisibleText(result.text)
            capturedAt = now()
            state = .loaded
        } catch is CancellationError {
            state = snapshot == nil ? .idle : .loaded
            if snapshot == nil {
                hasOpened = false
            }
        } catch {
            // Visible-screen refreshes surface every error honestly. The
            // `agent_not_idle` carve-out lives in the backfill path
            // (`loadEarlierHistory`), where it means history is unavailable
            // while the Agent works — never an error.
            state = .failed(Self.message(for: error))
        }
    }

    private func applyVisibleText(_ text: String) {
        let hadContent = !history.isEmpty
        let outcome = history.applyVisible(text)
        guard outcome != .unchanged else { return }
        if outcome == .replaced, historyState == .exhausted {
            // Exhaustion describes the backfill window anchored to the old
            // live run. A repaint invalidates that anchor, so the new live
            // generation must be allowed to backfill from the top again.
            historyState = agentStatus == .working ? .unavailable : .idle
        }
        renderSnapshot()
        contentChangeCount &+= 1
        if hadContent, !isBottomPinned {
            hasNewOutput = true
        }
    }

    /// Renders the whole cache, with history above the live screen and gap
    /// markers between unreconciled regions. Storage keeps history and live
    /// runs separate, but adjacent line segments render together so ANSI
    /// state still flows across every byte-proven boundary. It resets only
    /// at a gap, which is the honest boundary anyway.
    private func renderSnapshot() {
        var renderedSegments: [AttributedString] = []
        var contiguousParts: [String] = []

        func flushContiguousLines() {
            guard !contiguousParts.isEmpty else { return }
            renderedSegments.append(
                ANSISnapshotRenderer.render(contiguousParts.joined(separator: "\n")))
            contiguousParts.removeAll(keepingCapacity: true)
        }

        for segment in history.segments {
            switch segment {
            case .lines(let lines):
                contiguousParts.append(lines.joined(separator: "\n"))
            case .gap:
                flushContiguousLines()
                var marker = AttributedString(Self.gapMarkerText)
                marker.foregroundColor = Color.secondary
                marker.inlinePresentationIntent = .emphasized
                renderedSegments.append(marker)
            }
        }
        flushContiguousLines()

        var rendered = AttributedString()
        for (index, segment) in renderedSegments.enumerated() {
            if index > 0 {
                rendered.append(AttributedString("\n"))
            }
            rendered.append(segment)
        }
        snapshot = rendered
    }

    private func waitForCurrentFetch() async {
        guard isFetching else { return }
        await withCheckedContinuation { continuation in
            fetchWaiters.append(continuation)
        }
    }

    private func finishFetch() {
        isFetching = false
        let waiters = fetchWaiters
        fetchWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForCurrentBackfill() async {
        guard isBackfilling else { return }
        await withCheckedContinuation { continuation in
            backfillWaiters.append(continuation)
        }
    }

    private func finishBackfill() {
        isBackfilling = false
        let waiters = backfillWaiters
        backfillWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let error as HerdrAPIError:
            "herdr rejected the snapshot: \(error.message)"
        case let error as TransportError:
            error.connectionGuidance
        default:
            "Loading the latest screen failed: \(error)"
        }
    }
}
