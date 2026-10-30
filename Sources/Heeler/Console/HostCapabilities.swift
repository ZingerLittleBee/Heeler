/// Which actions a Host can serve. Actions only Herdr TUI can serve are offered
/// by this rather than attempted and failed; a herdr-core Host offers each one
/// as it is built (ADR 0032). An action's own conditions, such as a Chat's
/// platform or an Agent's linked Worktree, still apply on top.
struct HostCapabilities: Equatable, Sendable {
    /// A Terminal's or Agent's row opens its detail.
    let opensDetail: Bool
    let startsAgents: Bool
    let startsTerminals: Bool
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
            opensDetail: offered, startsAgents: offered, startsTerminals: offered,
            renameAgent: offered, renamesWorkspaces: offered, worktrees: offered, uploads: offered,
            composerSend: offered, chat: offered, tabNames: offered, closeTab: offered,
            syncLayoutFromPlugin: offered)
    }
}

extension Host {
    var capabilities: HostCapabilities { HostCapabilities(serverKind: serverKind) }
}

extension Collection<Host> {
    /// The Hosts a list's New button can start something on: Agents, or
    /// Terminals on the Terminals tab. With none, it is not offered.
    func offeringNewItem(listsTerminals: Bool) -> [Host] {
        filter { listsTerminals ? $0.capabilities.startsTerminals : $0.capabilities.startsAgents }
    }
}
