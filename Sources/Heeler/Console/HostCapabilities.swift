/// Which actions a Host can serve. Actions only Herdr TUI can serve are offered
/// by this rather than attempted and failed; a herdr-core Host offers each one
/// as it is built (ADR 0032). An action's own conditions, such as a Chat's
/// platform or an Agent's linked Worktree, still apply on top.
struct HostCapabilities: Equatable, Sendable {
    let renameAgent: Bool
    /// Read through `renameWorkspace(id:)`, which answers per Workspace.
    let renamesWorkspaces: Bool
    let worktrees: Bool
    let uploads: Bool
    let composerSend: Bool
    let chat: Bool
    let tabNames: Bool
    let closeTab: Bool
    let syncLayoutFromPlugin: Bool

    func renameWorkspace(id: String) -> Bool { renamesWorkspaces }
}

extension HostCapabilities {
    init(serverKind: ServerKind) {
        let offered = serverKind == .herdrTUI
        self.init(
            renameAgent: offered, renamesWorkspaces: offered, worktrees: offered, uploads: offered,
            composerSend: offered, chat: offered, tabNames: offered, closeTab: offered,
            syncLayoutFromPlugin: offered)
    }
}

extension Host {
    var capabilities: HostCapabilities { HostCapabilities(serverKind: serverKind) }
}
