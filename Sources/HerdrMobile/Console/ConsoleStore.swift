import Foundation
import Observation

/// The Console aggregate: reconciles the Host catalog and publishes one
/// status-sorted Agent list across every Host. Each HostConsoleProjection
/// owns its own convergence, retry, snippets and Host-scoped RPC behavior.
@MainActor
@Observable
final class ConsoleStore {
    private(set) var agents: [ConsoleAgent] = []
    private(set) var hostStatuses: [Host.ID: EventsSessionStatus] = [:]
    private(set) var hostSyncErrors: [Host.ID: String] = [:]
    private(set) var hostConnectionGenerations: [Host.ID: UInt64] = [:]

    @ObservationIgnored private var projections: [
        Host.ID: HostConsoleProjection
    ] = [:]
    @ObservationIgnored private let makeSession:
        @Sendable (Host, [EventSubscription]) -> EventsSession
    @ObservationIgnored private let snapshotRetryDelay: Duration
    @ObservationIgnored private var isActive = false
    /// The most recently enqueued lifecycle transition. Suspend and resume
    /// are each several awaits long, so without a chain a resume racing a
    /// suspend can finish first and leave every Host suspended with nothing
    /// left to re-activate it.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init(
        snapshotRetryDelay: Duration = .seconds(2),
        makeSession: @escaping @Sendable (Host, [EventSubscription]) -> EventsSession =
            ConsoleStore.sshSessionFactory()
    ) {
        self.snapshotRetryDelay = snapshotRetryDelay
        self.makeSession = makeSession
    }

    /// Aligns Host projections with the catalog. Editing a Host replaces its
    /// projection because its connection coordinates may have changed.
    func setHosts(_ hosts: [Host]) {
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        for (id, projection) in projections where incoming[id] != projection.host {
            projection.end()
            projections[id] = nil
        }
        for host in hosts where projections[host.id] == nil {
            startProjection(for: host)
        }
        rebuild()
    }

    func resume() async {
        await enqueueLifecycleTransition { [self] in
            isActive = true
            for projection in projections.values {
                await projection.resume()
            }
        }
    }

    func suspend() async {
        await enqueueLifecycleTransition { [self] in
            isActive = false
            for projection in projections.values {
                await projection.suspend()
            }
        }
    }

    /// Chains `transition` behind the previously enqueued one and waits for
    /// it. Enqueueing is synchronous on the main actor, so the chain order is
    /// the call order.
    private func enqueueLifecycleTransition(
        _ transition: @escaping @MainActor () async -> Void
    ) async {
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await transition()
        }
        lifecycleTask = task
        await task.value
    }

    func retryFailedHosts() async {
        for projection in projections.values {
            await projection.retry()
        }
    }

    /// The returned runner resolves the Host's live projection on every
    /// call: editing a Host replaces its projection (and session), and a
    /// runner captured by a long-lived Attach screen must follow it there
    /// instead of staying bound to the ended session.
    func terminalRunner(for hostID: Host.ID) -> TerminalSessionRunner {
        { [weak self] request, handler in
            guard let runner = await self?.liveTerminalRunner(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            try await runner(request, handler)
        }
    }

    /// Late-bound for the same reason as `terminalRunner(for:)`: a retryable
    /// upload taken before a Host edit must stage over the new session.
    func imageStager(for hostID: Host.ID) -> ImageStager {
        { [weak self] image, reporter in
            guard let stager = await self?.liveImageStager(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await stager(image, reporter)
        }
    }

    private func liveTerminalRunner(for hostID: Host.ID) -> TerminalSessionRunner? {
        projections[hostID]?.terminalRunner()
    }

    private func liveImageStager(for hostID: Host.ID) -> ImageStager? {
        projections[hostID]?.imageStager()
    }

    func workspaces(for hostID: Host.ID) -> [ConsoleWorkspace] {
        projections[hostID]?.workspaces ?? []
    }

    @discardableResult
    func startAgent(
        _ request: AgentLaunchRequest,
        on hostID: Host.ID
    ) async throws -> Agent {
        guard let projection = projections[hostID] else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        return try await projection.startAgent(request)
    }

    func closePane(_ paneID: String, on hostID: Host.ID) async throws {
        guard let projection = projections[hostID] else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        try await projection.closePane(paneID)
    }

    private func startProjection(for host: Host) {
        let session = makeSession(
            host,
            HostConsoleProjection.subscriptions(paneIDs: []))
        let projection = HostConsoleProjection(
            host: host,
            session: session,
            snapshotRetryDelay: snapshotRetryDelay
        ) { [weak self] in
            self?.rebuild()
        }
        projections[host.id] = projection
        projection.start(isActive: isActive)
    }

    private func rebuild() {
        let current = Array(projections.values)
        agents = current
            .flatMap { $0.agentsByPane.values }
            .consoleSorted()
        hostStatuses = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.status.map { (projection.host.id, $0) }
            })
        hostSyncErrors = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.syncError.map { (projection.host.id, $0) }
            })
        hostConnectionGenerations = Dictionary(
            uniqueKeysWithValues: current.map {
                ($0.host.id, $0.transportGeneration)
            })
    }
}

extension ConsoleStore: NotificationTransportProvider {
    /// Notification Registration work borrows the Host's live Console
    /// connection (#75) instead of dialing a second one; an unconnected Host
    /// fails loudly like every other Host-scoped RPC here.
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let projection = projections[hostID] else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        return try await projection.session.withTransport(operation)
    }
}

extension ConsoleStore {
    /// The production session factory: SSH transports built from the Host
    /// catalog's credentials. TOFU is restricted to already-trusted
    /// fingerprints; the Console never prompts.
    static func sshSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider()
    ) -> @Sendable (Host, [EventSubscription]) -> EventsSession {
        { host, subscriptions in
            EventsSession(subscriptions: subscriptions) {
                let resolved: SSHCredentials
                do {
                    resolved = try credentials.credentials(for: host)
                } catch HostCredentialsError.passwordNotSet {
                    throw TransportError.authenticationFailed
                }
                let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
                return try await connector.connect(
                    settings: SSHTransportSettings(
                        host: host,
                        credentials: resolved,
                        hostKeyPolicy: policy))
            }
        }
    }
}
