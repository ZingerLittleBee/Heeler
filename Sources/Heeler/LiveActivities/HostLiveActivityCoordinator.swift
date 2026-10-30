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
    @ObservationIgnored private let supportsHost: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let hostDisplayName: @MainActor (Host.ID) -> String
    @ObservationIgnored private let isAwaitingSnapshot: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let connectionStatus: @MainActor (Host.ID) -> EventsSessionStatus?
    @ObservationIgnored private let pinnedPaneIDs: @MainActor (Host.ID) -> [String]
    @ObservationIgnored private let rowLayout: @MainActor (Host.ID) -> AgentRowLayout?
    @ObservationIgnored private let settleDuration: Duration
    @ObservationIgnored private let now: @MainActor () -> Date

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var latestAgents: [Host.ID: [ConsoleAgent]] = [:]
    @ObservationIgnored private var applied: [Host.ID: AgentActivityDesire] = [:]
    @ObservationIgnored private var settleTasks: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessions: [Host.ID: ActivitySession] = [:]
    @ObservationIgnored private var pipes: [Host.ID: TokenPipe] = [:]
    @ObservationIgnored private var writerTasks: [Host.ID: Task<Void, Never>] = [:]
    /// The Live Activity push token last written to each Host's entry, so a
    /// clear removes that token and nothing another Host wrote. Nil when no
    /// token is known, including after a failed token write that may still
    /// have landed; a clear then drops whatever token the own entry holds.
    @ObservationIgnored private var writtenLiveActivityTokens: [Host.ID: String] = [:]
    @ObservationIgnored var onDiagnostic: (@MainActor (Host.ID, String) -> Void)?

    var areActivitiesEnabled: Bool { controller.areEnabled }

    deinit {
        for task in settleTasks.values { task.cancel() }
        for session in sessions.values {
            session.tokenTask.cancel()
            session.stateTask.cancel()
        }
        for task in writerTasks.values { task.cancel() }
    }

    func stop() async {
        didStart = false
        let tasks = Array(settleTasks.values) + Array(writerTasks.values)
            + sessions.values.flatMap { [$0.tokenTask, $0.stateTask] }
        for task in tasks { task.cancel() }
        settleTasks.removeAll()
        sessions.removeAll()
        writerTasks.removeAll()
        pipes.removeAll()
        writtenLiveActivityTokens.removeAll()
        applied.removeAll()
        for task in tasks { await task.value }
    }

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
        supportsHost: @escaping @MainActor (Host.ID) -> Bool = { _ in true },
        pinnedPaneIDs: @escaping @MainActor (Host.ID) -> [String] = { _ in [] },
        rowLayout: @escaping @MainActor (Host.ID) -> AgentRowLayout? = { _ in nil },
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
        self.supportsHost = supportsHost
        self.hostDisplayName = hostDisplayName
        self.isAwaitingSnapshot = isAwaitingSnapshot
        self.connectionStatus = connectionStatus
        self.pinnedPaneIDs = pinnedPaneIDs
        self.rowLayout = rowLayout
        self.settleDuration = settleDuration
        self.now = now
    }

    /// Core cannot receive the plugin's Live Activity updates. Treat a Host
    /// switched to that backend as outside this coordinator's inventory,
    /// retaining its saved preference but ending activities and queued writes.
    private func supportedHostIDs() -> Set<Host.ID> {
        knownHostIDs().filter { supportsHost($0) }
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
        let known = supportedHostIDs()
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
        // A removed Host's Agents linger until the Console drops its
        // projection; they must not bring its activity back.
        let known = supportedHostIDs()
        let grouped = Dictionary(
            grouping: agents.filter { known.contains($0.hostID) }, by: \.hostID)
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(grouped.keys)
        hosts.formUnion(sessions.keys)
        latestAgents = grouped
        guard didStart else { return }
        for hostID in hosts {
            scheduleSettle(for: hostID)
        }
    }

    /// An explicitly removed Host (#414): ends its activity, forgets its
    /// opt-in, and drops everything queued for it. Nothing is written to the
    /// Host: its Console projection is gone, so a clear could only fail and
    /// stay dirty. Call after the catalog removal, so `knownHostIDs` already
    /// excludes the Host and nothing re-creates its state.
    func forgetHost(_ hostID: Host.ID) {
        // Only here, never by catalog difference: an unreadable catalog also
        // reads as no Hosts, and that must not cost every Host its opt-in.
        preferences.setEnabled(false, for: hostID)
        var activityIDs = Set(
            controller.currentActivities().filter { $0.hostID == hostID }.map(\.id))
        if let session = sessions[hostID] { activityIDs.insert(session.id) }
        dropSession(hostID, endOnController: false)
        for id in activityIDs.sorted() {
            controller.end(id: id, finalContent: nil, immediate: true)
        }
        dropTransientState(for: hostID)
    }

    /// Foreground return: notice dismissals that happened while we were away,
    /// adopt or orphan whatever ActivityKit still holds, and retry dirty
    /// token writes.
    func reconcile() {
        guard didStart else { return }
        let known = supportedHostIDs()
        let current = controller.currentActivities()
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.hostID) })

        // A Host outside the catalog has no Console projection to write
        // its clear through, so its activity ends without one.
        for (id, hostID) in current where !known.contains(hostID) {
            controller.end(id: id, finalContent: nil, immediate: true)
            if sessions[hostID]?.id == id {
                dropSession(hostID, endOnController: false)
            }
        }

        for (hostID, session) in sessions where currentByID[session.id] == nil {
            dropSession(hostID, endOnController: false)
            enqueue(.clear, for: hostID)
        }

        var tracked = Set(pipes.keys).union(settleTasks.keys).union(writerTasks.keys)
        tracked.formUnion(applied.keys)
        tracked.formUnion(latestAgents.keys)
        tracked.formUnion(writtenLiveActivityTokens.keys)
        tracked.formUnion(reconcileNotes.keys)
        for hostID in tracked.subtracting(known) {
            dropTransientState(for: hostID)
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

    /// Pin set change: rebuild LA content through the existing settle, and
    /// push `pinned_pane_ids` to Hosts that are connected and already
    /// showing an activity. Offline Hosts pick up the current set on the
    /// next live_activity write — no queue.
    func pinsDidChange() {
        guard didStart else { return }
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(sessions.keys)
        for hostID in hosts {
            scheduleSettle(for: hostID)
            if sessions[hostID] != nil, connectionStatus(hostID) == .connected {
                enqueue(.setPreferences, for: hostID)
            }
        }
    }

    /// Rebuild visible content and queue the same layout for background pushes.
    /// Offline writes stay dirty and retry on reconnect through the token pipe.
    func layoutsDidChange() {
        guard didStart else { return }
        for hostID in Set(latestAgents.keys).union(sessions.keys) {
            scheduleSettle(for: hostID)
            if sessions[hostID] != nil { enqueue(.setPreferences, for: hostID) }
        }
    }

    // MARK: Desire / settle

    private func scheduleSettle(for hostID: Host.ID) {
        guard supportedHostIDs().contains(hostID) else {
            settleTasks.removeValue(forKey: hostID)?.cancel()
            return
        }
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
        guard didStart, supportedHostIDs().contains(hostID) else { return }
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
            from: agents,
            hostName: resolvedHostName(hostID, agents: agents),
            pinnedPaneIDs: pinnedPaneIDs(hostID), layout: rowLayout(hostID))
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

    private struct ActivitySession: Sendable {
        var id: String
        var awaitingFirstSnapshot: Bool
        var tokenTask: Task<Void, Never>
        var stateTask: Task<Void, Never>
    }

    private func beginSession(
        _ handle: LiveActivityHandle, awaitingFirstSnapshot: Bool
    ) {
        let tokens = controller.pushTokenUpdates(for: handle)
        let states = controller.stateUpdates(for: handle)
        onDiagnostic?(handle.hostID, "subscribed")
        let tokenTask = Task { [weak self] in
            for await token in tokens {
                guard !Task.isCancelled else { break }
                self?.considerToken(token, hostID: handle.hostID)
            }
        }
        let stateTask = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled else { break }
                self?.considerState(state, hostID: handle.hostID)
            }
        }
        sessions[handle.hostID] = ActivitySession(
            id: handle.id,
            awaitingFirstSnapshot: awaitingFirstSnapshot,
            tokenTask: tokenTask,
            stateTask: stateTask)
    }

    private func considerToken(_ token: Data, hostID: Host.ID) {
        onDiagnostic?(hostID, "token consumed")
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

    /// Everything held in memory for a Host other than its activity
    /// session: settle and writer tasks, the token pipe and its written
    /// token, and the last desire, Agent list, and reconcile verdict. Safe
    /// to drop for any Host outside the catalog; the persisted opt-in is
    /// `forgetHost`'s alone.
    private func dropTransientState(for hostID: Host.ID) {
        settleTasks.removeValue(forKey: hostID)?.cancel()
        writerTasks.removeValue(forKey: hostID)?.cancel()
        pipes[hostID] = nil
        writtenLiveActivityTokens[hostID] = nil
        applied[hostID] = nil
        latestAgents[hostID] = nil
        if reconcileNotes[hostID] != nil { reconcileNotes[hostID] = nil }
    }

    // MARK: Token pipe

    private enum TokenJob: Equatable {
        case set(hex: String, startedAt: Date)
        case setPreferences
        case clear
    }

    private struct TokenPipe {
        var pending: TokenJob?
        var inFlight = false
        var isDirty = false
    }

    private func enqueue(_ job: TokenJob, for hostID: Host.ID) {
        // A Host outside the catalog has nothing to write through, so a job
        // for it would only stay dirty and retry forever (#414).
        guard didStart, supportedHostIDs().contains(hostID) else { return }
        var pipe = pipes[hostID] ?? TokenPipe()
        switch (pipe.pending, job) {
        case (.some(.set), .setPreferences), (.some(.clear), .setPreferences):
            // A pending token write already includes current pins at
            // perform time; a pending clear drops live_activity entirely.
            break
        default:
            pipe.pending = job
        }
        pipes[hostID] = pipe
        onDiagnostic?(hostID,
            "pipe queued pending=\(pipe.pending != nil) inFlight=\(pipe.inFlight) dirty=\(pipe.isDirty)")
        pump(hostID)
    }

    private func pump(_ hostID: Host.ID) {
        guard didStart, var pipe = pipes[hostID], !pipe.inFlight, let job = pipe.pending else { return }
        pipe.pending = nil
        pipe.inFlight = true
        pipes[hostID] = pipe
        writerTasks[hostID] = Task { [weak self] in
            guard let self else { return }
            self.onDiagnostic?(hostID, "writer started")
            let succeeded = await self.perform(job, hostID: hostID)
            guard !Task.isCancelled, self.didStart else { return }
            self.writerTasks[hostID] = nil
            // The Host left the catalog while this write was in flight: its
            // pipe stays gone instead of coming back dirty.
            guard self.supportedHostIDs().contains(hostID) else {
                self.dropTransientState(for: hostID)
                return
            }
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
            self.onDiagnostic?(hostID,
                "writer completed success=\(succeeded) pending=\(pipe.pending != nil) dirty=\(pipe.isDirty)")
            // A failed write stays queued as dirty and waits for reconnect
            // or a foreground reconcile; pumping it here would spin.
            if succeeded || newer != nil {
                self.pump(hostID)
            }
        }
    }

    private func perform(_ job: TokenJob, hostID: Host.ID) async -> Bool {
        guard let token = deviceToken() else { return false }
        let pins = pinnedPaneIDs(hostID)
        let layout = rowLayout(hostID)
        let hostName = resolvedHostName(hostID, agents: latestAgents[hostID] ?? [])
        let writtenToken = writtenLiveActivityTokens[hostID]
        let diagnose = onDiagnostic
        do {
            try await transports.withNotificationTransport(for: hostID) { [ceremony] transport in
                try Task.checkCancellation()
                await diagnose?(hostID, "transport acquired")
                switch job {
                case .set(let hex, let startedAt):
                    try await ceremony.setLiveActivityToken(
                        tokenHex: hex, startedAt: startedAt, hostID: hostID, deviceToken: token,
                        pinnedPaneIDs: pins, rowLayout: layout, hostName: hostName,
                        over: transport,
                        diagnose: { event in await diagnose?(hostID, event) })
                case .setPreferences:
                    try await ceremony.setLiveActivityPinnedPaneIDs(
                        pins, rowLayout: layout, hostName: hostName, hostID: hostID,
                        deviceToken: token, over: transport)
                case .clear:
                    try await ceremony.clearLiveActivityToken(
                        writtenToken, hostID: hostID, deviceToken: token, over: transport)
                }
            }
            // A write that lands after its Host left the catalog records
            // nothing, even when its writer was cancelled and so never
            // reaches the writer's own catalog check.
            guard supportedHostIDs().contains(hostID) else { return true }
            switch job {
            case .set(let hex, _): writtenLiveActivityTokens[hostID] = hex
            case .clear: writtenLiveActivityTokens[hostID] = nil
            case .setPreferences: break
            }
            return true
        } catch {
            if case .set = job { writtenLiveActivityTokens[hostID] = nil }
            onDiagnostic?(hostID, "writer error category=\(Self.errorCategory(error))")
            return false
        }
    }

    private static func errorCategory(_ error: any Error) -> String {
        if let registrationError = error as? NotificationRegistrationError {
            switch registrationError {
            case .pluginNotInstalled: return "pluginNotInstalled"
            case .pluginProbeFailed: return "pluginProbeFailed"
            case .readFailed: return "readFailed"
            case .writeFailed: return "writeFailed"
            case .unsupportedFileVersion: return "unsupportedFileVersion"
            case .deviceNotRegistered: return "deviceNotRegistered"
            }
        }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }

    private func retryDirtyPipes(onlyIfConnected: Bool) {
        let known = supportedHostIDs()
        for (hostID, pipe) in pipes where pipe.isDirty {
            guard known.contains(hostID) else {
                pipes[hostID] = nil
                continue
            }
            if onlyIfConnected, connectionStatus(hostID) != .connected { continue }
            pump(hostID)
        }
    }

    private static func hexEncoded(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
