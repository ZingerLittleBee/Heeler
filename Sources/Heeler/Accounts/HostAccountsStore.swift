import Foundation
import Observation
import os

/// One Host's Accounts for every harness (#621): the one place they are
/// added, renamed and removed. The Host's Account file is the list; Usage,
/// Chat and Launch Presets all read it. For the harnesses Usage reads, its
/// report adds each Account's state, the Default Account's directory and
/// suggested directories, and a change keeps its row busy until Usage has
/// read the Host again.
@MainActor
@Observable
final class HostAccountsStore {
    /// Runs one operation over the Host's connection: on a herdr-core Host, the
    /// Host Helper's Account file beside the Host's own file services (ADR 0033).
    typealias HostOperation = @MainActor (
        _ operation: @escaping @Sendable (any HostServices & HostNotificationFiles) async throws -> Void
    ) async throws -> Void

    /// What one change is about, so its row can show a spinner.
    enum Change: Hashable, Sendable {
        /// Renaming or removing an Account, by its id (`default` for the
        /// Default Account).
        case account(SupportedAgentKind, String)
        /// Adding or ignoring a directory.
        case directory(SupportedAgentKind, String)
        /// Naming the variable a harness's Accounts set.
        case variable(SupportedAgentKind)
    }

    /// A change that could not be saved, for an alert.
    struct ChangeFailure: Identifiable, Equatable, Sendable {
        let id = UUID()
        let message: String
    }

    /// How adding a directory chosen in the remote browser ended.
    enum ChosenDirectoryOutcome: Equatable, Sendable {
        case added
        /// Shown in place, beside the browser.
        case refused(AgentAccountError)
        /// Reported in `changeFailure`.
        case failed
    }

    /// One Account as the Accounts screen lists it.
    struct Row: Equatable, Sendable, Identifiable {
        /// `default` for the Default Account; otherwise the file's id.
        let id: String
        let isDefault: Bool
        /// nil for the Default Account without a name of its own.
        let name: String?
        /// nil for a Default Account whose directory the harness decides
        /// and Usage does not report.
        let directory: String?
        /// Usage's word on the Account, for the harnesses it reads.
        let state: AgentUsageReport.Account.State?

        var displayName: String { name ?? AgentUsageReport.Account.defaultDisplayName }
    }

    enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The harnesses Usage reads, listed whether or not they have Accounts.
    nonisolated static let usageKinds: [SupportedAgentKind] = [.claude, .codex]

    let hostID: Host.ID
    private(set) var loadState: LoadState = .idle
    /// The Account file as last read or written.
    private(set) var file = UsageAccountFile()
    /// A failed refresh keeps this file authoritative over Usage's older list.
    private var hasLoadedFile = false
    /// Changes being saved, or read back by Usage.
    private(set) var pendingChanges: Set<Change> = []
    /// The last change that could not be saved; its alert, or the screen
    /// closing, clears it.
    var changeFailure: ChangeFailure?
    /// The Host's home folder, once asked for: directories show it as `~`.
    private(set) var hostHome: String?

    @ObservationIgnored private let onHost: HostOperation?
    /// Serializes the Account file's read, edit and replace. Hosts that
    /// share a plugin config directory share the file, so the Console
    /// passes one gate for every Host, as for the registration file.
    @ObservationIgnored private let fileGate: GitExecGate
    @ObservationIgnored private let usage: @MainActor () -> AgentUsageStore?
    /// Called after a change lands, so Chat and Launch Presets can follow.
    @ObservationIgnored var didChange: (@MainActor () -> Void)?

    init(
        hostID: Host.ID, onHost: HostOperation?, fileGate: GitExecGate = GitExecGate(),
        usage: @escaping @MainActor () -> AgentUsageStore? = { nil }
    ) {
        self.hostID = hostID
        self.onHost = onHost
        self.fileGate = fileGate
        self.usage = usage
    }

    convenience init(
        hostID: Host.ID, transports: any NotificationTransportProvider,
        usage: @escaping @MainActor () -> AgentUsageStore? = { nil }
    ) {
        self.init(
            hostID: hostID,
            onHost: { operation in
                try await transports.withNotificationTransport(for: hostID) { try await operation($0) }
            },
            usage: usage)
    }

    // MARK: Reading

    /// Reads the Host's Account file and its home folder. A failure stays
    /// visible and is rethrown so a launch cannot use stale variables.
    func load() async throws {
        if case .idle = loadState { loadState = .loading }
        do {
            let gate = fileGate
            let data = try await onHostValue { transport in
                try await gate.run { try await transport.readUsageAccountFile() }
            }
            file = try UsageAccountFile.decode(data)
            hasLoadedFile = true
            loadState = .loaded
        } catch {
            loadState = .failed(Self.changeMessage(for: error))
            throw error
        }
        if hostHome == nil { hostHome = try? await onHostValue { try await $0.hostHomeDirectory() } }
    }

    /// Usage's reading of `kind`, when Usage reads it and has a report.
    private func usageProgram(_ kind: SupportedAgentKind) -> AgentUsageReport.Program? {
        guard Self.usageKinds.contains(kind), case .available(let report) = usage()?.state else { return nil }
        return report.programs?.first { $0.program == kind.rawValue }
    }

    /// `kind`'s Default Account, then its added ones in the file's order.
    /// The file is the list once it is read: Usage adds only each
    /// Account's state, by id, and the Default Account's folder. Until the
    /// file is read, Usage's list stands in for it.
    func rows(for kind: SupportedAgentKind) -> [Row] {
        let reported = usageProgram(kind)?.accounts
        guard hasLoadedFile || reported == nil else {
            return (reported ?? []).map { account in
                Row(
                    id: account.id, isDefault: account.isDefault, name: account.name,
                    directory: account.directory, state: account.state)
            }
        }
        let byID = Dictionary((reported ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let defaultName = file.defaultDisplayName(for: kind)
        let defaultRow = Row(
            id: UsageAccountFile.defaultAccountID, isDefault: true,
            name: defaultName == AgentUsageReport.Account.defaultDisplayName ? nil : defaultName,
            directory: byID[UsageAccountFile.defaultAccountID]?.directory,
            state: byID[UsageAccountFile.defaultAccountID]?.state)
        return [defaultRow] + file.accounts(for: kind).map { account in
            // A state Usage read for another folder under this id is not this Account's.
            let reading = byID[account.id].flatMap { $0.directory == account.directory ? $0 : nil }
            return Row(
                id: account.id, isDefault: false, name: account.name, directory: account.directory,
                state: reading?.state)
        }
    }

    /// Directories Usage suggests for `kind`, none counted until added;
    /// one the file already lists or ignores is left out.
    func suggestions(for kind: SupportedAgentKind) -> [AgentUsageReport.AccountSuggestion] {
        let suggested = usageProgram(kind)?.accountSuggestions ?? []
        guard hasLoadedFile else { return suggested }
        let known = Set((file.directories(for: kind) + file.ignored(for: kind)).map(Self.comparable))
        return suggested.filter { !known.contains(Self.comparable($0.directory)) }
    }

    private static func comparable(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The Default Account's directory, where Usage reports it.
    func defaultDirectory(for kind: SupportedAgentKind) -> String? {
        rows(for: kind).first(where: \.isDefault)?.directory
    }

    /// The variable `kind`'s Accounts set when an Agent is launched.
    func variable(for kind: SupportedAgentKind) -> String? { file.variable(for: kind) }

    /// The harnesses the screen lists: those Usage reads, then every other
    /// one with an Account, in herdr's order.
    var shownKinds: [SupportedAgentKind] {
        Self.usageKinds + SupportedAgentKind.allCases.filter { kind in
            !Self.usageKinds.contains(kind) && !file.accounts(for: kind).isEmpty
        }
    }

    /// Whether another Account of `kind` fits on this Host.
    func isFull(_ kind: SupportedAgentKind) -> Bool {
        file.accounts(for: kind).count >= UsageAccountFile.accountLimit
    }

    func isChanging(_ change: Change) -> Bool { pendingChanges.contains(change) }

    /// Whether `name` already names another of `kind`'s Accounts, as the
    /// rename alert checks before Save. An empty name for the Default
    /// Account stands for "Default".
    func isNameTaken(_ name: String, renaming row: Row, for kind: SupportedAgentKind) -> Bool {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.isDefault, name.isEmpty { name = AgentUsageReport.Account.defaultDisplayName }
        return rows(for: kind).contains { $0.id != row.id && $0.displayName == name }
    }

    // MARK: Changes

    /// Adds a suggested directory under its suggested name.
    @discardableResult
    func add(_ suggestion: AgentUsageReport.AccountSuggestion, for kind: SupportedAgentKind) async -> Bool {
        await reportingFailure {
            try await self.change(.directory(kind, suggestion.directory)) { file, defaultDirectory in
                try file.add(
                    directory: suggestion.directory, name: suggestion.name, defaultDirectory: defaultDirectory,
                    for: kind)
            }
        }
    }

    /// Adds a directory picked in the remote browser. It must look like the
    /// harness's own (`SupportedAgentKind.accountMarkers`); one a suggestion
    /// offers is added as that suggestion.
    func add(directory: String, for kind: SupportedAgentKind) async -> ChosenDirectoryOutcome {
        do {
            if let suggestion = suggestions(for: kind).first(where: { $0.directory == directory }) {
                try await change(.directory(kind, directory)) { file, defaultDirectory in
                    try file.add(
                        directory: suggestion.directory, name: suggestion.name, defaultDirectory: defaultDirectory,
                        for: kind)
                }
            } else {
                try await change(.directory(kind, directory), checking: (directory, kind)) { file, defaultDirectory in
                    try file.add(directory: directory, defaultDirectory: defaultDirectory, for: kind)
                }
            }
            return .added
        } catch let refusal as AgentAccountError {
            return .refused(refusal)
        } catch {
            changeFailure = ChangeFailure(message: Self.changeMessage(for: error))
            return .failed
        }
    }

    /// Renames an Account; an empty name gives the Default Account back
    /// its "Default".
    @discardableResult
    func rename(_ row: Row, to name: String, for kind: SupportedAgentKind) async -> Bool {
        await reportingFailure {
            try await self.change(.account(kind, row.id)) { file, _ in
                try file.rename(
                    accountID: row.isDefault ? UsageAccountFile.defaultAccountID : row.id, to: name, for: kind)
            }
        }
    }

    /// Removes an added Account. The Default Account stays.
    @discardableResult
    func remove(_ row: Row, for kind: SupportedAgentKind) async -> Bool {
        guard !row.isDefault else { return false }
        return await reportingFailure {
            try await self.change(.account(kind, row.id)) { file, _ in
                file.remove(accountID: row.id, for: kind)
            }
        }
    }

    /// Dismisses a suggestion; the plugin stops offering its directory.
    @discardableResult
    func ignore(_ suggestion: AgentUsageReport.AccountSuggestion, for kind: SupportedAgentKind) async -> Bool {
        await reportingFailure {
            try await self.change(.directory(kind, suggestion.directory)) { file, defaultDirectory in
                try file.ignore(directory: suggestion.directory, defaultDirectory: defaultDirectory, for: kind)
            }
        }
    }

    /// Names the variable `kind` reads its config directory from; empty
    /// goes back to the harness's own.
    @discardableResult
    func setVariable(_ variable: String, for kind: SupportedAgentKind) async -> Bool {
        await reportingFailure {
            try await self.change(.variable(kind)) { file, _ in try file.setVariable(variable, for: kind) }
        }
    }

    /// A remote directory browser over this Host's connection, for Choose
    /// Another Directory…: it starts in the home folder and lists symbolic
    /// links to directories too, since a harness reads a directory by the
    /// path it is given. nil without a connection.
    func directoryBrowser() -> RemoteDirectoryBrowser? {
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

    nonisolated static func changeMessage(for error: any Error) -> String {
        switch error {
        case let error as AgentAccountError: error.message
        case NotificationRegistrationError.pluginNotInstalled:
            "Enable the Heeler plugin on this Host to change its Accounts."
        case NotificationRegistrationError.readFailed, NotificationRegistrationError.pluginProbeFailed:
            "Heeler could not read this Host’s Accounts. Try again."
        case NotificationRegistrationError.writeFailed:
            "Heeler could not save this Host’s Accounts. Try again."
        case TransportError.hostFeatureUnavailable:
            "Accounts are not available on this Host."
        default:
            "Could not change the Accounts. Check the Host connection and try again."
        }
    }

    /// Whether `directory` looks like `kind`'s config directory: it holds
    /// one of the harness's own files, or, for a harness Heeler knows none
    /// of, is a directory.
    nonisolated static func holdsHarness(
        _ kind: SupportedAgentKind, at directory: String, over transport: any HostServices
    ) async throws -> Bool {
        let base = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let markers = kind.accountMarkers
        guard !markers.isEmpty else { return try await transport.fileStatus(atPath: base)?.kind == .directory }
        for marker in markers {
            if try await transport.fileStatus(atPath: base + "/" + marker.name)?.kind == marker.kind { return true }
        }
        return false
    }

    // MARK: Plumbing

    private func onHostValue<Value: Sendable>(
        _ operation: @escaping @Sendable (any HostServices & HostNotificationFiles) async throws -> Value
    ) async throws -> Value {
        guard let onHost else { throw TransportError.hostFeatureUnavailable(feature: "Accounts") }
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        try await onHost { transport in
            let value = try await operation(transport)
            result.withLock { $0 = value }
        }
        guard let value = result.withLock({ $0 }) else { throw CancellationError() }
        return value
    }

    private func reportingFailure(_ change: () async throws -> Void) async -> Bool {
        do {
            try await change()
            return true
        } catch {
            changeFailure = ChangeFailure(message: Self.changeMessage(for: error))
            return false
        }
    }

    /// Reads the Account file, applies `edit` and replaces the file when it
    /// changed, under the file gate. For a harness Usage reads, the row
    /// stays busy until Usage has read the Host again; another change to
    /// it is refused until then. `edit` gets the Default Account's
    /// directory, which cannot be added again.
    private func change(
        _ change: Change, checking: (directory: String, kind: SupportedAgentKind)? = nil,
        _ edit: @escaping @Sendable (inout UsageAccountFile, String?) throws -> Void
    ) async throws {
        guard let onHost else { throw TransportError.hostFeatureUnavailable(feature: "Accounts") }
        guard pendingChanges.insert(change).inserted else { throw AgentAccountError.busy }
        defer { pendingChanges.remove(change) }
        let kind = Self.kind(of: change)
        let defaultDirectory = defaultDirectory(for: kind)
        let gate = fileGate
        let written = OSAllocatedUnfairLock<(file: UsageAccountFile, changed: Bool)?>(initialState: nil)
        try await onHost { transport in
            try await gate.run {
                var file = try UsageAccountFile.decode(try await transport.readUsageAccountFile())
                let original = file
                // A folder already listed, or a full harness, is refused
                // before the Host is asked what the folder holds.
                try edit(&file, defaultDirectory)
                if let checking, !(try await Self.holdsHarness(checking.kind, at: checking.directory, over: transport)) {
                    throw AgentAccountError.notHarnessDirectory(checking.kind)
                }
                let edited = file
                if edited != original { try await transport.replaceUsageAccountFile(try edited.encoded()) }
                written.withLock { $0 = (edited, edited != original) }
            }
        }
        guard let written = written.withLock({ $0 }) else { return }
        file = written.file
        hasLoadedFile = true
        loadState = .loaded
        guard written.changed else { return }
        didChange?()
        if Self.usageKinds.contains(kind), let usage = usage() { await usage.showAccountFileChange() }
    }

    private static func kind(of change: Change) -> SupportedAgentKind {
        switch change {
        case .account(let kind, _), .directory(let kind, _), .variable(let kind): kind
        }
    }
}
