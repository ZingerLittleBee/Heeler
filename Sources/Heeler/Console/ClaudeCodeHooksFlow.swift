import Foundation
import Observation

/// Host detail's Claude Code hooks on a tmux Host (ADR 0044): each configuration
/// root, the default one and each Claude Code Account's (ADR 0037), whether its
/// user settings run Heeler's script, and the change that adds or removes them,
/// shown before anything is written. Both go through the harness configuration
/// edit module. Removing takes out the entries that run Heeler's script,
/// whichever device added them, so this device keeps no record of either.
@MainActor
@Observable
final class ClaudeCodeHooksFlow {
    struct Root: Equatable, Identifiable, Sendable {
        /// Nil for the default root.
        let accountName: String?
        let path: String

        var id: String { path }
        var settingsPath: String { ClaudeCodeHooks.settingsPath(root: path) }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum RootState: Equatable {
        case reading
        /// Nil when the file can't be read with certainty.
        case read(ClaudeCodeHooks.Presence?)
        case review(HarnessConfigPendingChange, adding: Bool)
        case writing
        case refused(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var roots: [Root] = []
    private(set) var states: [Root.ID: RootState] = [:]
    /// The Host's Account file couldn't be read, so only the default root shows.
    private(set) var accountsUnreadable = false

    private var locations: HostHelperProbe.Locations?
    private var isLoading = false

    /// Heeler's own folder, which an addition places the script and the
    /// settings a launch passes in. Nil until the Host says where.
    var scriptFolder: String? { locations.map { ClaudeCodeHooks.folder(dataHome: $0.dataHome) } }
    private let services: @MainActor @Sendable () async throws -> any HostServices
    private let locate: @MainActor @Sendable () async throws -> HostHelperProbe.Locations
    private let place: @MainActor @Sendable () async throws -> Void

    /// `locate` finds the Host's home and data home; `place` puts Heeler's script
    /// and the stored tmux paths it runs on the Host.
    init(
        services: @escaping @MainActor @Sendable () async throws -> any HostServices,
        locate: @escaping @MainActor @Sendable () async throws -> HostHelperProbe.Locations,
        place: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.services = services
        self.locate = locate
        self.place = place
    }

    /// The Accounts are the Host's, in the Host Helper's folder, as on a herdr-core Host.
    static func accountFile(dataHome: String) -> String {
        RemoteFilePath.join(dataHome, HostHelperScript.helperDirectorySuffix, UsageAccountFile.fileName)
    }

    /// Lists the roots and reads each one's settings. Writes nothing. A load
    /// already under way is the one that answers.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        phase = .loading
        do {
            let locations = try await locate()
            self.locations = locations
            let editor = HarnessConfigEditor(files: try await services())
            var roots = [Root(accountName: nil, path: RemoteFilePath.join(locations.home, ".claude"))]
            do {
                let file = try UsageAccountFile.decode(try await editor.read(Self.accountFile(dataHome: locations.dataHome)))
                for account in file.accounts(for: .claude) where !roots.contains(where: { $0.path == account.directory }) {
                    roots.append(Root(accountName: account.name, path: account.directory))
                }
                accountsUnreadable = false
            } catch {
                accountsUnreadable = true
            }
            self.roots = roots
            states = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, .reading) })
            phase = .loaded
            for root in roots { await read(root) }
        } catch {
            phase = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// Shows the change that adds Heeler's hooks to the root's settings, or takes
    /// them out. Writes nothing.
    func review(_ root: Root, adding: Bool) async {
        guard let locations else { return }
        states[root.id] = .reading
        let edit =
            adding
            ? ClaudeCodeHooks.addition(root: root.path, script: ClaudeCodeHooks.scriptPath(dataHome: locations.dataHome))
            : ClaudeCodeHooks.removal(root: root.path)
        do {
            switch try await HarnessConfigEditor(files: try await services()).propose(edit) {
            case .change(let change): states[root.id] = .review(change, adding: adding)
            case .alreadyApplied: await read(root)
            case .refused(_, let reason, _): states[root.id] = .refused(reason)
            }
        } catch {
            states[root.id] = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// The user's word: writes exactly what was shown, if the file still holds
    /// what was read. An addition places the script first, so no settings file
    /// ever runs one that isn't there.
    func accept(_ root: Root) async {
        guard case .review(let change, let adding) = states[root.id] else { return }
        states[root.id] = .writing
        do {
            if adding { try await place() }
            _ = try await HarnessConfigEditor(files: try await services()).apply(change)
            await read(root)
        } catch {
            states[root.id] = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// Leaves a review or a message, and reads the file again.
    func dismiss(_ root: Root) async {
        await read(root)
    }

    private func read(_ root: Root) async {
        guard let locations else { return }
        do {
            let current = try await HarnessConfigEditor(files: try await services()).read(root.settingsPath)
            let script = ClaudeCodeHooks.scriptPath(dataHome: locations.dataHome)
            states[root.id] = .read(ClaudeCodeHooks.presence(in: current, script: script))
        } catch let error as HarnessConfigEditError {
            states[root.id] = error == .tooLarge || error == .unreadable ? .read(nil) : .failed(HarnessConfigEditMessage.text(for: error))
        } catch {
            states[root.id] = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }
}
