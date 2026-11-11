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
    /// A core on a native Windows machine. Its Terminals start in directories of that
    /// machine's form, and Send, staging and Chat each read it for their own rule.
    var isNativeWindowsCore = false
    /// Changes, Skills and Grok Build's status edit run POSIX scripts on the Host.
    /// A native Windows core Host offers none of them, rather than failing once
    /// opened; a native Windows Herdr TUI Host keeps what it has always shown.
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
    var namesNewWorkspaces: Bool { tabNames || desktopAppNaming != nil || namesCreatedWorkspaces }
    /// A Host that names a Workspace it creates, such as a tmux session, and
    /// does not also name Tabs. Existing memberwise callers leave it off.
    var namesCreatedWorkspaces = false

    /// What New Terminal asks for beside a Terminal in this directory. Nil on a
    /// Host that starts none, and for a directory that is not usable, rather
    /// than letting the server pick some other Pane's.
    func newTerminalRequest(workspaceID: String, cwd: String) -> ShellTerminalCreationRequest? {
        guard startsTerminals, startsIn(cwd) else { return nil }
        return ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: cwd)
    }

    /// Whether a Terminal here can start in this directory.
    func startsIn(_ directory: String) -> Bool {
        RemoteHostPath.isStartDirectory(directory, allowingWindows: isNativeWindowsCore)
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
    /// for `coreLinuxChatPrograms` and `coreMacOSChatPrograms`, and on native Windows for
    /// `coreWindowsChatPrograms`, within `windowsCoreChatCandidates`. `isLocatingCore` is a
    /// connection on its way: nothing could start on a core Host before that attempt says
    /// what it is.
    init(
        serverKind: ServerKind, platform: HostPlatform? = nil,
        desktopAppNaming: HerdrAppNaming? = nil, coreKernel: String? = nil,
        coreLinuxChatPrograms: Set<ChatProgram> = confirmedLinuxCoreChatPrograms,
        coreMacOSChatPrograms: Set<ChatProgram> = confirmedMacOSCoreChatPrograms,
        coreWindowsChatPrograms: Set<ChatProgram> = confirmedWindowsCoreChatPrograms,
        isLocatingCore: Bool = false
    ) {
        // A tmux Host starts Agents and Terminals, renames a Workspace, closes
        // a Pane or a Tab, opens a Worktree, and offers Composer Send, Stop, and
        // Chat for confirmed POSIX programs once a probe has named Linux or macOS.
        // It does not rename an Agent, take over a Terminal, or name Tabs.
        guard serverKind != .tmux else {
            let tmuxChatPrograms: Set<ChatProgram>? =
                switch coreKernel {
                case HerdrCoreLocator.linuxKernel: coreLinuxChatPrograms
                case HerdrCoreLocator.macOSKernel: coreMacOSChatPrograms
                default: nil
                }
            self.init(
                startsAgents: true, startsTerminals: true, renameAgent: false, renamesWorkspaces: true,
                worktrees: true, uploads: false, composerSend: true, chat: tmuxChatPrograms != nil,
                tabNames: false, closeTab: true, syncLayoutFromPlugin: false, takeOver: false,
                composerStop: true, chatPrograms: tmuxChatPrograms, hostScripts: false,
                namesCreatedWorkspaces: true)
            return
        }
        let offered = serverKind == .herdrTUI
        let coreOnPosix = serverKind == .herdrCore && platform == .posix
        let coreChatPrograms: Set<ChatProgram>? =
            switch coreKernel {
            case HerdrCoreLocator.linuxKernel where coreOnPosix: coreLinuxChatPrograms
            case HerdrCoreLocator.macOSKernel where coreOnPosix: coreMacOSChatPrograms
            default: nil
            }
        let coreChat = coreChatPrograms != nil
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
            chatPrograms: coreChatPrograms ?? (coreOnWindows ? windowsChatPrograms : nil),
            isNativeWindowsCore: coreOnWindows,
            hostScripts: !coreOnWindows)
    }

    /// What Chat on a native Windows core Host can ever open (ADR 0034). Codex and
    /// OpenCode stay without it.
    static let windowsCoreChatCandidates: Set<ChatProgram> = [.claude, .grok, .pi, .omp]

    /// The programs whose Chat a native Windows core Host opens, each once the owner's
    /// check of it on a Windows machine passed and was recorded in the native Windows
    /// acceptance checklist (`docs/guides/native-windows-testing.md`). On Windows build
    /// 26200 with herdr-core 0.1.16 (2026-11-03), Claude Code 2.1.286 and 2.1.316, and
    /// Pi 1.4.0 with Heeler's extension, each bound, showed its conversation and sent
    /// from Chat. The recheck there (2026-11-04) passed Grok Build 1.0.70, bound from
    /// `opened_at` since its `active_sessions.json` rows carry no `pid_start`, and Oh My
    /// Pi 18.13.3 with a profile and without, whose Sends from Chat had found no input
    /// box under the profile's band (`π-hwa > `).
    static let confirmedWindowsCoreChatPrograms: Set<ChatProgram> = [.claude, .grok, .pi, .omp]

    /// The programs whose Chat a Linux core Host opens, each once the owner's check of
    /// it on hc-lab passed and was recorded (ADR 0034): Claude Code 2.1.288 and 2.1.316
    /// against a mock API (2026-11-02), and, on herdr-core 0.1.13 (2026-11-03), Codex
    /// 0.165.0 started with `--no-daemon` and Grok Build 1.0.70 signed in, and Pi 1.4.0
    /// and Oh My Pi 18.13.3 on an API-key provider. OpenCode stays off, since this list
    /// turns a program on for every release: 2.2.2 passed, but on the recheck
    /// (2026-11-04) a 1.19.5 Agent's last turn never ended in Chat, and every Send from
    /// Chat found no input box on screen.
    static let confirmedLinuxCoreChatPrograms: Set<ChatProgram> = [.claude, .codex, .grok, .pi, .omp]

    /// The programs whose Chat a macOS core Host opens, each once the owner's signed-in
    /// check of it on a Mac passed and was recorded (ADR 0034). OpenCode 2.0 from New
    /// Agent reached only candidates there and 2.1 or later was not run, so it stays off.
    static let confirmedMacOSCoreChatPrograms: Set<ChatProgram> = [.claude, .codex, .grok, .pi, .omp]

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
        RemoteHostPath.isStartDirectory(directory, allowingWindows: serverKind == .herdrCore)
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
        listsTerminals: Bool, capabilities: (Host) -> HostCapabilities
    ) -> [Host] {
        filter { host in
            let offers = capabilities(host)
            return listsTerminals ? offers.startsTerminals : offers.startsAgents
        }
    }

    /// Whether a list offers New at all: it does with no Hosts, and stops only
    /// when every Host it has cannot start the item.
    func offersNewItem(
        listsTerminals: Bool, capabilities: (Host) -> HostCapabilities
    ) -> Bool {
        isEmpty || !offeringNewItem(listsTerminals: listsTerminals, capabilities: capabilities).isEmpty
    }
}
