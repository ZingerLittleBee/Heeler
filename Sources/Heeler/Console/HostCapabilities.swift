/// What the Herdr desktop app on a core Host can name right now (ADR 0032). None
/// at all while the app cannot be reached or the capability is off.
struct HerdrAppNaming: Equatable, Sendable {
    /// The Workspaces it shows, by Workspace id. A derived Workspace, or a space
    /// it has not adopted yet, is not one of them.
    let workspaceIDs: Set<String>
}

/// Which actions a Host can serve. Actions only Herdr TUI can serve are offered
/// by this rather than attempted and failed; a herdr-core Host offers each one
/// as it is built (ADR 0032). An action's own conditions, such as a Chat's
/// platform or an Agent's linked Worktree, still apply on top.
struct HostCapabilities: Equatable, Sendable {
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
    /// The Composer's Stop, which shows in Send's place. A native Windows core
    /// Host offers it with its own Composer.
    var composerStop = true
    var desktopAppNaming: HerdrAppNaming?
    /// The programs Chat opens for; nil for every one it can read.
    var chatPrograms: Set<ChatProgram>?

    func offersChat(for program: ChatProgram) -> Bool {
        chat && chatPrograms?.contains(program) != false
    }

    func renameWorkspace(id: String) -> Bool {
        renamesWorkspaces || desktopAppNaming?.workspaceIDs.contains(id) == true
    }

    /// Whether New Workspace asks for a name it can apply.
    var namesNewWorkspaces: Bool { tabNames || desktopAppNaming != nil }

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
    /// `platform` is what the Host's connection reported, nil until it has. A
    /// core Host offers uploads once it is known to take them over SFTP: native
    /// Windows stages through the core's `terminal.put` instead (ADR 0032), and
    /// has no Rename or Worktrees until each passes a test there. It offers Send
    /// and Stop once it is known to be POSIX too, because the foreground that Send
    /// checks takes another form on native Windows (ADRs 0032 and 0035). `coreKernel`
    /// is the core Host's `uname -s`: its Chat opens on Linux, whose process reads a
    /// check of an Agent's session uses, for `coreChatPrograms`.
    init(
        serverKind: ServerKind, platform: HostPlatform? = nil,
        desktopAppNaming: HerdrAppNaming? = nil, coreKernel: String? = nil,
        coreChatPrograms: Set<ChatProgram> = confirmedCoreChatPrograms
    ) {
        let offered = serverKind == .herdrTUI
        let coreOnPosix = serverKind == .herdrCore && platform == .posix
        let coreChat = coreOnPosix && coreKernel == "Linux"
        self.init(
            startsAgents: true, startsTerminals: true,
            renameAgent: offered, renamesWorkspaces: offered, worktrees: offered || coreOnPosix,
            uploads: offered || coreOnPosix,
            composerSend: offered || coreOnPosix, chat: offered || coreChat,
            tabNames: offered, closeTab: true,
            syncLayoutFromPlugin: offered, takeOver: offered,
            composerStop: offered || coreOnPosix,
            desktopAppNaming: coreOnPosix ? desktopAppNaming : nil,
            chatPrograms: coreChat ? coreChatPrograms : nil)
    }

    /// The programs whose Chat a Linux core Host opens. Binding works for Codex, Grok
    /// Build, OpenCode, Pi and Oh My Pi, from recordings with no sign-in. Each joins
    /// this list only once the owner's signed-in check of that program passes and is
    /// recorded, and one that fails stays off with its observation saying why
    /// (ADR 0034).
    static let confirmedCoreChatPrograms: Set<ChatProgram> = [.claude]
}

extension Host {
    var capabilities: HostCapabilities { HostCapabilities(serverKind: serverKind) }
}

/// What an Agent's row offers besides its pin, by what its Host can do.
struct ConsoleAgentRowOffers: Equatable {
    let opensInNewWindow: Bool
    let closes: Bool

    init(opensInNewWindow: Bool, closes: Bool) {
        self.opensInNewWindow = opensInNewWindow
        self.closes = closes
    }

    init(capabilities: HostCapabilities, supportsMultipleWindows: Bool) {
        self.init(opensInNewWindow: supportsMultipleWindows, closes: capabilities.closeTab)
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
