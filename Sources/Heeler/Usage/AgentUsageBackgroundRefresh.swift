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

    /// Reads every stale Host at once, through each of its Servers, publishing
    /// each Host's reading as it lands, so a task iOS expires keeps the
    /// readings that finished. Usage turned off during the run ends it, so no
    /// later reading replaces the widgets' "Usage is off" snapshot.
    func run(
        hosts records: [Host], publisher: AgentUsageWidgetPublisher, isUsageEnabled: @MainActor () -> Bool
    ) async {
        let stale = AgentUsageHost.grouped(records).filter { publisher.isStale($0.id, readAt: nil) }
        let read = self.read
        var answered: [Host.ID: Int] = [:]
        var landed: [Host.ID: [Int: Answer]] = [:]
        var readings: [Host.ID: AgentUsageWidgetReading] = [:]
        await withTaskGroup(of: (Host.ID, Int, Answer?).self) { group in
            for host in stale {
                for (index, record) in host.records.enumerated() {
                    let claudeLimits = defaults.bool(
                        forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: record.id))
                    group.addTask {
                        let answer = await read(record, claudeLimits).map { state in
                            Answer(
                                state: state,
                                isConnected: (record.serverKind != .herdrCore && record.serverKind != .tmux)
                                    || !state.couldNotReachHost,
                                readAt: .now)
                        }
                        return (host.id, index, answer)
                    }
                }
            }
            for await (hostID, index, answer) in group {
                guard isUsageEnabled() else {
                    group.cancelAll()
                    return
                }
                guard !Task.isCancelled else { continue }
                answered[hostID, default: 0] += 1
                if let answer { landed[hostID, default: [:]][index] = answer }
                guard let host = stale.first(where: { $0.id == hostID }),
                    let reading = Self.reading(
                        of: host, from: landed[hostID] ?? [:],
                        everyServerAnswered: answered[hostID] == host.records.count)
                else { continue }
                readings[hostID] = reading
                publisher.publish(stale.compactMap { readings[$0.id] }, updating: records)
            }
        }
    }

    /// What one of a Host's Servers answered.
    private struct Answer: Sendable {
        let state: AgentUsageStore.State
        let isConnected: Bool
        let readAt: Date
    }

    /// A Host's reading, once what its Servers answered settles it: the Server
    /// `AgentUsageHost.chosen` picks among those that answered, by their place
    /// among the Host's records. nil while that Server has no reading and
    /// another is still out, so a Server that cannot report does not take the
    /// Host's figures away before the others have answered.
    private static func reading(
        of host: AgentUsageHost, from landed: [Int: Answer], everyServerAnswered: Bool
    ) -> AgentUsageWidgetReading? {
        let answers = landed.sorted { $0.key < $1.key }.map(\.value)
        guard !answers.isEmpty else { return nil }
        let chosen = answers[AgentUsageHost.chosen(among: answers.map { ($0.state, $0.isConnected) })]
        if case .available = chosen.state {} else if !everyServerAnswered { return nil }
        return AgentUsageWidgetReading(
            id: host.id, name: host.name, state: chosen.state, readAt: chosen.readAt,
            isConnected: chosen.isConnected)
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
