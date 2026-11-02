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
    /// The Composer's Stop, which shows in Send's place.
    var composerStop = true
    var desktopAppNaming: HerdrAppNaming?
    /// The programs Chat opens for; nil for every one it can read.
    var chatPrograms: Set<ChatProgram>?
    /// A core runs what it is given in a directory of its own machine's form.
    var startsInWindowsDirectories = false
    /// Changes and Skills run POSIX scripts on the Host. A native Windows core
    /// Host offers neither, rather than failing once opened; a native Windows
    /// Herdr TUI Host keeps what it has always shown.
    var hostScripts = true

    /// Whether an Agent in this directory offers Changes, wherever it does.
    func offersChanges(directory: String?) -> Bool {
        hostScripts && directory != nil
    }

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
        guard startsTerminals, startsIn(cwd) else { return nil }
        return ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: cwd)
    }

    /// Whether a Terminal here can start in this directory.
    func startsIn(_ directory: String) -> Bool {
        directory.hasPrefix("/")
            || (startsInWindowsDirectories && RemoteHostPath.isWindowsAbsolute(directory))
    }

    /// What a window may do with this Host's terminals. Windows only take
    /// turns where a terminal has one holder.
    func terminalAccess(_ sceneAccess: HostTerminalAccess?) -> HostTerminalAccess {
        takeOver ? sceneAccess ?? .holds : .holds
    }
}

extension HostCapabilities {
    /// `platform` is what the Host's connection reported, nil until it has. A
    /// core Host offers uploads once it is known to take them: over SFTP on POSIX,
    /// through the core's `terminal.put` on native Windows (ADR 0032), which has no
    /// Rename or Worktrees until each passes a test there. It offers Send and Stop
    /// once its platform is known, because the foreground that Send checks takes
    /// another form on native Windows, where Send itself refuses a Terminal whose
    /// shell can outlive its Agent (ADRs 0032 and 0035). `coreKernel` is the core
    /// Host's `uname -s`, known once its locator ran with or without a core: its Chat
    /// opens on Linux and macOS, whose process reads a check of an Agent's session uses,
    /// for `coreChatPrograms`, and on native Windows for `coreWindowsChatPrograms`, within
    /// `windowsCoreChatCandidates`. `isLocatingCore` is a connection on its way: nothing could
    /// start on a core Host before that attempt says what it is.
    init(
        serverKind: ServerKind, platform: HostPlatform? = nil,
        desktopAppNaming: HerdrAppNaming? = nil, coreKernel: String? = nil,
        coreChatPrograms: Set<ChatProgram> = confirmedCoreChatPrograms,
        coreWindowsChatPrograms: Set<ChatProgram> = confirmedWindowsCoreChatPrograms,
        isLocatingCore: Bool = false
    ) {
        let offered = serverKind == .herdrTUI
        let coreOnPosix = serverKind == .herdrCore && platform == .posix
        let coreChat = coreOnPosix && (coreKernel == "Linux" || coreKernel == HerdrCoreLocator.macOSKernel)
        let coreOnWindows =
            serverKind == .herdrCore
            && (platform == .nativeWindows || coreKernel == HerdrCoreLocator.windowsKernel)
        let windowsChatPrograms = coreOnWindows ? coreWindowsChatPrograms.intersection(Self.windowsCoreChatCandidates) : []
        let coreStillUnknown =
            serverKind == .herdrCore && isLocatingCore && platform == nil && coreKernel == nil
        let starts = !coreStillUnknown
        self.init(
            startsAgents: starts, startsTerminals: starts,
            renameAgent: offered, renamesWorkspaces: offered, worktrees: offered || coreOnPosix,
            uploads: offered || coreOnPosix || coreOnWindows,
            composerSend: offered || coreOnPosix || coreOnWindows,
            chat: offered || coreChat || !windowsChatPrograms.isEmpty,
            tabNames: offered, closeTab: true,
            syncLayoutFromPlugin: offered, takeOver: offered,
            composerStop: offered || coreOnPosix || coreOnWindows,
            desktopAppNaming: coreOnPosix ? desktopAppNaming : nil,
            chatPrograms: coreChat ? coreChatPrograms : coreOnWindows ? windowsChatPrograms : nil,
            startsInWindowsDirectories: coreOnWindows,
            hostScripts: !coreOnWindows)
    }

    /// What Chat on a native Windows core Host can ever open (ADR 0034). Codex and
    /// OpenCode stay without it.
    static let windowsCoreChatCandidates: Set<ChatProgram> = [.claude, .grok, .pi, .omp]

    /// The programs whose Chat a native Windows core Host opens. Each joins only when
    /// its owner's check there has passed and is recorded in the native Windows
    /// acceptance checklist (`docs/guides/native-windows-testing.md`). None has yet.
    static let confirmedWindowsCoreChatPrograms: Set<ChatProgram> = []

    /// The programs whose Chat a Linux or macOS core Host opens. Binding works for
    /// Codex, Grok Build, OpenCode, Pi and Oh My Pi, from recordings with no sign-in.
    /// Each joins this list only once the owner's signed-in check of that program
    /// passes and is recorded, and one that fails stays off with its observation saying
    /// why (ADR 0034).
    static let confirmedCoreChatPrograms: Set<ChatProgram> = [.claude]

    /// The programs a macOS core Host binds exactly, each from reads the macOS
    /// recordings saw it through (ADR 0034, `host-evidence/macos`). Taking one out
    /// leaves it to the candidate list on macOS, and changes nothing on Linux.
    static let macOSExactCoreChatPrograms = Set(ChatProgram.allCases)
}

extension Host {
    var capabilities: HostCapabilities { HostCapabilities(serverKind: serverKind) }

    /// For a directory the Host reported, which says its own platform: a core
    /// Host's is a Windows path only on native Windows.
    func reportedDirectoryStartsTerminals(_ directory: String) -> Bool {
        directory.hasPrefix("/") || (serverKind == .herdrCore && RemoteHostPath.isWindowsAbsolute(directory))
    }
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
    /// Terminals on the Terminals tab. With none, it is not offered. What a
    /// connection has learned of a Host comes through `capabilities`.
    func offeringNewItem(
        listsTerminals: Bool, capabilities: (Host) -> HostCapabilities = \.capabilities
    ) -> [Host] {
        filter { host in
            let offers = capabilities(host)
            return listsTerminals ? offers.startsTerminals : offers.startsAgents
        }
    }

    /// Whether a list offers New at all: it does with no Hosts, and stops only
    /// when every Host it has cannot start the item.
    func offersNewItem(
        listsTerminals: Bool, capabilities: (Host) -> HostCapabilities = \.capabilities
    ) -> Bool {
        isEmpty || !offeringNewItem(listsTerminals: listsTerminals, capabilities: capabilities).isEmpty
    }
}
