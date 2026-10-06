import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Agent detail's Chat surface (ADR 0020): the Agent's conversation, read
/// from the transcript its own program writes, in place of the terminal.
/// It never types into the Agent's PTY; the terminal stays retained per
/// ADR 0017 while Chat shows. The geometry, top chrome and Composer copy the
/// terminal's, so the two swap in place, but in system colors rather than
/// the terminal theme.
struct AgentChatSurfaceView: View {
    let agent: ConsoleAgent
    let program: ChatProgram
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let hosts: [Host]
    /// The Composer and staging the terminal shares, so a draft or an
    /// upload carries across a surface switch.
    private let session: AgentComposerSession
    private var composer: AgentComposerStore { session.composer }
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    /// Router truth: the detail shows, with Chat as its surface.
    private let isOnStage: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    private let canOpenTerminal: Bool
    private let isOpeningTerminal: Bool
    private let openTerminal: () -> Void
    private let showChanges: (() -> Void)?
    private let workspaceDrawer: WorkspaceTerminalDrawer?
    /// Swaps the detail back to the Agent terminal.
    private let selectSurface: (AgentDetailSurface) -> Void

    @State private var timeline = ChatTimelineModel()
    @State private var skills: SkillsPaneStore?
    @State private var closer: ClosePaneStore
    /// This view's token with the Chat store, which follows the
    /// conversation while any window shows it.
    @State private var viewerID = UUID()
    @State private var isFollowing = true
    /// The banners' height over the timeline's top edge.
    @State private var bannerHeight: CGFloat = 0
    @State private var surfaceHeight: CGFloat = 0
    @State private var jumpRequest = 0
    @State private var followRequest = 0
    @State private var composerKeyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    @State private var isConfirmingClose = false
    @State private var isSelectingPhoto = false
    @State private var isSelectingFile = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isStartingAgent = false
    @State private var isManagingSnippets = false
    @State private var isShowingSkillsPicker = false
    @State private var isRenamingAgent = false
    @State private var isRenamingWorkspace = false
    @State private var closeErrorMessage: String?
    /// The Workspace drawer's panel, while the back header's button owns it.
    @State private var isHeaderDrawerOpen = false
    /// This view's own window, for hosts without a scene root.
    @State private var mountedWindow = WindowReference()
    @State private var windowControlsHeight: CGFloat = 0
    /// Shared with the terminal: one reading preference across surfaces.
    @AppStorage("agent.back-header-expanded") private var isBackHeaderExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sceneWindow) private var sceneWindow
    @Environment(\.detailCrossfade) private var detailCrossfade
    @Environment(\.revealDetailSidebar) private var revealDetailSidebar
    @Environment(\.showsDetailBackHeader) private var showsBackHeader
    @Environment(\.detailTopChromeInset) private var topChromeInset
    @Environment(\.detailSurfaceEdges) private var surfaceEdges

    init(
        agent: ConsoleAgent,
        program: ChatProgram,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        session: AgentComposerSession,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        canOpenTerminal: Bool,
        isOpeningTerminal: Bool,
        openTerminal: @escaping () -> Void,
        showChanges: (() -> Void)?,
        workspaceDrawer: WorkspaceTerminalDrawer?,
        selectSurface: @escaping (AgentDetailSurface) -> Void
    ) {
        self.agent = agent
        self.program = program
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.session = session
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.isOnStage = isOnStage
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        self.canOpenTerminal = canOpenTerminal
        self.isOpeningTerminal = isOpeningTerminal
        self.openTerminal = openTerminal
        self.showChanges = showChanges
        self.workspaceDrawer = workspaceDrawer
        self.selectSurface = selectSurface
        _skills = State(initialValue: AgentTerminalView.makeSkillsStore(for: agent, console: console))
        let paneID = agent.agent.paneID
        let hostID = agent.hostID
        _closer = State(
            initialValue: ClosePaneStore(paneTitle: AgentTerminalView.displayTitle(for: agent)) {
                [console] in
                try await console.closePane(paneID, on: hostID)
            })
    }

    /// The Agent's Chat; nil while its Host is not in the catalog.
    private var chat: AgentChatStore? {
        console.chatStore(for: agent, program: program)
    }

    var body: some View {
        GeometryReader { proxy in
            presentedSurface
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { surfaceHeight = $0 }
        // Keyboard avoidance is `TerminalKeyboardInset`'s, as on the
        // terminal, so swapping surfaces never changes the proposal.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Registered so the Composer's ⌘↩ has a surface to belong to; ⌘E
        // has nothing to toggle here.
        .modifier(ConsoleTerminalCommandRegistration(
            agentID: agent.id,
            isFocused: false,
            isPresenting: isSelectingPhoto || isSelectingFile || isConfirmingClose
                || isStartingAgent || isManagingSnippets || isShowingSkillsPicker
                || isRenamingAgent || isRenamingWorkspace || closeErrorMessage != nil,
            isOnStage: { @MainActor in isOnStage() },
            toggleInputMode: nil,
            inputMode: .composer))
        .task { composer.open() }
    }

    private var presentedSurface: some View {
        lifecycleSurface
        .photosPicker(
            isPresented: $isSelectingPhoto,
            selection: $selectedPhoto,
            matching: .images)
        .fileImporter(
            isPresented: $isSelectingFile,
            allowedContentTypes: [.data]
        ) { result in
            guard case .success(let url) = result else { return }
            session.staging.begin(.file(url))
        }
        .sheet(isPresented: $isStartingAgent) {
            StartAgentView(
                hosts: hosts,
                console: console,
                origin: StartAgentStore.LaunchOrigin(
                    hostID: agent.hostID,
                    workspaceID: agent.agent.workspaceID,
                    cwd: agent.agent.cwd),
                onStarted: { switchToAgent($0) })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass),
                fitsContent: true))
        }
        .sheet(isPresented: $isManagingSnippets) {
            SnippetsManagementView(store: terminal.snippets)
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isShowingSkillsPicker) {
            if let skills {
                SkillsPickerView(
                    store: skills,
                    onInsert: { composer.insertIntoDraft($0.insertionText) },
                    readSkill: { [console, agent] skill in
                        try await console.readSkillFile(path: skill.path, on: agent.hostID)
                    })
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
            }
        }
        .sheet(isPresented: $isRenamingAgent) {
            RenameSheetView(
                title: "Rename Agent",
                store: RenameStore(
                    subject: .agent(detectedKind: agent.agent.kind),
                    currentValue: agent.agent.name ?? ""
                ) { [console, agent] name in
                    try await console.renameAgent(agent.agent.paneID, name: name, on: agent.hostID)
                })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isRenamingWorkspace) {
            RenameSheetView(
                title: "Rename Workspace",
                store: RenameStore.workspace(
                    currentLabel: agent.workspaceLabel ?? ""
                ) { [console, agent] label in
                    try await console.renameWorkspace(
                        agent.agent.workspaceID, label: label, on: agent.hostID)
                })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
        .confirmationDialog(
            "Close \(title)?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button("Close Agent", role: .destructive) {
                Task { await performClose() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This closes the pane on the Host and removes the agent everywhere. "
                    + "This can't be undone.")
        }
        .alert(
            "Couldn't Close Agent",
            isPresented: Binding(
                get: { closeErrorMessage != nil },
                set: { if !$0 { closeErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(closeErrorMessage ?? "")
        }
    }

    private var lifecycleSurface: some View {
        chatSurface
        .onAppear {
            if isOnStage() {
                // The outgoing surface may have paused the shared inset for
                // its tools dock.
                prepareComposerKeyboardPresentation(composerKeyboardPresentation)
                chat?.show(viewerID)
            }
            // The dissolve waits for the list's first positioned layout;
            // anything else is in place as it appears.
            if presentation != .timeline { detailCrossfade?.contentDidAppear() }
        }
        .onDisappear {
            // SwiftUI also hands out disappears nobody caused; the router
            // says whether Chat really left.
            Task { @MainActor in
                await Task.yield()
                guard !isOnStage() else { return }
                chat?.hide(viewerID)
            }
        }
        .onChange(of: timelineFeed, initial: true) { _, feed in
            let entries = feed.history.marking(chat?.conversation.transcript.entries ?? [])
            timeline.update(
                conversation: feed.generation,
                input: ChatTimelineInput(entries: feed.outputs.marking(entries), pending: feed.pending, older: feed.older),
                isReady: feed.isReady)
        }
        .onChange(of: sentMessages, initial: true) { previous, messages in
            chat?.updateSends(messages)
            // A new message shows at the end, so the list follows it there.
            let earlier = Set(previous.map(\.id))
            if messages.contains(where: { !earlier.contains($0.id) }) { followRequest += 1 }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            session.staging.begin(.photo(PhotosPickerImageSelection(item: item)))
        }
        .onChange(of: composer.draft.hasPrefix("/"), initial: true) { _, opensMenu in
            guard opensMenu, let skills else { return }
            Task { await skills.loadIfNeeded() }
        }
        .onChange(of: skillNames, initial: true) { _, names in
            chat?.skillsDidLoad(names)
        }
    }

    // MARK: Layout

    private var chatSurface: some View {
        conversation
        .overlay(alignment: .bottom) {
            HStack {
                Spacer(minLength: 0)
                ChatJumpToLatestButton(
                    isVisible: presentation == .timeline && timeline.state.isReady && !isFollowing
                ) {
                    jumpRequest += 1
                }
            }
            .chatContentColumn()
            .padding(.bottom, 12)
        }
        .overlay {
            if let workspaceDrawer {
                let drawer = keyboardCarryingDrawer(workspaceDrawer).palette(.system)
                // The back header's button stands in for the edge handle
                // while the header is out; folded, the handle comes back.
                if showsBackHeader, isBackHeaderExpanded {
                    drawer.openedFromHeader(
                        $isHeaderDrawerOpen,
                        panelTop: backHeaderTop + AgentDetailHeader.controlSize + 8)
                } else {
                    drawer
                }
            }
        }
        // Below the Composer, like the terminal's, so its transparent hit
        // region never covers the Composer's leading controls.
        .overlay(alignment: .leading) {
            if !showsBackHeader {
                AgentEdgeBackGesture {
                    if let revealDetailSidebar { revealDetailSidebar() } else { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerStagingStatusBar(staging: session.staging)
                .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerChrome
        }
        .padding(.bottom, composerKeyboardLayout.contentInset)
        .padding(.top, topInset)
        .overlay(alignment: .top) {
            if showsBackHeader {
                AgentDetailHeader(
                    palette: .system,
                    isExpanded: $isBackHeaderExpanded,
                    onBack: { dismiss() },
                    actions: backHeaderActions)
                .padding(.horizontal, 12)
                .padding(.top, backHeaderTop)
                .onChange(of: isBackHeaderExpanded) { _, expanded in
                    if !expanded { isHeaderDrawerOpen = false }
                }
            }
        }
        .onWindowControlsHeightChange { windowControlsHeight = $0 }
        .background {
            // Keyboard geometry and the status bar inset follow this view's
            // own window, not whichever window of the app is key.
            WindowReader { window in
                keyboardInset.attach(to: window)
                mountedWindow.attach(window)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea(.all, edges: surfaceEdges)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationBarBackButtonHidden(true)
        .interactivePopGestureEnabled(showsBackHeader)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.clear, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
    }

    /// The timeline runs under the back header and the banners, which
    /// float over its top edge; at rest its rows start below them.
    private var conversation: some View {
        ZStack(alignment: .top) {
            ChatTimelineView(
                state: timeline.state, jumpRequest: jumpRequest, followRequest: followRequest,
                topObstruction: headerObstruction + bannerHeight, actions: timelineActions)
            .accessibilityHidden(presentation != .timeline)
            if presentation != .timeline {
                GeometryReader { proxy in
                    ScrollView {
                        placeholder
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.top, headerObstruction + bannerHeight)
            }
            if headerObstruction > 0 {
                ChatTopEdgeFade(height: headerObstruction)
            }
            banners
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                .padding(.top, headerObstruction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The back header's band over the conversation's top edge.
    private var headerObstruction: CGFloat {
        showsBackHeader ? 4 + AgentDetailHeader.controlSize + 4 : 0
    }

    @ViewBuilder
    private var placeholder: some View {
        switch presentation {
        case .timeline:
            EmptyView()
        case .locating:
            ChatLocatingView()
        case .empty:
            ChatEmptyConversationView()
        case .unavailable(let reason):
            ChatUnavailableView(
                reason: reason,
                retry: { chat?.retry() },
                showAgentTerminal: { showAgentTerminal() })
        case .disconnected:
            ContentUnavailableView(
                "Not Connected", systemImage: "wifi.slash",
                description: Text("Chat shows the conversation once this Agent's Host connects."))
        }
    }

    /// Always present, so its measured height drops to zero with the last
    /// banner.
    private var banners: some View {
        let banners = bannerContent
        return VStack(spacing: 6) {
            ForEach(banners) { banner in
                ChatBanner(
                    systemImage: banner.systemImage, text: banner.text,
                    showsProgress: banner.showsProgress, actionTitle: banner.actionTitle,
                    action: banner.action)
            }
        }
        .chatContentColumn()
        .padding(.top, banners.isEmpty ? 0 : 6)
        .padding(.bottom, banners.isEmpty ? 0 : 2)
    }

    private struct Banner: Identifiable {
        let id: String
        let systemImage: String
        let text: String
        var showsProgress = false
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private var bannerContent: [Banner] {
        var banners: [Banner] = []
        let status = console.hostStatuses[agent.hostID]
        switch status {
        case .connected?:
            break
        case .connecting?, .reconnecting?:
            banners.append(Banner(id: "host", systemImage: "wifi", text: "Connecting to the Host…", showsProgress: true))
        default:
            banners.append(Banner(id: "host", systemImage: "wifi.slash", text: "Not connected. Showing saved messages."))
        }
        guard status == .connected, let chat else { return banners }
        if let failure = chat.conversation.readFailure {
            banners.append(
                Banner(
                    id: "read", systemImage: "exclamationmark.triangle",
                    text: "Couldn't read the conversation. \(failure.presentation.explanation)",
                    actionTitle: "Retry", action: { chat.retry() }))
        }
        if case .unavailable(let reason) = chat.conversation.phase, presentation == .timeline {
            banners.append(
                Banner(
                    id: "unavailable", systemImage: reason.systemImage, text: reason.bannerText,
                    showsProgress: reason == .noSession(program),
                    actionTitle: reason == .noSession(program) ? nil : AgentDetailSurface.terminal.showTitle,
                    action: { showAgentTerminal() }))
        }
        return banners
    }

    // MARK: Conversation

    private enum Presentation: Equatable {
        case timeline
        case locating
        case empty
        case unavailable(ChatUnavailableReason)
        /// The Host is not in the catalog, so there is no Chat to read.
        case disconnected
    }

    private var presentation: Presentation {
        guard let chat else { return .disconnected }
        let conversation = chat.conversation
        if !conversation.transcript.entries.isEmpty || !pendingEchoes.isEmpty { return .timeline }
        switch conversation.phase {
        case .locating: return .locating
        case .following: return .empty
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    /// What the timeline is rebuilt from; anything else it shows comes
    /// with these.
    private struct TimelineFeed: Equatable {
        var generation: Int
        var revision: Int
        var older: ChatOlderHistory
        var pending: [ChatPendingEcho]
        /// Blocked card answers the entries can't show by themselves.
        var history: BlockedHistory
        /// Output expanded rows read again.
        var outputs: ChatToolOutputs
        var isReady: Bool
    }

    private var timelineFeed: TimelineFeed {
        guard let chat else {
            return TimelineFeed(
                generation: 0, revision: 0, older: .reachedStart, pending: [], history: BlockedHistory(),
                outputs: ChatToolOutputs(), isReady: false)
        }
        let conversation = chat.conversation
        let pending = pendingEchoes
        var isReady = !conversation.transcript.entries.isEmpty || !pending.isEmpty
        if case .locating = conversation.phase {} else { isReady = true }
        return TimelineFeed(
            generation: chat.conversationGeneration, revision: conversation.revision,
            older: conversation.older, pending: pending, history: chat.blocked.history, outputs: chat.outputs,
            isReady: isReady)
    }

    private var timelineActions: ChatTimelineActions {
        ChatTimelineActions(
            loadOlder: { chat?.loadOlder() },
            followingChanged: { isFollowing = $0 },
            firstPositionedLayout: { detailCrossfade?.contentDidAppear() },
            loadOutput: { chat?.loadOutput($0) },
            missingOutputText: missingOutputText)
    }

    /// What an expanded row whose output was never read says until it can
    /// be: saved entries keep no tool output, and a row expanded before the
    /// transcript opens is read once it does.
    private var missingOutputText: String {
        guard console.hostStatuses[agent.hostID] == .connected else { return "Output is available when connected." }
        if case .unavailable = chat?.conversation.phase { return ChatToolOutputFailure.gone.message }
        return "Loading output…"
    }

    private var pendingEchoes: [ChatPendingEcho] {
        ChatComposerEchoes.pending(composer.messages, statuses: chat?.sendStatuses ?? [:])
    }

    private var sentMessages: [AgentChatStore.SentMessage] {
        ChatComposerEchoes.sentMessages(composer.messages, rules: sendRules)
    }

    // MARK: Composer

    /// The `/` menu: the Host's skills once loaded, plus `/compact`.
    private var commands: [ChatCommand] {
        ChatCommandMenu.commands(
            skills: skills?.skills ?? [],
            agentIsIdle: ChatAgentActivity(agent.agent.status) == .idle)
    }

    private var skillNames: Set<String> {
        Set(skills?.skills.map(\.name) ?? [])
    }

    private var sendRules: ChatSendRules {
        ChatSendRules(program: program, commands: commands)
    }

    private var sendPolicy: ComposerDeliveryPolicy {
        let paneID = agent.agent.paneID
        let hostID = agent.hostID
        let agentID = agent.id
        return .chat(
            rules: sendRules,
            activity: { [console] in
                ChatAgentActivity(console.agents.first { $0.id == agentID }?.agent.status)
            },
            readScreen: { [console] in
                try await console.readAgentScreen(paneID, on: hostID)
            })
    }

    private var composerChrome: some View {
        AgentComposerView(
            store: composer,
            status: agent.agent.status,
            hostTelemetry: HostTelemetryPresentation(
                status: console.hostStatuses[agent.hostID],
                latency: console.hostLatencies[agent.hostID]),
            changes: AgentDetailChanges(rows: console.rowChanges, agent: agent, open: showChanges),
            chromeColorScheme: colorScheme,
            switcher: agentSwitcher,
            keyboardHandoff: keyboardHandoff,
            // No tools dock yet, so no keyboard switch.
            keyboardHeight: 0,
            actions: composerActions,
            attachLinksPopover: AttachLinksPopover(
                origin: .composerChip, presentedOrigin: .constant(nil), links: [],
                open: { _ in }, copy: { _ in }),
            // The `/` menu takes the inline Skill suggestions' place.
            skills: nil,
            keyboardPresentation: $composerKeyboardPresentation,
            prepareKeyboardPresentation: prepareComposerKeyboardPresentation,
            surfaceControl: .button(
                systemImage: AgentDetailSurface.terminal.showSystemImage,
                accessibilityLabel: AgentDetailSurface.terminal.showTitle,
                accessibilityHint: AgentDetailSurface.terminal.showAccessibilityHint,
                action: { showAgentTerminal() }),
            sendPolicy: sendPolicy,
            commandMenu: commands,
            openAgentTerminal: { showAgentTerminal() },
            inputReplacement: blockedCard,
            focusRequest: chat?.blocked.composerFocusRequest ?? 0)
        .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
        .frame(maxWidth: .infinity)
    }

    /// A Blocked Agent's dialog, answered in the Composer's place.
    private var blockedCard: AnyView? {
        guard let chat, chat.blocked.content != .none else { return nil }
        return AnyView(
            BlockedCardView(
                store: chat.blocked,
                // Leaves the conversation room above, keyboard up or not.
                maxHeight: max(120, (surfaceHeight - composerKeyboardLayout.contentInset) * 0.4),
                openTerminal: { showAgentTerminal() }))
    }

    private var composerActions: AgentComposerActions {
        AgentComposerActions(
            canBegin: session.staging.canBegin,
            attachLinkCount: 0,
            addImage: { isSelectingPhoto = true },
            addFile: { isSelectingFile = true },
            showAttachLinks: {},
            openTerminal: canOpenTerminal
                ? {
                    armShellTerminalKeyboardHandoffIfKeyboardIsUp()
                    openTerminal()
                } : nil,
            isOpeningTerminal: isOpeningTerminal,
            showChanges: showChanges,
            startAgent: { isStartingAgent = true },
            manageSnippets: { isManagingSnippets = true },
            showSkills: skills != nil ? { isShowingSkillsPicker = true } : nil,
            showWorktreeDetails: nil,
            renameAgent: { isRenamingAgent = true },
            renameWorkspace: { isRenamingWorkspace = true },
            closeAgent: { isConfirmingClose = true },
            showAgentTerminal: { showAgentTerminal() })
    }

    private var agentSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: console.agents.map {
                TerminalAgentSwitcherItem(
                    agent: $0, pins: console.pins, layout: console.rowLayout(for: $0.hostID))
            },
            selectedID: agent.id,
            onSelect: switchToAgent,
            onTogglePin: { id in
                console.togglePin(hostID: id.hostID, paneID: id.paneID)
            })
    }

    // MARK: Keyboard

    private var composerKeyboardLayout: AgentComposerKeyboardLayout {
        AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: composerKeyboardPresentation,
            softwareKeyboardDismissed: keyboardInset.isSoftwareKeyboardDismissed)
    }

    private func prepareComposerKeyboardPresentation(
        _ presentation: AgentComposerKeyboardPresentation
    ) {
        switch presentation {
        case .tools:
            keyboardInset.pauseHeightCapture()
        case .hidden:
            keyboardInset.resumeHeightCapture()
        case .system:
            keyboardInset.resumeHeightCapture()
            keyboardInset.expectSoftwareKeyboard()
        }
    }

    /// Chat types only through its Composer, so a raised keyboard is the
    /// software one.
    private var keyboardIsUp: Bool { keyboardInset.height > 0 }

    /// The terminal takes over in place with the keyboard as Chat leaves it.
    private func showAgentTerminal() {
        if keyboardIsUp { keyboardHandoff.arm(for: agent.id, mode: .text) }
        selectSurface(.terminal)
    }

    /// The selection change rebuilds the detail; the next Agent's surface
    /// claims the keyboard as it comes up.
    private func switchToAgent(_ id: ConsoleAgent.ID) {
        guard id != agent.id else { return }
        if keyboardIsUp { keyboardHandoff.arm(for: id, mode: .text) }
        onSwitch(id)
    }

    private func armShellTerminalKeyboardHandoffIfKeyboardIsUp() {
        if keyboardIsUp {
            keyboardHandoff.armShellTerminal()
        } else {
            keyboardHandoff.cancelShellTerminal()
        }
    }

    private func keyboardCarryingDrawer(_ drawer: WorkspaceTerminalDrawer) -> WorkspaceTerminalDrawer {
        var carrying = drawer
        let onSelect = drawer.onSelect
        carrying.onSelect = { target in
            if let agentID = target.agentID {
                if agentID != agent.id, keyboardIsUp { keyboardHandoff.arm(for: agentID, mode: .text) }
            } else {
                armShellTerminalKeyboardHandoffIfKeyboardIsUp()
            }
            onSelect(target)
        }
        if let onNewTerminal = drawer.onNewTerminal {
            carrying.onNewTerminal = {
                armShellTerminalKeyboardHandoffIfKeyboardIsUp()
                onNewTerminal()
            }
        }
        return carrying
    }

    // MARK: Chrome

    /// The status bar height of the window this view is in.
    private var statusBarInset: CGFloat {
        (sceneWindow?.window ?? mountedWindow.window)?.safeAreaInsets.top ?? 0
    }

    private var topInset: CGFloat {
        max(statusBarInset, topChromeInset, windowControlsHeight)
    }

    private var backHeaderTop: CGFloat { topInset + 4 }

    private var backHeaderActions: [AgentDetailHeaderAction] {
        var actions: [AgentDetailHeaderAction] = []
        if workspaceDrawer != nil {
            actions.append(AgentDetailHeaderAction(
                title: "Workspace Terminals", systemImage: "terminal"
            ) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    isHeaderDrawerOpen.toggle()
                }
            })
        }
        if let showChanges {
            actions.append(AgentDetailHeaderAction(
                title: "Changes", systemImage: "arrow.triangle.branch", perform: showChanges))
        }
        return actions
    }

    private var title: String {
        AgentTerminalView.displayTitle(for: agent)
    }

    private func performClose() async {
        await closer.confirmClose()
        switch closer.state {
        case .closed:
            onClosed()
        case .failed(let message):
            closeErrorMessage = message
        case .idle, .closing:
            break
        }
    }
}

/// Fades rows out where the back header floats over the timeline, as the
/// system's soft scroll edge does under a navigation bar.
private struct ChatTopEdgeFade: View {
    let height: CGFloat

    var body: some View {
        let background = Color(uiColor: .systemBackground)
        LinearGradient(
            stops: [
                .init(color: background, location: 0),
                .init(color: background.opacity(0.85), location: 0.55),
                .init(color: background.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
