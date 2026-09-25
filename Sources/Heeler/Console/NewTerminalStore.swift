import Foundation
import Observation

/// The Terminals tab's New Terminal sheet (#316): pick a Host and a
/// Workspace, or a new Workspace at a remote directory, optionally name the
/// tab, and open a plain shell there. Mirrors New Agent's Workspace choice
/// without any Agent fields.
@MainActor
@Observable
final class NewTerminalStore {
    enum State: Equatable {
        case editing
        case creating
        case created(ConsoleTerminal.ID)
        case failed(String)
    }

    enum Target: Equatable {
        case existingWorkspace
        case newWorkspace
    }

    /// What `submit()` dispatches: a tab in an existing Workspace, or a
    /// Workspace whose root pane is the shell.
    enum Destination: Equatable, Sendable {
        case existing(ShellTerminalCreationRequest)
        case newWorkspace(NewWorkspaceSpec, tabLabel: String?)
    }

    let hosts: [Host]

    var selectedHostID: Host.ID? {
        didSet {
            guard selectedHostID != oldValue else { return }
            pickedWorkspaceID = nil
            target = .existingWorkspace
            newWorkspaceDirectory = ""
            newWorkspaceLabel = ""
        }
    }

    /// The picked Workspace while it still exists, else the Host's first in
    /// herdr's order; nil while the Host reports none.
    var selectedWorkspaceID: String? {
        let available = workspaces
        if let pickedWorkspaceID, available.contains(where: { $0.id == pickedWorkspaceID }) {
            return pickedWorkspaceID
        }
        return available.first?.id
    }

    private(set) var target: Target = .existingWorkspace
    private(set) var newWorkspaceDirectory = ""
    var newWorkspaceLabel = ""
    var tabLabel = ""
    private(set) var state: State = .editing

    private var pickedWorkspaceID: String?
    private var isCreating = false
    private let workspacesProvider: (Host.ID) -> [ConsoleWorkspace]
    private let directory: (Host.ID, String) -> String?
    private let remoteHome: (Host.ID) async throws -> String
    private let create: (Destination, Host.ID) async throws -> ShellTerminalIdentity
    private let awaitTerminal: (ShellTerminalIdentity, Host.ID) async -> ConsoleTerminal?

    init(
        hosts: [Host],
        initialHostID: Host.ID? = nil,
        initialWorkspaceID: String? = nil,
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        directory: @escaping (Host.ID, String) -> String?,
        remoteHome: @escaping (Host.ID) async throws -> String,
        create: @escaping (Destination, Host.ID) async throws -> ShellTerminalIdentity,
        awaitTerminal: @escaping (ShellTerminalIdentity, Host.ID) async -> ConsoleTerminal?
    ) {
        self.hosts = hosts
        self.workspacesProvider = workspaces
        self.directory = directory
        self.remoteHome = remoteHome
        self.create = create
        self.awaitTerminal = awaitTerminal
        selectedHostID =
            initialHostID.flatMap { id in hosts.contains { $0.id == id } ? id : nil }
            ?? (hosts.count == 1 ? hosts.first?.id : nil)
        pickedWorkspaceID = initialWorkspaceID
    }

    /// The selected Host's Workspaces in herdr's order.
    var workspaces: [ConsoleWorkspace] {
        guard let selectedHostID else { return [] }
        return workspacesProvider(selectedHostID).sorted { $0.order < $1.order }
    }

    var canSubmit: Bool {
        guard selectedHostID != nil, state != .creating else { return false }
        return target == .newWorkspace || selectedWorkspaceID != nil
    }

    var canDismiss: Bool { state != .creating }

    func selectExistingWorkspace(_ id: String) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        pickedWorkspaceID = id
        target = .existingWorkspace
    }

    /// A name-only New Workspace opens in the Host's home directory.
    func selectNewWorkspace() {
        target = .newWorkspace
    }

    func applyBrowsedDirectory(_ path: String) {
        guard RemoteShellPath.isQuotableAbsolute(path) else { return }
        newWorkspaceDirectory = path
        target = .newWorkspace
    }

    func submit() async {
        guard canSubmit, !isCreating, let hostID = selectedHostID else { return }
        isCreating = true
        defer { isCreating = false }
        state = .creating
        do {
            let destination = try await destination(on: hostID)
            let identity = try await create(destination, hostID)
            guard let terminal = await awaitTerminal(identity, hostID) else {
                state = .failed("The terminal was created, but its Workspace hasn't refreshed yet.")
                return
            }
            state = .created(terminal.id)
        } catch let failure as SubmitFailure {
            state = .failed(failure.message)
        } catch {
            state = .failed(AgentOpenTerminalStore.presentation(for: error).message)
        }
    }

    private struct SubmitFailure: Error {
        let message: String
    }

    /// Resolves the directory the shell opens in. An existing Workspace uses
    /// the one it vouches for; only when it reports none, or for a
    /// name-only New Workspace, does the Host's home directory stand in.
    private func destination(on hostID: Host.ID) async throws -> Destination {
        let label = Self.nonEmptyTrimmed(tabLabel)
        switch target {
        case .existingWorkspace:
            guard let workspaceID = selectedWorkspaceID else {
                throw SubmitFailure(message: "Choose a Workspace.")
            }
            let known = directory(hostID, workspaceID)
            let cwd = if let known { known } else { try await home(on: hostID) }
            return .existing(
                ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: cwd, label: label))
        case .newWorkspace:
            let browsed = Self.nonEmptyTrimmed(newWorkspaceDirectory)
            let cwd = if let browsed { browsed } else { try await home(on: hostID) }
            return .newWorkspace(
                NewWorkspaceSpec(directory: cwd, label: Self.nonEmptyTrimmed(newWorkspaceLabel)),
                tabLabel: label)
        }
    }

    private func home(on hostID: Host.ID) async throws -> String {
        let home: String
        do {
            home = try await remoteHome(hostID)
        } catch {
            throw SubmitFailure(message: StartAgentStore.homeProbeMessage(for: error))
        }
        guard RemoteShellPath.isQuotableAbsolute(home) else {
            throw SubmitFailure(message: "The Host's home directory is not a usable path: \(home)")
        }
        return home
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
