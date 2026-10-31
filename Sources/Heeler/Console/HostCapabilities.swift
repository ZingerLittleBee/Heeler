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
    /// One client at a time holds a terminal, so another may take it over. A
    /// herdr-core Terminal has no such thing: every viewer may type (ADR 0031).
    var takeOver = true

    func renameWorkspace(id: String) -> Bool { renamesWorkspaces }

    /// What New Terminal asks for beside a Terminal in this directory. Nil on a
    /// Host that starts none, and for a directory that is not usable, rather
    /// than letting the server pick some other Pane's.
    func newTerminalRequest(workspaceID: String, cwd: String) -> ShellTerminalCreationRequest? {
        guard startsTerminals, cwd.hasPrefix("/") else { return nil }
        return ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: cwd)
    }

    /// What a window may do with this Host's terminals. Windows only take
    /// turns where a terminal has one holder.
    func terminalAccess(_ sceneAccess: HostTerminalAccess?) -> HostTerminalAccess {
        takeOver ? sceneAccess ?? .holds : .holds
    }
}

extension HostCapabilities {
    init(serverKind: ServerKind) {
        let offered = serverKind == .herdrTUI
        self.init(
            opensDetail: true, startsAgents: offered, startsTerminals: offered,
            renameAgent: offered, renamesWorkspaces: offered, worktrees: offered, uploads: offered,
            composerSend: offered, chat: offered, tabNames: offered, closeTab: offered,
            syncLayoutFromPlugin: offered, takeOver: offered)
    }
}

extension Host {
    var capabilities: HostCapabilities { HostCapabilities(serverKind: serverKind) }
}

/// What an Agent's row offers besides its pin, by what its Host can do.
struct ConsoleAgentRowOffers: Equatable {
    let opensDetail: Bool
    let opensInNewWindow: Bool
    let closes: Bool

    init(opensDetail: Bool, opensInNewWindow: Bool, closes: Bool) {
        self.opensDetail = opensDetail
        self.opensInNewWindow = opensInNewWindow
        self.closes = closes
    }

    init(capabilities: HostCapabilities, supportsMultipleWindows: Bool) {
        self.init(
            opensDetail: capabilities.opensDetail,
            opensInNewWindow: capabilities.opensDetail && supportsMultipleWindows,
            closes: capabilities.closeTab)
    }
}

extension Collection<Host> {
    /// The Hosts a list's New button can start something on: Agents, or
    /// Terminals on the Terminals tab. With none, it is not offered.
    func offeringNewItem(listsTerminals: Bool) -> [Host] {
        filter { listsTerminals ? $0.capabilities.startsTerminals : $0.capabilities.startsAgents }
    }

    /// Whether a list offers New at all: it does with no Hosts, and stops only
    /// when every Host it has cannot start the item.
    func offersNewItem(listsTerminals: Bool) -> Bool {
        isEmpty || !offeringNewItem(listsTerminals: listsTerminals).isEmpty
    }
}
