import Foundation
import Observation

protocol AgentMonitorClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousAgentMonitorClock: AgentMonitorClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Owns Monitor's adaptive live mirror. Status pushes trigger one refresh;
/// only a Working Agent in a foreground view also receives cadence refreshes.
@MainActor
@Observable
final class AgentMonitorStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let refreshCadence: Duration = .seconds(2)

    private(set) var state: State = .idle
    private(set) var snapshot: AttributedString?
    private(set) var capturedAt: Date?
    private(set) var agentStatus: AgentStatus
    private(set) var liveUpdatesAvailable = true
    private(set) var contentChangeCount: UInt64 = 0
    private(set) var isBottomPinned = true
    private(set) var hasNewOutput = false

    private let target: String
    private let now: @Sendable () -> Date
    private let clock: any AgentMonitorClock
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private let read: @Sendable (AgentReadParams) async throws -> PaneReadResult
    @ObservationIgnored private var snapshotText: String?
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var isMonitorVisible = true
    @ObservationIgnored private var needsRefreshAfterAttach = false
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
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

    /// Fetches exactly once for this Monitor instance, then starts the
    /// status-driven state machine. SwiftUI may re-run its task when Attach
    /// pops, so the return refresh has its own explicit path.
    func open() async {
        guard !hasOpened else { return }
        hasOpened = true
        consumeStatusUpdates()
        await fetch()
        reconcilePolling()
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

        do {
            let result = try await read(
                AgentReadParams(
                    source: .visible,
                    target: target,
                    format: .ansi,
                    stripANSI: false))
            applySnapshotText(result.text)
            capturedAt = now()
            state = .loaded
        } catch is CancellationError {
            state = snapshot == nil ? .idle : .loaded
            if snapshot == nil {
                hasOpened = false
            }
        } catch {
            // #181 owns special `agent_not_idle` handling for history
            // backfill; visible-screen refreshes surface every error honestly.
            state = .failed(Self.message(for: error))
        }
    }

    private func applySnapshotText(_ text: String) {
        guard snapshotText != text else { return }
        let hadSnapshot = snapshotText != nil
        snapshotText = text
        snapshot = ANSISnapshotRenderer.render(text)
        contentChangeCount &+= 1
        if hadSnapshot, !isBottomPinned {
            hasNewOutput = true
        }
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
