import Foundation
import Observation

/// Owns the first Monitor cut: one ANSI snapshot on open, one refresh after
/// an Attach round trip, and control-key delivery with a one-shot refresh
/// after each successful send (#183). It deliberately has no event
/// subscription or polling; later Monitor packages add those behaviors from
/// ADR 0012.
@MainActor
@Observable
final class AgentMonitorStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var snapshot: AttributedString?
    private(set) var capturedAt: Date?
    /// User-facing message from the last failed control-key send; cleared on
    /// the next successful send. Independent of snapshot `state` so a key
    /// failure never pretends the screen is missing.
    private(set) var sendError: String?
    private(set) var isSendingKey = false

    private let target: String
    private let now: @Sendable () -> Date
    private let read: @Sendable (AgentReadParams) async throws -> PaneReadResult
    private let sendKeys: @Sendable (AgentSendKeysParams) async throws -> Void
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var needsRefreshAfterAttach = false
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        target: String,
        now: @escaping @Sendable () -> Date = { Date() },
        read: @escaping @Sendable (AgentReadParams) async throws -> PaneReadResult,
        sendKeys: @escaping @Sendable (AgentSendKeysParams) async throws -> Void = { _ in }
    ) {
        self.target = target
        self.now = now
        self.read = read
        self.sendKeys = sendKeys
    }

    /// Fetches exactly once for this Monitor instance. SwiftUI may re-run its
    /// task when Attach pops, so the return refresh has its own explicit path.
    func open() async {
        guard !hasOpened else { return }
        hasOpened = true
        await fetch()
    }

    /// Records a user-initiated Attach push. Repeated destination lifecycle
    /// callbacks still collapse to one refresh when navigation returns.
    func attachDidOpen() {
        needsRefreshAfterAttach = true
    }

    /// Refreshes once after Attach closes, then consumes the pending marker.
    func refreshOnReturn() async {
        guard needsRefreshAfterAttach else { return }
        needsRefreshAfterAttach = false
        await waitForCurrentFetch()
        await fetch()
    }

    func retry() async {
        await waitForCurrentFetch()
        await fetch()
    }

    /// Delivers one control-key sequence via `agent.send_keys`, then refreshes
    /// the snapshot so the strip's effect is visible without Attach (#183).
    /// Concurrent taps are ignored while a send is in flight.
    func send(_ key: MonitorControlKey) async {
        guard !isSendingKey else { return }
        isSendingKey = true
        defer { isSendingKey = false }

        do {
            try await sendKeys(
                AgentSendKeysParams(keys: key.keys, target: target))
            sendError = nil
        } catch {
            sendError = Self.sendMessage(for: error)
            return
        }

        await waitForCurrentFetch()
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
            snapshot = ANSISnapshotRenderer.render(result.text)
            capturedAt = now()
            state = .loaded
        } catch is CancellationError {
            state = snapshot == nil ? .idle : .loaded
            if snapshot == nil {
                hasOpened = false
            }
        } catch {
            // #181 owns special `agent_not_idle` handling for history
            // backfill; this visible-screen cut surfaces every error honestly.
            state = .failed(Self.message(for: error))
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

    private static func sendMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let error as HerdrAPIError:
            "herdr rejected the key: \(error.message)"
        case let error as TransportError:
            error.connectionGuidance
        default:
            "Sending the key failed: \(error)"
        }
    }
}
