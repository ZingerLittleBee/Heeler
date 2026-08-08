import Foundation
import Observation

/// Owns the first Monitor cut: one ANSI snapshot on open and one refresh
/// after an Attach round trip. It deliberately has no event subscription or
/// polling; later Monitor packages add those behaviors from ADR 0012.
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

    private let target: String
    private let now: @Sendable () -> Date
    private let read: @Sendable (AgentReadParams) async throws -> PaneReadResult
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var needsRefreshAfterAttach = false
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        target: String,
        now: @escaping @Sendable () -> Date = { Date() },
        read: @escaping @Sendable (AgentReadParams) async throws -> PaneReadResult
    ) {
        self.target = target
        self.now = now
        self.read = read
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
    func refreshAfterAttach() async {
        guard needsRefreshAfterAttach else { return }
        needsRefreshAfterAttach = false
        await waitForCurrentFetch()
        await fetch()
    }

    func retry() async {
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
}
