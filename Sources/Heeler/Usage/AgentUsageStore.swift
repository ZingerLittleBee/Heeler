import Foundation
import Observation
import os

/// One Host's on-demand Usage reading. Connections are borrowed from Console;
/// opening Usage never starts an independent SSH connection.
@MainActor
@Observable
final class AgentUsageStore {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case requirement(String)
        case unsupportedPlatform
        case runtimeMissing
        case updateRequired
        case available(AgentUsageReport)
        case failed(String)
    }

    /// One read's outcome and the plugin release that gave it, when the
    /// read learned it.
    struct Reading: Sendable {
        let state: State
        let pluginVersion: PluginVersion?
    }

    /// Runs one operation over the Host's connection.
    typealias HostOperation = @MainActor (
        _ operation: @escaping @Sendable (any Transport) async throws -> Void
    ) async throws -> Void

    /// What one Account file change is about, so its row can show a spinner.
    enum AccountChange: Hashable, Sendable {
        /// Renaming or removing an Account, by its report id (`default` for
        /// the Default Account).
        case account(String)
        /// Adding or ignoring a directory.
        case directory(String)
    }

    /// An Account change that could not be saved, for an alert.
    struct AccountChangeFailure: Identifiable, Equatable, Sendable {
        let id = UUID()
        let message: String
    }

    /// How adding a directory chosen in the remote browser ended.
    enum ChosenDirectoryOutcome: Equatable, Sendable {
        case added
        /// Shown in place, beside the browser.
        case refused(ClaudeAccountError)
        /// Reported in `accountChangeFailure`.
        case failed
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
    /// The plugin release behind the shown state, when its read learned it.
    private(set) var pluginVersion: PluginVersion?
    /// Account file changes in flight; each stays until a read started
    /// after its write lands.
    private(set) var pendingAccountChanges: Set<AccountChange> = []
    /// The last Account change that could not be saved; its alert, or the
    /// Accounts sheet closing, clears it.
    var accountChangeFailure: AccountChangeFailure?
    /// The Host's home folder, once the Accounts sheet asked for it: their
    /// directories show it as `~`.
    private(set) var hostHome: String?
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
    @ObservationIgnored private let onHost: HostOperation?
    /// Serializes the Account file's read, edit and replace. Hosts that
    /// share a plugin config directory share the file, so the Console
    /// passes one gate for every Host, as for the registration file.
    @ObservationIgnored private let accountFileGate: GitExecGate
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var pendingPause: Task<Void, any Error>?
    @ObservationIgnored private var readWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Reads started so far; each read is numbered by it.
    @ObservationIgnored private var readsStarted = 0
    /// For each pending Account change whose write landed, the reads
    /// started by then: any later read shows the change.
    @ObservationIgnored private var accountChangeWrites: [AccountChange: Int] = [:]

    convenience init(hostID: Host.ID, transports: any NotificationTransportProvider,
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(
            hostID: hostID,
            onHost: { operation in try await transports.withNotificationTransport(for: hostID, operation) },
            defaults: defaults, sleep: sleep
        ) { timeZone, claudeLimits in
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await Self.reading(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        }
    }

    /// A store that only reads: Account changes fail, and whether the
    /// plugin has Accounts follows the shown report.
    convenience init(hostID: Host.ID, defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @escaping @MainActor (String, Bool) async throws -> State) {
        self.init(hostID: hostID, onHost: nil, defaults: defaults, sleep: sleep) { timeZone, claudeLimits in
            Reading(state: try await read(timeZone, claudeLimits), pluginVersion: nil)
        }
    }

    /// Console uses weak captures here so its retained stores cannot keep it alive.
    init(hostID: Host.ID, onHost: HostOperation?, defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        accountFileGate: GitExecGate = GitExecGate(),
        reading: @escaping @MainActor (String, Bool) async throws -> Reading) {
        read = reading
        self.onHost = onHost
        self.accountFileGate = accountFileGate
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
        pendingAccountChanges = []
        endRefresh()
        snapshotState = .idle
        snapshotIncludesClaudeLimits = false
        refreshFailure = nil
        readAt = nil
        pluginVersion = nil
        hostHome = nil
        consecutiveFailures = 0
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
                state: .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host."), pluginVersion: nil)
        }
        guard let version = plugin.parsedVersion else {
            return Reading(
                state: .requirement("Could not verify the plugin version. Usage needs plugin 0.7.0 or newer."),
                pluginVersion: nil)
        }
        let state: State
        if !HeelerPluginFeature.usage.isSupported(by: version) {
            state = .requirement(HeelerPluginFeature.usage.requirementNote(installed: version))
        } else if !plugin.isEnabled {
            state = .requirement("Enable the Heeler plugin on this Host to read Usage.")
        } else if let pluginRoot = plugin.pluginRoot {
            let report = try await transport.readAgentUsage(
                timeZone: timeZone, claudeLimits: claudeLimits, pluginRoot: pluginRoot)
            state = report.runtime == "missing" ? .runtimeMissing : .available(report)
        } else {
            state = .requirement(
                "herdr did not report where the Heeler plugin is installed. Update herdr on this Host to read Usage.")
        }
        return Reading(state: state, pluginVersion: version)
    }

    /// Link failures ask the user to check the connection. A Host that
    /// answered, but not with a readable report, would answer the same way
    /// over any connection, so its copy does not blame the link.
    nonisolated static func state(for error: any Error) -> State {
        switch error {
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
        "Could not read Usage. Check the Host connection and try again."
    nonisolated static let pluginFailureMessage =
        "The Heeler plugin on this Host could not report Usage. Try again, or update the plugin."
    nonisolated static let timeoutMessage =
        "The Host took too long to report Usage. Try again in a moment."

    /// Polling continues while the shown report is refreshing; a failed
    /// refresh backs off. nil stops polling.
    private var pollingInterval: Duration? {
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
        }
        // This read shows the Account changes written before it started; a
        // failed one ends their wait all the same.
        for (change, readsBefore) in accountChangeWrites where readsBefore < number {
            accountChangeWrites[change] = nil
            pendingAccountChanges.remove(change)
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

    /// Whether `name` already names another of the shown Accounts, as the
    /// rename alert checks before Save. An empty name for the Default
    /// Account stands for "Default".
    func isAccountNameTaken(_ name: String, renaming account: AgentUsageReport.Account) -> Bool {
        guard case .available(let report) = snapshotState, let accounts = report.claudeProgram?.accounts
        else { return false }
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isDefault, name.isEmpty { name = AgentUsageReport.Account.defaultDisplayName }
        return accounts.contains { $0.id != account.id && $0.displayName == name }
    }

    /// Whether a change to this row is being saved or read back.
    func isChangingAccount(_ change: AccountChange) -> Bool {
        pendingAccountChanges.contains(change)
    }

    /// Adds a suggested directory under its suggested name.
    @discardableResult
    func addAccount(_ suggestion: AgentUsageReport.AccountSuggestion) async -> Bool {
        await reportingFailure { try await self.add(suggestion) }
    }

    /// Adds a directory picked in the remote browser. It must hold Claude
    /// Code's `.claude.json` or `projects/`; one a suggestion offers is
    /// added as that suggestion.
    func addAccount(directory: String) async -> ChosenDirectoryOutcome {
        do {
            if case .available(let report) = snapshotState,
                let suggestion = report.claudeProgram?.accountSuggestions?.first(where: { $0.directory == directory })
            {
                try await add(suggestion)
            } else {
                try await changeAccounts(.directory(directory), checkingDirectory: directory) { file, defaultDirectory in
                    try file.add(directory: directory, defaultDirectory: defaultDirectory)
                }
            }
            return .added
        } catch let refusal as ClaudeAccountError {
            return .refused(refusal)
        } catch {
            accountChangeFailure = AccountChangeFailure(message: Self.accountChangeMessage(for: error))
            return .failed
        }
    }

    /// Renames an Account; an empty name gives the Default Account back
    /// its "Default".
    @discardableResult
    func renameAccount(_ account: AgentUsageReport.Account, to name: String) async -> Bool {
        await reportingFailure {
            try await self.changeAccounts(.account(account.id)) { file, _ in
                try file.rename(
                    accountID: account.isDefault ? UsageAccountFile.defaultAccountID : account.id, to: name)
            }
        }
    }

    /// Removes an added Account. The Default Account stays.
    @discardableResult
    func removeAccount(_ account: AgentUsageReport.Account) async -> Bool {
        guard !account.isDefault else { return false }
        return await reportingFailure {
            try await self.changeAccounts(.account(account.id)) { file, _ in
                file.remove(accountID: account.id)
            }
        }
    }

    /// Dismisses a suggestion; the plugin stops offering its directory.
    @discardableResult
    func ignoreSuggestion(_ suggestion: AgentUsageReport.AccountSuggestion) async -> Bool {
        await reportingFailure {
            try await self.changeAccounts(.directory(suggestion.directory)) { file, defaultDirectory in
                try file.ignore(directory: suggestion.directory, defaultDirectory: defaultDirectory)
            }
        }
    }

    /// Learns the Host's home folder once; a failure leaves full paths.
    func loadHostHome() async {
        guard hostHome == nil, onHost != nil else { return }
        hostHome = try? await onHostValue { try await $0.hostHomeDirectory() }
    }

    /// A remote directory browser over this Host's connection, for Choose
    /// Another Directory…: it starts in the home folder and lists symbolic
    /// links to directories too, since Claude Code reads a directory by the
    /// path it is given. nil for a store that only reads.
    func accountDirectoryBrowser() -> RemoteDirectoryBrowser? {
        guard onHost != nil else { return nil }
        return RemoteDirectoryBrowser(
            resolveHome: { [weak self] in
                guard let self else { throw CancellationError() }
                let home = try await self.onHostValue { try await $0.hostHomeDirectory() }
                self.hostHome = home
                return home
            },
            list: { [weak self] path in
                guard let self else { throw CancellationError() }
                return try await self.onHostValue { transport in
                    try await RemoteDirectoryListing.followingLinks(at: path, over: transport)
                }
            })
    }

    nonisolated static func accountChangeMessage(for error: any Error) -> String {
        switch error {
        case let error as ClaudeAccountError: error.message
        case NotificationRegistrationError.pluginNotInstalled:
            "Enable the Heeler plugin on this Host to change its Accounts."
        case NotificationRegistrationError.readFailed, NotificationRegistrationError.pluginProbeFailed:
            "Heeler could not read this Host’s Accounts. Try again."
        case NotificationRegistrationError.writeFailed:
            "Heeler could not save this Host’s Accounts. Try again."
        case TransportError.hostFeatureUnavailable:
            "Claude Code Accounts are not available on this Host."
        default:
            "Could not change the Accounts. Check the Host connection and try again."
        }
    }

    /// Whether `directory` holds Claude Code's own `.claude.json` or a
    /// `projects/` directory, as the plugin's home listing checks.
    nonisolated static func holdsClaudeCode(_ directory: String, over transport: any Transport) async throws -> Bool {
        let base = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        if try await transport.fileStatus(atPath: base + "/.claude.json")?.kind == .regular { return true }
        return try await transport.fileStatus(atPath: base + "/projects")?.kind == .directory
    }

    /// Runs `operation` over the Host's connection and returns its value.
    private func onHostValue<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let onHost else { throw TransportError.hostFeatureUnavailable(feature: "Claude Code Accounts") }
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        try await onHost { transport in
            let value = try await operation(transport)
            result.withLock { $0 = value }
        }
        guard let value = result.withLock({ $0 }) else { throw CancellationError() }
        return value
    }

    private func add(_ suggestion: AgentUsageReport.AccountSuggestion) async throws {
        try await changeAccounts(.directory(suggestion.directory)) { file, defaultDirectory in
            try file.add(directory: suggestion.directory, name: suggestion.name, defaultDirectory: defaultDirectory)
        }
    }

    private func reportingFailure(_ change: () async throws -> Void) async -> Bool {
        do {
            try await change()
            return true
        } catch {
            accountChangeFailure = AccountChangeFailure(message: Self.accountChangeMessage(for: error))
            return false
        }
    }

    /// Reads the Account file, applies `edit` and replaces the file when it
    /// changed, under the Account file gate, then reads Usage again. The
    /// row's change stays pending until a read started after the write
    /// lands: that read, or a newer one that replaced it; another change to
    /// the same row is refused until then. `edit` gets the Default Account's
    /// directory, which cannot be added again.
    private func changeAccounts(
        _ change: AccountChange, checkingDirectory: String? = nil,
        _ edit: @escaping @Sendable (inout UsageAccountFile, String?) throws -> Void
    ) async throws {
        guard supportsClaudeAccounts else {
            throw ClaudeAccountError.pluginRequirement(
                claudeAccountsRequirement
                    ?? "Claude Code Accounts need plugin \(HeelerPluginFeature.claudeAccounts.minimumVersion) "
                    + "or newer on this Host.")
        }
        guard let onHost else { throw TransportError.hostFeatureUnavailable(feature: "Claude Code Accounts") }
        guard pendingAccountChanges.insert(change).inserted else { throw ClaudeAccountError.busy }
        var defaultDirectory: String?
        if case .available(let report) = snapshotState {
            defaultDirectory = report.claudeProgram?.accounts?.first(where: \.isDefault)?.directory
        }
        let gate = accountFileGate
        do {
            try await onHost { [defaultDirectory] transport in
                try await gate.run {
                    if let checkingDirectory, !(try await Self.holdsClaudeCode(checkingDirectory, over: transport)) {
                        throw ClaudeAccountError.notClaudeDirectory
                    }
                    var file = try UsageAccountFile.decode(try await transport.readUsageAccountFile())
                    let original = file
                    try edit(&file, defaultDirectory)
                    guard file != original else { return }
                    try await transport.replaceUsageAccountFile(try file.encoded())
                }
            }
        } catch {
            pendingAccountChanges.remove(change)
            throw error
        }
        accountChangeWrites[change] = readsStarted
        await readAfterAccountChange()
        // A newer read may have replaced this one: wait for it, or read
        // again when none is underway (turning Claude Code limits on or
        // off drops a read).
        while accountChangeWrites[change] != nil, !Task.isCancelled {
            if request == nil {
                await readAfterAccountChange()
            } else {
                await waitForNextRead()
            }
        }
        // Cancelled before a read showed it.
        if accountChangeWrites.removeValue(forKey: change) != nil { pendingAccountChanges.remove(change) }
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
