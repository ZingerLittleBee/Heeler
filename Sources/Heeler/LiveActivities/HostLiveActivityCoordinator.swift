import Foundation
import Observation

/// Per-Host Live Activity state machine. The Console's Agent list is the
/// source of truth while the app is foregrounded; after a 3-second settle
/// the coordinator starts, updates, or ends one activity per Host. Push
/// tokens are written to the Host registration file so the plugin can keep
/// the activity alive after the app suspends.
@MainActor
@Observable
final class HostLiveActivityCoordinator {
    let preferences: LiveActivityPreferences

    @ObservationIgnored private let controller: any LiveActivityControlling
    @ObservationIgnored private let transports: any NotificationTransportProvider
    @ObservationIgnored private let keys: NotificationKeyStore
    @ObservationIgnored private let ceremony: NotificationRegistrationCeremony
    @ObservationIgnored private let deviceToken: @MainActor () -> APNSDeviceToken?
    @ObservationIgnored private let knownHostIDs: @MainActor () -> Set<Host.ID>
    @ObservationIgnored private let hostDisplayName: @MainActor (Host.ID) -> String
    @ObservationIgnored private let isAwaitingSnapshot: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let connectionStatus: @MainActor (Host.ID) -> EventsSessionStatus?
    @ObservationIgnored private let settleDuration: Duration
    @ObservationIgnored private let now: @MainActor () -> Date

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var latestAgents: [Host.ID: [ConsoleAgent]] = [:]
    @ObservationIgnored private var applied: [Host.ID: AgentActivityDesire] = [:]
    @ObservationIgnored private var settleTasks: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessions: [Host.ID: ActivitySession] = [:]
    @ObservationIgnored private var pipes: [Host.ID: TokenPipe] = [:]

    var areActivitiesEnabled: Bool { controller.areEnabled }

    /// Last reconcile verdict per Host, human-readable — the Settings
    /// diagnostic row that turns "no banner and no idea why" into a
    /// sentence (observable so the row updates live).
    private(set) var reconcileNotes: [Host.ID: String] = [:]

    init(
        controller: any LiveActivityControlling,
        preferences: LiveActivityPreferences,
        transports: any NotificationTransportProvider,
        keys: NotificationKeyStore = NotificationKeyStore(),
        ceremony: NotificationRegistrationCeremony? = nil,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken?,
        knownHostIDs: @escaping @MainActor () -> Set<Host.ID>,
        hostDisplayName: @escaping @MainActor (Host.ID) -> String,
        isAwaitingSnapshot: @escaping @MainActor (Host.ID) -> Bool,
        connectionStatus: @escaping @MainActor (Host.ID) -> EventsSessionStatus?,
        settleDuration: Duration = .seconds(3),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.controller = controller
        self.preferences = preferences
        self.transports = transports
        self.keys = keys
        self.ceremony = ceremony ?? NotificationRegistrationCeremony(keys: keys)
        self.deviceToken = deviceToken
        self.knownHostIDs = knownHostIDs
        self.hostDisplayName = hostDisplayName
        self.isAwaitingSnapshot = isAwaitingSnapshot
        self.connectionStatus = connectionStatus
        self.settleDuration = settleDuration
        self.now = now
    }

    func isEnabled(for hostID: Host.ID) -> Bool {
        preferences.isEnabled(for: hostID)
    }

    /// Settings toggle: persist the opt-in and apply immediately. Switching
    /// off ends the activity and clears the registration field.
    func setEnabled(_ enabled: Bool, for hostID: Host.ID) {
        preferences.setEnabled(enabled, for: hostID)
        settleTasks[hostID]?.cancel()
        settleTasks[hostID] = nil
        guard didStart else { return }
        if enabled {
            apply(hostID)
        } else {
            endNow(hostID)
        }
    }

    /// Adopts (or ends) activities that survived a previous launch, then
    /// starts reflecting the current Agent list. Unknown `hostID`s end
    /// immediately; a still-connecting or reconnecting known Host keeps
    /// its activity until the first post-connect snapshot arrives.
    func start() {
        guard !didStart else { return }
        didStart = true
        let known = knownHostIDs()
        for (id, hostID) in controller.currentActivities() {
            if !known.contains(hostID) {
                controller.end(id: id, finalContent: nil, immediate: true)
                continue
            }
            guard sessions[hostID] == nil else { continue }
            beginSession(
                LiveActivityHandle(id: id, hostID: hostID),
                awaitingFirstSnapshot: isAwaitingSnapshot(hostID))
        }
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(sessions.keys)
        for hostID in hosts {
            scheduleSettle(for: hostID)
        }
    }

    /// The Console feed. First sight is current truth, not a baseline — a
    /// launch with already-working Agents should start an activity once the
    /// settle elapses. Newer input cancels an in-flight settle.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        let grouped = Dictionary(grouping: agents, by: \.hostID)
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(grouped.keys)
        hosts.formUnion(sessions.keys)
        latestAgents = grouped
        guard didStart else { return }
        for hostID in hosts {
            scheduleSettle(for: hostID)
        }
    }

    /// Foreground return: notice dismissals that happened while we were away,
    /// adopt or orphan whatever ActivityKit still holds, and retry dirty
    /// token writes.
    func reconcile() {
        guard didStart else { return }
        let known = knownHostIDs()
        let current = controller.currentActivities()
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.hostID) })

        for (id, hostID) in current where !known.contains(hostID) {
            controller.end(id: id, finalContent: nil, immediate: true)
            if sessions[hostID]?.id == id {
                dropSession(hostID, endOnController: false)
                enqueue(.clear, for: hostID)
            }
        }

        for (hostID, session) in sessions where currentByID[session.id] == nil {
            dropSession(hostID, endOnController: false)
            enqueue(.clear, for: hostID)
        }

        for (id, hostID) in current where known.contains(hostID) && sessions[hostID] == nil {
            beginSession(
                LiveActivityHandle(id: id, hostID: hostID),
                awaitingFirstSnapshot: isAwaitingSnapshot(hostID))
        }

        retryDirtyPipes(onlyIfConnected: false)
        releaseSnapshotHolds()
    }

    /// Connection or snapshot-hold change: retry token writes for Hosts that
    /// are reachable again, hold live activities while the Agent list is
    /// unknown, and apply a deferred end/update once the first snapshot lands.
    func connectionsDidChange() {
        guard didStart else { return }
        retryDirtyPipes(onlyIfConnected: true)
        for hostID in sessions.keys {
            holdIfUnknown(hostID)
        }
        releaseSnapshotHolds()
    }

    // MARK: Desire / settle

    private func scheduleSettle(for hostID: Host.ID) {
        holdIfUnknown(hostID)
        if shouldDeferApply(for: hostID) {
            settleTasks[hostID]?.cancel()
            settleTasks[hostID] = nil
            return
        }
        let desired = computeDesired(for: hostID)
        if isUnchanged(hostID: hostID, desired: desired) {
            settleTasks[hostID]?.cancel()
            settleTasks[hostID] = nil
            return
        }
        settleTasks[hostID]?.cancel()
        let duration = settleDuration
        settleTasks[hostID] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.settleTasks[hostID] = nil
            self?.apply(hostID)
        }
    }

    private func apply(_ hostID: Host.ID) {
        guard didStart else { return }
        holdIfUnknown(hostID)
        if shouldDeferApply(for: hostID) { return }
        let desired = computeDesired(for: hostID)
        if isUnchanged(hostID: hostID, desired: desired) { return }

        guard let desired else {
            reconcileNotes[hostID] = "idle — \(desireBlocker(for: hostID))"
            endNow(hostID)
            return
        }
        guard let key = notificationKey(for: hostID),
            let content = AgentActivityContentBuilder.content(for: desired, key: key)
        else {
            reconcileNotes[hostID] = "sealing the update failed"
            return
        }

        if let session = sessions[hostID] {
            controller.update(id: session.id, content: content)
            applied[hostID] = desired
            reconcileNotes[hostID] = "active — updated"
            return
        }
        guard controller.areEnabled else {
            reconcileNotes[hostID] = "idle — iOS has Live Activities disabled for Heeler"
            return
        }
        do {
            let handle = try controller.request(
                attributes: AgentActivityAttributes(hostID: hostID.uuidString),
                content: content)
            beginSession(handle, awaitingFirstSnapshot: false)
            applied[hostID] = desired
            reconcileNotes[hostID] = "active — started"
        } catch {
            // Stay idle otherwise: a later change, reconnect, or foreground
            // reconcile is the retry. The note carries ActivityKit's reason.
            reconcileNotes[hostID] = "start failed — \(requestFailureReason(error))"
        }
    }

    /// The gate that kept `computeDesired` from producing content, in the
    /// order the gates run — surfaced by the Settings diagnostic row.
    private func desireBlocker(for hostID: Host.ID) -> String {
        if !controller.areEnabled { return "iOS has Live Activities disabled for Heeler" }
        if !preferences.isEnabled(for: hostID) { return "the per-Host toggle is off" }
        if deviceToken() == nil { return "no push device token yet" }
        if notificationKey(for: hostID) == nil { return "no Notification Key for this Host" }
        return "no working, blocked, or done agents"
    }

    private func requestFailureReason(_ error: any Error) -> String {
        if case LiveActivityRequestError.requestFailed(let reason) = error, !reason.isEmpty {
            return reason
        }
        return String(describing: error)
    }

    private func computeDesired(for hostID: Host.ID) -> AgentActivityDesire? {
        guard controller.areEnabled else { return nil }
        guard preferences.isEnabled(for: hostID) else { return nil }
        guard deviceToken() != nil else { return nil }
        guard notificationKey(for: hostID) != nil else { return nil }
        let agents = latestAgents[hostID] ?? []
        return AgentActivityContentBuilder.desire(
            from: agents, hostName: resolvedHostName(hostID, agents: agents))
    }

    private func isUnchanged(hostID: Host.ID, desired: AgentActivityDesire?) -> Bool {
        switch desired {
        case .some(let next):
            return applied[hostID] == next
        case .none:
            return applied[hostID] == nil && sessions[hostID] == nil
        }
    }

    /// True while this Host's Agent list is unknown: an empty slice is
    /// loading, not all-idle. Covers cold-launch adoption and a reconnect
    /// that cleared `agentsByPane` before the next snapshot.
    private func shouldDeferApply(for hostID: Host.ID) -> Bool {
        if isUnknownAgentInventory(hostID) { return true }
        if sessions[hostID]?.awaitingFirstSnapshot == true { return true }
        return false
    }

    private func isUnknownAgentInventory(_ hostID: Host.ID) -> Bool {
        if isAwaitingSnapshot(hostID) { return true }
        if sessions[hostID] != nil, let status = connectionStatus(hostID),
            status != .connected
        {
            return true
        }
        return false
    }

    /// Marks a live activity so `releaseSnapshotHolds` applies once the
    /// post-reconnect snapshot arrives — including an empty one.
    private func holdIfUnknown(_ hostID: Host.ID) {
        guard sessions[hostID] != nil, isUnknownAgentInventory(hostID) else { return }
        sessions[hostID]?.awaitingFirstSnapshot = true
    }

    private func releaseSnapshotHolds() {
        for (hostID, session) in sessions where session.awaitingFirstSnapshot {
            guard !isUnknownAgentInventory(hostID) else { continue }
            sessions[hostID]?.awaitingFirstSnapshot = false
            scheduleSettle(for: hostID)
        }
    }

    private func resolvedHostName(_ hostID: Host.ID, agents: [ConsoleAgent]) -> String {
        let catalog = hostDisplayName(hostID)
        if !catalog.isEmpty { return catalog }
        return agents.first?.hostName ?? ""
    }

    private func notificationKey(for hostID: Host.ID) -> Data? {
        guard let record = try? keys.record(forHost: hostID), record.key.count == 32 else {
            return nil
        }
        return record.key
    }

    // MARK: Sessions

    private struct ActivitySession {
        var id: String
        var awaitingFirstSnapshot: Bool
        var tokenTask: Task<Void, Never>
        var stateTask: Task<Void, Never>
    }

    private func beginSession(
        _ handle: LiveActivityHandle, awaitingFirstSnapshot: Bool
    ) {
        let tokenTask = Task { [weak self] in
            guard let self else { return }
            for await token in self.controller.pushTokenUpdates(for: handle) {
                self.considerToken(token, hostID: handle.hostID)
            }
        }
        let stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.controller.stateUpdates(for: handle) {
                self.considerState(state, hostID: handle.hostID)
            }
        }
        sessions[handle.hostID] = ActivitySession(
            id: handle.id,
            awaitingFirstSnapshot: awaitingFirstSnapshot,
            tokenTask: tokenTask,
            stateTask: stateTask)
    }

    private func considerToken(_ token: Data, hostID: Host.ID) {
        let hex = Self.hexEncoded(token)
        guard !hex.isEmpty else { return }
        enqueue(.set(hex: hex, startedAt: now()), for: hostID)
    }

    private func considerState(_ state: LiveActivityRunState, hostID: Host.ID) {
        switch state {
        case .dismissed, .ended:
            guard sessions[hostID] != nil else { return }
            dropSession(hostID, endOnController: false)
            enqueue(.clear, for: hostID)
        case .active, .stale:
            break
        }
    }

    private func endNow(_ hostID: Host.ID) {
        dropSession(hostID, endOnController: true)
        enqueue(.clear, for: hostID)
        applied[hostID] = nil
    }

    private func dropSession(_ hostID: Host.ID, endOnController: Bool) {
        guard let session = sessions.removeValue(forKey: hostID) else { return }
        session.tokenTask.cancel()
        session.stateTask.cancel()
        if endOnController {
            controller.end(id: session.id, finalContent: nil, immediate: true)
        }
    }

    // MARK: Token pipe

    private enum TokenJob: Equatable {
        case set(hex: String, startedAt: Date)
        case clear
    }

    private struct TokenPipe {
        var pending: TokenJob?
        var inFlight = false
        var isDirty = false
    }

    private func enqueue(_ job: TokenJob, for hostID: Host.ID) {
        var pipe = pipes[hostID] ?? TokenPipe()
        pipe.pending = job
        pipes[hostID] = pipe
        pump(hostID)
    }

    private func pump(_ hostID: Host.ID) {
        guard var pipe = pipes[hostID], !pipe.inFlight, let job = pipe.pending else { return }
        pipe.pending = nil
        pipe.inFlight = true
        pipes[hostID] = pipe
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.perform(job, hostID: hostID)
            var pipe = self.pipes[hostID] ?? TokenPipe()
            pipe.inFlight = false
            let newer = pipe.pending
            if succeeded {
                pipe.isDirty = false
            } else {
                pipe.isDirty = true
                if newer == nil { pipe.pending = job }
            }
            self.pipes[hostID] = pipe
            // A failed write stays queued as dirty and waits for reconnect
            // or a foreground reconcile; pumping it here would spin.
            if succeeded || newer != nil {
                self.pump(hostID)
            }
        }
    }

    private func perform(_ job: TokenJob, hostID: Host.ID) async -> Bool {
        guard let token = deviceToken() else { return false }
        do {
            try await transports.withNotificationTransport(for: hostID) { [ceremony] transport in
                switch job {
                case .set(let hex, let startedAt):
                    try await ceremony.setLiveActivityToken(
                        tokenHex: hex, startedAt: startedAt, deviceToken: token,
                        over: transport)
                case .clear:
                    try await ceremony.clearLiveActivityToken(
                        deviceToken: token, over: transport)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func retryDirtyPipes(onlyIfConnected: Bool) {
        for (hostID, pipe) in pipes where pipe.isDirty {
            if onlyIfConnected, connectionStatus(hostID) != .connected { continue }
            pump(hostID)
        }
    }

    private static func hexEncoded(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
