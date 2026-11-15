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
    /// Re-reads while the plugin's worker is refreshing, within the about 30
    /// seconds iOS grants the task. A Helper left quiet for half an hour took
    /// 13 seconds to refresh; six re-reads wait up to 18.
    nonisolated static let refreshingRereads = 6

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
    /// so a task iOS expires keeps the readings that finished. Usage turned
    /// off during the run ends it, so no later reading replaces the widgets'
    /// "Usage is off" snapshot.
    func run(
        hosts: [Host], publisher: AgentUsageWidgetPublisher, isUsageEnabled: @MainActor () -> Bool
    ) async {
        let stale = hosts.filter { publisher.isStale($0.id, readAt: nil) }
        let read = self.read
        var readings: [AgentUsageWidgetReading] = []
        await withTaskGroup(of: (Host, AgentUsageStore.State?, Date).self) { group in
            for host in stale {
                let claudeLimits = defaults.bool(forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: host.id))
                group.addTask { (host, await read(host, claudeLimits), .now) }
            }
            for await (host, state, readAt) in group {
                guard isUsageEnabled() else {
                    group.cancelAll()
                    return
                }
                guard let state, !Task.isCancelled else { continue }
                readings.append(AgentUsageWidgetReading(
                    id: host.id, name: host.displayName, state: state, readAt: readAt,
                    isConnected: (host.serverKind != .herdrCore && host.serverKind != .tmux)
                        || !state.couldNotReachHost))
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
            // Nothing says what a Host of an unconfirmed Server Kind runs.
            guard host.serverKind.hasHostIntegrations else { return nil }
            var host = host
            host.routes.removeAll { $0.overlayNetworkID != nil }
            guard !host.routes.isEmpty, let resolved = try? credentials.credentials(for: host) else { return nil }
            let timeZone = TimeZone.current.identifier
            let settings = SSHTransportSettings(
                host: host, credentials: resolved,
                hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in false })
            do {
                if host.serverKind == .herdrCore {
                    let transport = try await connector.connectCore(settings: settings)
                    let helper = transport.hostHelperHost
                    let state = await readWithRereads(sleep: sleep) {
                        try await AgentUsageStore.reading(
                            overHelper: helper, session: host.sessionName,
                            timeZone: timeZone, claudeLimits: claudeLimits
                        ).state
                    }
                    try? await transport.close()
                    return state
                }
                if host.serverKind == .tmux {
                    let transport = try await connector.connectTmux(settings: settings)
                    let helper = transport.hostHelperHost
                    let state = await readWithRereads(sleep: sleep) {
                        try await AgentUsageStore.reading(
                            overHelper: helper, tmuxSocket: host.tmuxSocketName,
                            tmuxPaths: host.storedTmuxPaths, timeZone: timeZone, claudeLimits: claudeLimits
                        ).state
                    }
                    try? await transport.close()
                    return state
                }
                let transport = try await connector.connect(settings: settings)
                let state = await readWithRereads(sleep: sleep) {
                    try await AgentUsageStore.read(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
                }
                try? await transport.close()
                return state
            } catch {
                return AgentUsageStore.state(for: error)
            }
        }, defaults: defaults)
    }

    /// One read, and a few more while its answer says another is worth waiting
    /// for. A failed re-read keeps the state already read.
    private static func readWithRereads(
        sleep: @Sendable (Duration) async throws -> Void,
        read: () async throws -> AgentUsageStore.State
    ) async -> AgentUsageStore.State {
        func readOnce() async -> AgentUsageStore.State {
            do {
                return try await read()
            } catch {
                return AgentUsageStore.state(for: error)
            }
        }
        var state = await readOnce()
        for _ in 0..<refreshingRereads {
            guard wantsAnotherRead(state), (try? await sleep(AgentUsageStore.pollInterval)) != nil else { break }
            let next = await readOnce()
            if case .failed = next { break }
            state = next
        }
        return state
    }

    private static func wantsAnotherRead(_ state: AgentUsageStore.State) -> Bool {
        switch state {
        case .available(let report): report.refreshing == true
        case .hostHelper(.waitingForCore), .hostHelper(.waitingForTmux): true
        default: false
        }
    }
}
