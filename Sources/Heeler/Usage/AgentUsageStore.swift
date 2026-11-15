import Foundation
import Observation
import os

/// What a herdr-core Host's Usage is waiting for (ADR 0033). Thrown by a read,
/// and held in `AgentUsageStore.State`.
enum AgentUsageHostHelperNeed: Error, Equatable, Sendable {
    case notInstalled
    /// A Helper from before it served Usage.
    case outdated
    /// The Helper holds no record of this session's core yet.
    case waitingForCore
    /// The Helper holds no record of this tmux server yet.
    case waitingForTmux
    /// The record and the service both name a Node.js that has gone.
    case nodeGone
    case notOnWindows

    var message: String {
        switch self {
        case .notInstalled: String(localized: "Usage needs the Host Helper. See this Host's details.")
        case .outdated: String(localized: "Usage needs a newer Host Helper. Update it from this Host's details.")
        case .waitingForCore:
            String(localized: "The Host Helper has not reached this session's core yet. Start the core if it is not running.")
        case .waitingForTmux:
            String(localized: "The Host Helper has not reached this tmux server yet. Start tmux if it is not running.")
        case .nodeGone:
            String(localized: "The Node.js the Host Helper was set up with has gone from this Host. Repair it from this Host's details.")
        case .notOnWindows: String(localized: "Usage comes with the Host Helper, which is not available on native Windows yet.")
        }
    }

    /// Why the Host is left out of the totals, which its short line names.
    var exclusion: AgentUsageExclusion {
        switch self {
        case .notInstalled: .needsHostHelper
        case .outdated: .updateHostHelper
        case .waitingForCore: .waitingForCore
        case .waitingForTmux: .waitingForTmux
        case .nodeGone: .repairHostHelper
        case .notOnWindows: .hostHelperNotOnWindows
        }
    }
}

/// One Host's on-demand Usage reading. A Herdr TUI Host's connection is borrowed
/// from Console, so opening Usage starts no independent SSH connection there. A
/// core Host's read dials one when Console has none (ADR 0033).
@MainActor
@Observable
final class AgentUsageStore {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case requirement(String)
        case unsupportedPlatform
        case hostHelper(AgentUsageHostHelperNeed)
        case runtimeMissing
        case updateRequired
        case available(AgentUsageReport)
        case failed(String)

        /// The read failed on the way to the Host, not at the Host's answer.
        nonisolated var couldNotReachHost: Bool {
            self == .failed(AgentUsageStore.connectionFailureMessage)
        }
    }

    /// One read's outcome and the plugin release that gave it, when the
    /// read learned it.
    struct Reading: Sendable {
        let state: State
        let pluginVersion: PluginVersion?
    }

    /// What a visible surface keys its refresh task on: the request it
    /// carries, and a generation the store advances to restart polling.
    struct RefreshKey: Hashable {
        let claudeLimits: Bool
        let generation: Int
    }

    /// The re-query cadence while the plugin's worker is refreshing.
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// A shown report's failed refreshes are retried with a backoff that
    /// doubles from `pollInterval` up to this interval.
    nonisolated static let maximumRetryInterval: Duration = .seconds(30)

    private var snapshotState: State = .idle
    /// Whether the shown report's query asked for Claude Code limits.
    private var snapshotIncludesClaudeLimits = false
    var state: State {
        guard case .available(let report) = snapshotState else { return snapshotState }
        if !claudeLimitsEnabled { return .available(report.hidingClaudeLimits()) }
        // The toggle turned on after this report: its "off" reading is no
        // longer this device's choice while the re-query is underway, and
        // a failed re-query must not leave it reading.
        if !snapshotIncludesClaudeLimits {
            return .available(refreshFailure == nil ? report.readingClaudeLimits() : report.failedClaudeLimits())
        }
        return snapshotState
    }
    /// A refresh is running: a read is in flight or polling continues.
    private(set) var isLoading = false
    /// Why the last refresh failed while the earlier report stays shown.
    private(set) var refreshFailure: String?
    /// When the state was last read from the Host.
    private(set) var readAt: Date?
    /// When the shown figures were read on the Host, which a refreshing
    /// report puts before `readAt`.
    var figuresReadAt: Date? {
        guard let readAt, case .available(let report) = snapshotState else { return readAt }
        return report.figuresDate(readAt: readAt)
    }
    /// The plugin release behind the shown state, when its read learned it.
    private(set) var pluginVersion: PluginVersion?
    /// Called after the state or the Claude Code limits choice changes, so
    /// the widgets' snapshot can follow.
    @ObservationIgnored var didChange: (@MainActor () -> Void)?
    /// Advanced when visible surfaces should start polling again.
    private(set) var refreshGeneration = 0
    var claudeLimitsEnabled: Bool {
        didSet {
            guard oldValue != claudeLimitsEnabled else { return }
            defaults.set(claudeLimitsEnabled, forKey: preferenceKey)
            endRefresh()
            didChange?()
        }
    }

    var refreshKey: RefreshKey {
        RefreshKey(claudeLimits: claudeLimitsEnabled, generation: refreshGeneration)
    }

    /// Whether a failed refresh is retried without another pull.
    var isRetryingRefresh: Bool { refreshFailure != nil && pollingInterval != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferenceKey: String
    @ObservationIgnored private let read: @MainActor (String, Bool) async throws -> Reading
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var consecutiveWaits = 0
    @ObservationIgnored private var pendingPause: Task<Void, any Error>?
    @ObservationIgnored private var readWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Reads started so far; each read is numbered by it.
    @ObservationIgnored private var readsStarted = 0
    /// For each Account file change still to be shown, the reads started
    /// when it was written: any later read shows it.
    @ObservationIgnored private var accountChangeWrites: [UUID: Int] = [:]

    convenience init(hostID: Host.ID, transports: any NotificationTransportProvider,
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(hostID: hostID, reader: Reader { timeZone, claudeLimits in
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await Self.reading(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        }, defaults: defaults, sleep: sleep)
    }

    /// A store whose reads learn no plugin version: whether the plugin has
    /// Accounts follows the shown report.
    convenience init(hostID: Host.ID, defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @escaping @MainActor (String, Bool) async throws -> State) {
        self.init(hostID: hostID, reader: Reader { timeZone, claudeLimits in
            Reading(state: try await read(timeZone, claudeLimits), pluginVersion: nil)
        }, defaults: defaults, sleep: sleep)
    }

    /// How a store reads its Host: the time zone and whether to ask for
    /// Claude Code limits in, a reading out. Not a bare closure, so a
    /// trailing closure always means the read-only `read:`.
    struct Reader {
        let read: @MainActor (String, Bool) async throws -> Reading
    }

    /// Console uses weak captures here so its retained stores cannot keep it alive.
    init(hostID: Host.ID, reader: Reader, defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        read = reader.read
        self.sleep = sleep
        self.defaults = defaults
        preferenceKey = Self.claudeLimitsPreferenceKey(for: hostID)
        claudeLimitsEnabled = defaults.bool(forKey: preferenceKey)
    }

    /// The device-local Claude Code limits consent for one Host.
    nonisolated static func claudeLimitsPreferenceKey(for hostID: Host.ID) -> String {
        "usage.claude-limits.\(hostID.uuidString)"
    }

    /// Reads, then keeps reading while the plugin's worker is refreshing or
    /// a failed refresh of a shown report is retried. A newer refresh
    /// supersedes this one; cancelling the caller stops it.
    func refresh(timeZone: String = TimeZone.current.identifier) async {
        let claudeLimits = claudeLimitsEnabled
        guard !Task.isCancelled else { return }
        let id = beginRefresh()
        defer { finishRefresh(id) }
        // A restarted loop keeps the polling cadence instead of reading
        // again right after the read that restarted it.
        if refreshFailure == nil, let interval = pollingInterval, let lastRead {
            let remaining = interval - lastRead.duration(to: .now)
            if remaining > .zero { await pause(for: remaining) }
        }
        while request == id && !Task.isCancelled {
            guard await readOnce(id: id, timeZone: timeZone, claudeLimits: claudeLimits),
                let interval = pollingInterval
            else { return }
            await pause(for: interval)
        }
    }

    /// Pull to refresh ends after one read; the inline Refreshing state
    /// covers the rest of the worker's run. A running refresh reads at once
    /// and keeps polling. Otherwise this pull reads, and a refreshing answer
    /// restarts the visible surfaces' polling.
    func pullToRefresh(timeZone: String = TimeZone.current.identifier) async {
        if request != nil {
            pendingPause?.cancel()
            await waitForNextRead()
            return
        }
        let claudeLimits = claudeLimitsEnabled
        guard !Task.isCancelled else { return }
        let id = beginRefresh()
        defer { finishRefresh(id) }
        guard await readOnce(id: id, timeZone: timeZone, claudeLimits: claudeLimits) else { return }
        if pollingInterval != nil { refreshGeneration += 1 }
    }

    /// The Host's connection is usable again: retry a failed refresh now
    /// instead of at the end of its backoff.
    func connectionBecameUsable() {
        let failed: Bool
        if case .failed = snapshotState { failed = true } else { failed = refreshFailure != nil }
        guard failed else { return }
        lastRead = nil
        if request != nil {
            pendingPause?.cancel()
        } else {
            refreshGeneration += 1
        }
    }

    func invalidate() {
        // No read will show a pending Account change now.
        accountChangeWrites = [:]
        endRefresh()
        snapshotState = .idle
        snapshotIncludesClaudeLimits = false
        refreshFailure = nil
        readAt = nil
        pluginVersion = nil
        consecutiveFailures = 0
        consecutiveWaits = 0
        didChange?()
    }

    nonisolated static func read(
        over transport: any Transport, timeZone: String, claudeLimits: Bool
    ) async throws -> State {
        try await reading(over: transport, timeZone: timeZone, claudeLimits: claudeLimits).state
    }

    nonisolated static func reading(
        over transport: any Transport, timeZone: String, claudeLimits: Bool
    ) async throws -> Reading {
        // The read's only plugin listing: the query runs the installation
        // it resolved.
        guard let plugin = try await transport.readHeelerPlugin() else {
            return Reading(
                state: .requirement(String(localized: "Usage needs the Heeler plugin 0.7.0 or newer on this Host.")), pluginVersion: nil)
        }
        guard let version = plugin.parsedVersion else {
            return Reading(
                state: .requirement(String(localized: "Could not verify the plugin version. Usage needs plugin 0.7.0 or newer.")),
                pluginVersion: nil)
        }
        let state: State
        if !HeelerPluginFeature.usage.isSupported(by: version) {
            state = .requirement(HeelerPluginFeature.usage.requirementNote(installed: version))
        } else if !plugin.isEnabled {
            state = .requirement(String(localized: "Enable the Heeler plugin on this Host to read Usage."))
        } else if let pluginRoot = plugin.pluginRoot {
            let report = try await transport.readAgentUsage(
                timeZone: timeZone, claudeLimits: claudeLimits, pluginRoot: pluginRoot)
            state = report.runtime == "missing" ? .runtimeMissing : .available(report)
        } else {
            state = .requirement(String(localized:
                "herdr did not report where the Heeler plugin is installed. Update herdr on this Host to read Usage."))
        }
        return Reading(state: state, pluginVersion: version)
    }

    /// A herdr-core Host's read: its Helper's report for the Host's session, from
    /// one bounded exec. A native Windows Host has no Helper and runs nothing.
    nonisolated static func reading(
        overHelper host: any HostHelperHost, session: String, timeZone: String, claudeLimits: Bool
    ) async throws -> Reading {
        try await reading(
            overHelper: host, files: HostHelperFiles(host: host, session: session),
            waiting: .waitingForCore, timeZone: timeZone, claudeLimits: claudeLimits)
    }

    /// A tmux Host's read: its Helper's report for the Host's tmux socket, from
    /// one bounded exec.
    nonisolated static func reading(
        overHelper host: any HostHelperHost, tmuxSocket: String, tmuxPaths: TmuxPaths? = nil,
        timeZone: String, claudeLimits: Bool
    ) async throws -> Reading {
        try await reading(
            overHelper: host, files: HostHelperFiles(host: host, tmuxSocket: tmuxSocket, tmuxPaths: tmuxPaths),
            waiting: .waitingForTmux, timeZone: timeZone, claudeLimits: claudeLimits)
    }

    private nonisolated static func reading(
        overHelper host: any HostHelperHost, files: HostHelperFiles, waiting: AgentUsageHostHelperNeed,
        timeZone: String, claudeLimits: Bool
    ) async throws -> Reading {
        guard try await host.hostPlatform() == .posix else {
            return Reading(state: .hostHelper(.notOnWindows), pluginVersion: nil)
        }
        let report: AgentUsageReport
        do {
            report = try await files.readUsage(timeZone: timeZone, claudeLimits: claudeLimits)
        } catch {
            // A Host reading over the Helper has no plugin to blame or update.
            guard Self.state(for: error) == .failed(pluginFailureMessage) else { throw error }
            return Reading(state: .failed(helperFailureMessage), pluginVersion: nil)
        }
        return Reading(
            state: report.runtime == "missing" ? .hostHelper(waiting) : .available(report),
            pluginVersion: nil)
    }

    /// Link failures ask the user to check the connection. A Host that
    /// answered, but not with a readable report, would answer the same way
    /// over any connection, so its copy does not blame the link.
    nonisolated static func state(for error: any Error) -> State {
        switch error {
        case let need as AgentUsageHostHelperNeed: .hostHelper(need)
        case AgentUsageError.unsupportedVersion: .updateRequired
        case TransportError.hostFeatureUnavailable: .unsupportedPlatform
        case TransportError.hostFileTimedOut: .failed(timeoutMessage)
        case AgentUsageError.invalidReport, is DecodingError,
            TransportError.malformedResponse, TransportError.apiRejected:
            .failed(pluginFailureMessage)
        default: .failed(connectionFailureMessage)
        }
    }

    nonisolated static let connectionFailureMessage =
        String(localized: "Could not read Usage. Check the Host connection and try again.")
    nonisolated static let pluginFailureMessage =
        String(localized: "The Heeler plugin on this Host could not report Usage. Try again, or update the plugin.")
    nonisolated static let helperFailureMessage =
        String(localized: "The Host Helper on this Host could not report Usage. Try again, or see this Host's details.")
    nonisolated static let timeoutMessage =
        String(localized: "The Host took too long to report Usage. Try again in a moment.")

    /// Polling continues while the shown report is refreshing; a failed
    /// refresh backs off. A Helper that has yet to reach a core is read again
    /// too, backing off, since no core may be running. nil stops polling.
    private var pollingInterval: Duration? {
        if snapshotState == .hostHelper(.waitingForCore) || snapshotState == .hostHelper(.waitingForTmux) {
            let doublings = min(max(consecutiveWaits - 1, 0), 4)
            return min(Self.pollInterval * (1 << doublings), Self.maximumRetryInterval)
        }
        guard case .available(let report) = snapshotState, report.refreshing == true else { return nil }
        guard refreshFailure != nil else { return Self.pollInterval }
        let doublings = min(max(consecutiveFailures - 1, 0), 4)
        return min(Self.pollInterval * (1 << doublings), Self.maximumRetryInterval)
    }

    private func beginRefresh() -> UUID {
        let id = UUID()
        request = id
        isLoading = true
        if snapshotState == .idle { snapshotState = .loading }
        return id
    }

    private func finishRefresh(_ id: UUID) {
        guard request == id else { return }
        request = nil
        isLoading = false
        resumeReadWaiters()
    }

    private func endRefresh() {
        request = nil
        isLoading = false
        lastRead = nil
        pendingPause?.cancel()
        resumeReadWaiters()
    }

    /// One read, applied unless a newer request or the caller's cancellation
    /// superseded it. false stops the caller's loop.
    private func readOnce(id: UUID, timeZone: String, claudeLimits: Bool) async -> Bool {
        readsStarted += 1
        let number = readsStarted
        let reading: Reading
        do {
            reading = try await read(timeZone, claudeLimits)
        } catch {
            reading = Reading(state: Self.state(for: error), pluginVersion: nil)
        }
        let next = reading.state
        guard request == id else { return false }
        guard !Task.isCancelled else {
            if snapshotState == .loading { snapshotState = .idle }
            return false
        }
        lastRead = .now
        if case .failed(let message) = next, case .available = snapshotState {
            // A transient failure must not discard the report on screen.
            refreshFailure = message
            consecutiveFailures += 1
        } else {
            snapshotState = next
            snapshotIncludesClaudeLimits = claudeLimits
            pluginVersion = reading.pluginVersion
            refreshFailure = nil
            readAt = .now
            consecutiveFailures = 0
            consecutiveWaits =
                (next == .hostHelper(.waitingForCore) || next == .hostHelper(.waitingForTmux))
                ? consecutiveWaits + 1 : 0
        }
        // This read shows the Account changes written before it started; a
        // failed one ends their wait all the same.
        for (change, readsBefore) in accountChangeWrites where readsBefore < number {
            accountChangeWrites[change] = nil
        }
        resumeReadWaiters()
        didChange?()
        return true
    }

    /// Sleeps for `delay` unless a pull, a reconnect, or cancellation ends
    /// the pause first.
    private func pause(for delay: Duration) async {
        let sleep = self.sleep
        let pause = Task { try await sleep(delay) }
        pendingPause = pause
        await withTaskCancellationHandler {
            _ = await pause.result
        } onCancel: {
            pause.cancel()
        }
        if pendingPause == pause { pendingPause = nil }
    }

    private func waitForNextRead() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    readWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.readWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func resumeReadWaiters() {
        let waiters = readWaiters.values
        readWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

// MARK: Claude Code Accounts

extension AgentUsageStore {
    /// Whether the Host's plugin reports Claude Code Accounts and reads the
    /// Account file: from the last read's plugin version, or, when the read
    /// did not say, from the shown report carrying Accounts.
    var supportsClaudeAccounts: Bool {
        if let pluginVersion { return HeelerPluginFeature.claudeAccounts.isSupported(by: pluginVersion) }
        guard case .available(let report) = snapshotState else { return false }
        return report.claudeProgram?.accounts != nil
    }

    /// The Accounts entry's note when the Host's plugin is too old for them;
    /// nil when it is new enough or its version is unknown.
    var claudeAccountsRequirement: String? {
        guard let pluginVersion, !HeelerPluginFeature.claudeAccounts.isSupported(by: pluginVersion)
        else { return nil }
        return HeelerPluginFeature.claudeAccounts.requirementNote(installed: pluginVersion)
    }

    /// The Account file changed on the Host: reads Usage again and returns
    /// once a read started after the change lands, so a row can keep its
    /// spinner until Usage shows it. A newer read may replace the one this
    /// starts; dropping it (turning Claude Code limits on or off) reads
    /// again. Turning Usage off ends the wait.
    func showAccountFileChange() async {
        let change = UUID()
        accountChangeWrites[change] = readsStarted
        await readAfterAccountChange()
        while accountChangeWrites[change] != nil, !Task.isCancelled {
            if request == nil {
                await readAfterAccountChange()
            } else {
                await waitForNextRead()
            }
        }
        accountChangeWrites[change] = nil
    }

    /// One read right after the Account file changed. A read already in
    /// flight may predate the change, so this one supersedes it, and a
    /// refreshing answer restarts the visible surfaces' polling.
    private func readAfterAccountChange(timeZone: String = TimeZone.current.identifier) async {
        let claudeLimits = claudeLimitsEnabled
        pendingPause?.cancel()
        let id = beginRefresh()
        defer { finishRefresh(id) }
        guard await readOnce(id: id, timeZone: timeZone, claudeLimits: claudeLimits) else { return }
        if pollingInterval != nil { refreshGeneration += 1 }
    }
}
