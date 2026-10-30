import BackgroundTasks
import Foundation

/// Keeps the Usage widgets current while Heeler is closed. An app refresh
/// task reads each stale Host over a connection of its own, publishes the
/// readings, and closes it again; the Console stays suspended. iOS decides
/// when the task runs, from how often the app and its widgets are used.
@MainActor
struct AgentUsageBackgroundRefresh {
    nonisolated static let identifier = "dev.bybee.heeler.usage-refresh"
    /// The earliest next run after one is scheduled.
    nonisolated static let interval: TimeInterval = 30 * 60
    /// Re-reads while the plugin's worker is refreshing, within the few
    /// seconds iOS grants the task.
    nonisolated static let refreshingRereads = 3

    /// One Host's reading, with or without Claude Code limits; nil when the
    /// Host cannot be read in the background.
    let read: @Sendable (Host, _ claudeLimits: Bool) async -> AgentUsageStore.State?
    /// Holds each Host's Claude Code limits consent.
    var defaults: UserDefaults = .standard

    /// Asks iOS for the next run. It fails where background refresh is
    /// unavailable, such as the Simulator or with Background App Refresh off,
    /// which leaves the widgets to the foreground reads.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    /// Reads every stale Host at once, publishing each reading as it lands,
    /// so a task iOS expires keeps the readings that finished.
    func run(hosts: [Host], publisher: AgentUsageWidgetPublisher) async {
        let stale = hosts.filter { publisher.isStale($0.id, readAt: nil) }
        let read = self.read
        var readings: [AgentUsageWidgetReading] = []
        await withTaskGroup(of: (Host, AgentUsageStore.State?, Date).self) { group in
            for host in stale {
                let claudeLimits = defaults.bool(forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: host.id))
                group.addTask { (host, await read(host, claudeLimits), .now) }
            }
            for await (host, state, readAt) in group {
                guard let state, !Task.isCancelled else { continue }
                readings.append(AgentUsageWidgetReading(
                    id: host.id, name: host.displayName, state: state, readAt: readAt, isConnected: true))
                publisher.publish(readings, updating: hosts)
            }
        }
    }
}

extension AgentUsageBackgroundRefresh {
    /// Real SSH, with the Console's credentials and trusted host keys. Routes
    /// through an Overlay Network are skipped: their nodes stay down while
    /// the app is in the background.
    static func live(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Self {
        Self(read: { host, claudeLimits in
            guard host.serverKind == .herdrTUI else { return .unsupportedBackend }
            var host = host
            host.routes.removeAll { $0.overlayNetworkID != nil }
            guard !host.routes.isEmpty, let resolved = try? credentials.credentials(for: host) else { return nil }
            let timeZone = TimeZone.current.identifier
            do {
                let transport = try await connector.connect(settings: SSHTransportSettings(
                    host: host, credentials: resolved,
                    hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in false }))
                func readOnce() async -> AgentUsageStore.State {
                    do {
                        return try await AgentUsageStore.read(
                            over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
                    } catch {
                        return AgentUsageStore.state(for: error)
                    }
                }
                var state = await readOnce()
                // A failed re-read keeps the report already read.
                for _ in 0..<refreshingRereads {
                    guard case .available(let report) = state, report.refreshing == true,
                        (try? await sleep(AgentUsageStore.pollInterval)) != nil
                    else { break }
                    let next = await readOnce()
                    if case .failed = next { break }
                    state = next
                }
                try? await transport.close()
                return state
            } catch {
                return AgentUsageStore.state(for: error)
            }
        }, defaults: defaults)
    }
}
