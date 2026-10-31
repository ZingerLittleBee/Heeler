import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Agent detail's Chat surface (ADR 0024): the Agent's conversation, read
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
    /// Waits, after a disappear, for the router to say Chat left.
    @State private var stageExit: Task<Void, Never>?
    @State private var isFollowing = true
    /// The banners' height over the timeline's top edge.
    @State private var bannerHeight: CGFloat = 0
    /// Where the Composer and what sits on it begin, in the global space,
    /// and how far it is from there to the screen's bottom.
    @State private var conversationBottom: CGFloat?
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var surfaceHeight: CGFloat = 0
    @State private var jumpRequest = 0
    @State private var followRequest = 0
    @State private var collapseRequest = 0
    @State private var canCollapseTrajectory = false
    @State private var collapseControlHeight: CGFloat = 0
    @State private var composerKeyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    @State private var isConfirmingClose = false
    @State private var isSelectingPhoto = false
    @State private var isSelectingFile = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isStartingAgent = false
    @State private var isManagingSnippets = false
    @State private var isShowingSkillsPicker = false
    @State private var viewingSkill: AgentSkill?
    @State private var agentKeys: ChatAgentKeysStore
    @State private var isRenamingAgent = false
    @State private var isRenamingWorkspace = false
    @State private var closeErrorMessage: String?
    /// The Workspace drawer's panel, while the back header's menu owns it.
    @State private var isHeaderDrawerOpen = false
    /// The Background Work strip's height over the staging bar; zero while
    /// it lists nothing.
    @State private var backgroundWorkHeight: CGFloat = 0
    @State private var isShowingBackgroundWork = false
    /// The row the Background Work sheet opened from.
    @State private var backgroundWorkFocus: String?
    /// This view's own window, for hosts without a scene root.
    @State private var mountedWindow = WindowReference()
    @State private var windowControlsHeight: CGFloat = 0
    /// Shared with the terminal: one reading preference across surfaces.
    @AppStorage("agent.back-header-expanded") private var isBackHeaderExpanded = false
    @AppStorage(ChatFoldSettings.defaultsKey) private var foldsFinishedTurns = true
    @AppStorage(ChatTextSettings.sizeOffsetKey) private var textSizeOffset = ChatTextSettings.defaultSizeOffset
    @AppStorage(ChatTextSettings.fontKey) private var chatFont = ChatFontOption.system
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sceneWindow) private var sceneWindow
    @Environment(\.detailCrossfade) private var detailCrossfade
    @Environment(\.revealDetailSidebar) private var revealDetailSidebar
    @Environment(\.showsDetailBackButton) private var showsBackButton
    @Environment(\.detailTopChromeInset) private var topChromeInset
    @Environment(\.detailBarRow) private var barRow
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
        // Chat lists only the skills its `/` menu sends, in the menu, the
        // Skills sheet and the tools keyboard alike.
        _skills = State(
            initialValue: AgentTerminalView.makeSkillsStore(for: agent, console: console) {
                ChatCommandMenu.offers($0, for: program)
            })
        let paneID = agent.agent.paneID
        let hostID = agent.hostID
        _agentKeys = State(
            initialValue: ChatAgentKeysStore { [console] keys in
                try await console.sendAgentKeys(keys, to: paneID, on: hostID)
            })
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
                || viewingSkill != nil || isRenamingAgent || isRenamingWorkspace
                || closeErrorMessage != nil || isShowingBackgroundWork,
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
                    onInsert: { composer.insertIntoDraft($0.chatInsertionText) },
                    readSkill: { [console, agent] skill in
                        try await console.readSkillFile(path: skill.path, on: agent.hostID)
                    })
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
            }
        }
        .sheet(isPresented: $isShowingBackgroundWork) {
            if let chat {
                ConsoleSheetContent(ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)) {
                    ChatBackgroundWorkSheet(
                        chat: chat, isHostConnected: isHostConnected, focus: backgroundWorkFocus,
                        sheetPresentation: $0)
                }
            }
        }
        .sheet(item: $viewingSkill) { skill in
            SkillContentSheet(skill: skill) { [console, agent] in
                try await console.readSkillFile(path: skill.path, on: agent.hostID)
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
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
            stageExit?.cancel()
            stageExit = nil
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
            stageExit?.cancel()
            stageExit = ChatStageExit.watch(isOnStage: isOnStage) { [chat, viewerID] in
                chat?.hide(viewerID)
            }
        }
        .onChange(of: timelineFeed, initial: true) { _, feed in
            let transcript = chat?.conversation.transcript
            let entries = feed.history.marking(transcript?.entries ?? [])
            timeline.update(
                conversation: feed.generation,
                input: ChatTimelineInput(entries: feed.outputs.marking(entries), pending: feed.pending, older: feed.older),
                turns: transcript?.turns ?? [], precedingTurnEnd: transcript?.precedingTurnEnd, signals: feed.signals,
                isReady: feed.isReady)
        }
        .onChange(of: sentMessages, initial: true) { previous, messages in
            chat?.updateSends(messages)
            // A new message shows at the end, so the list follows it there.
            let earlier = Set(previous.map(\.id))
            if messages.contains(where: { !earlier.contains($0.id) }) { followRequest += 1 }
        }
        .onChange(of: chat.map { $0.blocked.content != .none } ?? false) { _, isReplaced in
            // A Blocked card takes the Composer's place and the tools dock
            // with it. iPad keeps `.tools` without focus, so nothing else
            // would put the dock away.
            guard isReplaced, composerKeyboardPresentation == .tools else { return }
            prepareComposerKeyboardPresentation(.hidden)
            composerKeyboardPresentation = .hidden
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
        .onChange(of: isHostConnected, initial: true) { _, isConnected in
            chat?.hostConnectionChanged(isConnected)
        }
    }

    // MARK: Layout

    private var chatSurface: some View {
        conversation
        .overlay(alignment: .bottom) { floatingTimelineControls }
        .overlay {
            if let workspaceDrawer {
                let drawer = keyboardCarryingDrawer(workspaceDrawer).palette(.system)
                // The back header's menu stands in for the edge handle
                // while the header is out; folded, the handle comes back.
                if isBackHeaderExpanded {
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
            if !showsBackButton {
                AgentEdgeBackGesture { backToConsole() }
            }
        }
        // Above the staging bar, which stays next to the Composer it feeds.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            backgroundWorkStrip
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerStagingStatusBar(staging: session.staging)
                .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerChrome
        }
        // The conversation and its chrome stay together on the keyboard. The
        // tools dock is not a keyboard that moves.
        .keyboardRidePadding(
            keyboardInset, restingInset: composerKeyboardLayout.contentInset,
            isEnabled: composerKeyboardPresentation != .tools)
        // The Composer's fold and the condensed background work change the
        // chrome's height with the keyboard. Out here, so the conversation
        // above them eases along instead of jumping to the final layout.
        .animation(
            reduceMotion ? nil : .spring(response: 0.266, dampingFraction: 1),
            value: condensesBackgroundWork)
        // In place at the system keyboard's last height, as on the terminal,
        // and shown only while the Composer has switched to it.
        .overlay(alignment: .bottom) {
            AgentChatToolsKeyboard(
                insertText: { composer.insertIntoDraft($0) },
                skills: skills.map { store in
                    TerminalSkillsContext(store: store) { viewingSkill = $0 }
                },
                snippets: terminal.snippets,
                manageSnippets: { isManagingSnippets = true },
                agentKeys: agentKeys,
                height: composerKeyboardLayout.availableToolsHeight)
            .opacity(composerKeyboardPresentation == .tools ? 1 : 0)
            .disabled(composerKeyboardPresentation != .tools)
            .allowsHitTesting(composerKeyboardPresentation == .tools)
            .accessibilityHidden(composerKeyboardPresentation != .tools)
        }
        .padding(.top, topInset)
        .overlay(alignment: .top) {
            AgentDetailHeader(
                palette: .system,
                isExpanded: $isBackHeaderExpanded,
                onBack: showsBackButton ? { dismiss() } : nil,
                actions: backHeaderActions,
                surfaceSwitch: terminalSurfaceSwitch,
                title: AgentDetailHeaderTitle(agent),
                trailingInBar: headerSharesBar)
            .padding(.horizontal, 12)
            .padding(.top, backHeaderTop)
            .onChange(of: isBackHeaderExpanded) { _, expanded in
                if !expanded { isHeaderDrawerOpen = false }
            }
        }
        .onWindowControlsHeightChange { windowControlsHeight = $0 }
        .background {
            // Keyboard geometry and the status bar inset follow this view's
            // own window, not whichever window of the app is key. The reader
            // also anchors the keyboard measurement to this screen's own
            // bottom edge, which a tab bar can hold above the window's (see
            // `TerminalKeyboardInset.contentBottomInset`).
            WindowReader(
                onWindow: { window in
                    keyboardInset.attach(to: window)
                    mountedWindow.attach(window)
                },
                onView: { window, view in
                    keyboardInset.attach(to: window, contentAnchor: view)
                })
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea(.all, edges: surfaceEdges)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationBarBackButtonHidden(true)
        .interactivePopGestureEnabled(showsBackButton)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.clear, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .detailHeaderBarControls(
            headerSharesBar,
            palette: .system,
            isExpanded: $isBackHeaderExpanded,
            actions: backHeaderActions,
            surfaceSwitch: terminalSurfaceSwitch)
    }

    /// Over the list's bottom edge, which keeps Collapse Steps' band clear
    /// of rows while it shows.
    private var floatingTimelineControls: some View {
        // The buttons' hit areas reach past their circles, which already
        // leaves a gap between them.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatCollapseTrajectoryButton(
                isVisible: presentation == .timeline && timeline.state.isReady && canCollapseTrajectory
            ) {
                collapseRequest += 1
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapseControlHeight = $0 }
            ChatJumpToLatestButton(
                isVisible: presentation == .timeline && timeline.state.isReady && !isFollowing
            ) {
                jumpRequest += 1
            }
        }
        .chatContentColumn()
    }

    /// The timeline runs edge to edge: under the status bar, the back
    /// header and the banners over its top, and under the Composer and the
    /// home indicator below. At rest its rows sit between them.
    private var conversation: some View {
        ZStack(alignment: .top) {
            ChatTimelineView(
                state: timeline.state, jumpRequest: jumpRequest, followRequest: followRequest,
                collapseRequest: collapseRequest,
                topObstruction: topInset + headerObstruction + bannerHeight,
                bottomEdge: conversationBottom,
                collapseControlClearance: collapseControlHeight,
                textSize: ChatTextSettings.size(system: dynamicTypeSize, offset: textSizeOffset),
                font: chatFont,
                actions: timelineActions)
            .padding(.top, -topInset)
            .ignoresSafeArea(.container, edges: .bottom)
            .accessibilityHidden(presentation != .timeline)
            .modifier(HiddenConversation(isHidden: hidesConversation))
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
            ChatScrollEdgeEffect(edge: .top, height: topInset + headerObstruction, solid: topInset)
                .padding(.top, -topInset)
            banners
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                .padding(.top, headerObstruction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hung from the conversation's bottom edge down to the screen's, so
        // it never sizes the conversation: as a sibling it could outgrow the
        // room left above a raised keyboard, push the chrome down and the
        // measured inset with it, and the two then traded places on every
        // layout pass until the watchdog ended the app.
        .overlay(alignment: .bottom) {
            ChatScrollEdgeEffect(
                edge: .bottom, height: bottomChromeHeight,
                solid: bottomChromeHeight - Self.bottomEdgeFadeLength)
                .alignmentGuide(.bottom) { $0[.top] }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { conversationBottom = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomChromeHeight = $0 }
    }

    /// Whether the reason Chat shows takes the place of rows it keeps, such
    /// as OpenCode on its home screen: the placeholder over them has no
    /// background of its own.
    private var hidesConversation: Bool {
        if case .unavailable(let reason) = presentation { return reason.hidesConversation }
        return false
    }

    /// Hides the timeline and keeps touches off it, without rebuilding it,
    /// so the conversation comes back where it was.
    private struct HiddenConversation: ViewModifier {
        let isHidden: Bool

        func body(content: Content) -> some View {
            content
                .opacity(isHidden ? 0 : 1)
                .allowsHitTesting(!isHidden)
        }
    }

    /// How far rows fade into the bottom chrome's edge before they blur.
    private static let bottomEdgeFadeLength: CGFloat = 24

    /// The back header's band over the conversation's top edge. Level with
    /// the bar, the header can sit wholly above that edge.
    private var headerObstruction: CGFloat {
        max(0, backHeaderTop + AgentDetailHeader.controlSize + 4 - topInset)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch presentation {
        case .timeline:
            EmptyView()
        case .locating:
            ChatLocatingView()
        case .awaitingHost:
            // The banner above says how the connection is going.
            ContentUnavailableView(
                "Nothing Saved Yet", systemImage: "tray",
                description: Text(
                    "Chat shows this conversation once its Host connects. This device hasn't saved any of it."))
            .accessibilityIdentifier("chat.awaitingHost")
        case .empty:
            ChatEmptyConversationView()
        case .unavailable(let reason) where reason.isAwaitingFirstMessage:
            // A new conversation: the Composer starts it.
            ChatEmptyConversationView(description: reason.explanation)
        case .unavailable(let reason):
            ChatUnavailableView(
                reason: reason, launchNotice: chat?.launchNotice,
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
            ForEach(banners) { @Sendable banner in
                MainActorContent {
                    ChatBanner(
                        systemImage: banner.systemImage, text: banner.text,
                        showsProgress: banner.showsProgress, actionTitle: banner.actionTitle,
                        action: banner.action)
                }
            }
        }
        .chatContentColumn()
        .padding(.top, banners.isEmpty ? 0 : 6)
        .padding(.bottom, banners.isEmpty ? 0 : 2)
    }

    /// Main-actor isolated, and so Sendable for `banners`' `@Sendable`
    /// rows, like `AgentDetailHeaderAction` (#471).
    @MainActor
    private struct Banner: Identifiable {
        let id: String
        let systemImage: String
        let text: String
        var showsProgress = false
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private var bannerContent: [Banner] {
        let lines = ChatBannerLine.lines(
            hostStatus: console.hostStatuses[agent.hostID], conversation: chat?.conversation,
            hasPendingEchoes: !pendingEchoes.isEmpty, launchNotice: chat?.launchNotice)
        let terminalOffered = lines.contains {
            if case .unavailable(let reason, _) = $0 { !reason.isWaiting } else { false }
        }
        return lines.map { line in
            var banner = Banner(
                id: line.id, systemImage: line.systemImage, text: line.text, showsProgress: line.showsProgress)
            switch line {
            case .connecting, .notConnected:
                break
            case .readFailure:
                banner.actionTitle = "Retry"
                banner.action = { chat?.retry() }
            case .unavailable(let reason, _):
                if !reason.isWaiting {
                    banner.actionTitle = AgentDetailSurface.terminal.showTitle
                    banner.action = { showAgentTerminal() }
                }
            case .launch:
                if !terminalOffered {
                    banner.actionTitle = AgentDetailSurface.terminal.showTitle
                    banner.action = { showAgentTerminal() }
                }
            }
            return banner
        }
    }

    // MARK: Conversation

    private var presentation: ChatSurfacePresentation {
        ChatSurfacePresentation(
            conversation: chat?.conversation, hasPendingEchoes: !pendingEchoes.isEmpty,
            isHostConnected: isHostConnected, checkingLaunch: chat?.isCheckingLaunch ?? false)
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
        /// What decides whether a turn runs or folds.
        var signals: ChatTurnSignals
        var isReady: Bool
    }

    private var timelineFeed: TimelineFeed {
        guard let chat else {
            return TimelineFeed(
                generation: 0, revision: 0, older: .reachedStart, pending: [], history: BlockedHistory(),
                outputs: ChatToolOutputs(), signals: ChatTurnSignals(), isReady: false)
        }
        let conversation = chat.conversation
        let pending = pendingEchoes
        var isReady = !conversation.transcript.entries.isEmpty || !pending.isEmpty
        if case .locating = conversation.phase {} else { isReady = true }
        // Work that has shown no sign of itself for hours keeps no turn open.
        let signals = ChatTurnSignals(
            activity: ChatAgentActivity(agent.agent.status),
            isBackgroundWorkRunning: chat.backgroundWork.rows.contains { $0.isRunning && !$0.isStale },
            foldsFinishedTurns: foldsFinishedTurns,
            isLive: ChatTurnSignals.isLive(hostStatus: console.hostStatuses[agent.hostID], conversation: conversation),
            olderAwaitsUser: conversation.olderAwaitsUser)
        return TimelineFeed(
            generation: chat.conversationGeneration, revision: conversation.revision,
            older: conversation.older, pending: pending, history: chat.blocked.history, outputs: chat.outputs,
            signals: signals, isReady: isReady)
    }

    private var timelineActions: ChatTimelineActions {
        ChatTimelineActions(
            loadOlder: { chat?.loadOlder() },
            loadOlderAutomatically: { chat?.loadOlder(automatic: true) },
            followingChanged: { isFollowing = $0 },
            firstPositionedLayout: { detailCrossfade?.contentDidAppear() },
            loadOutput: { chat?.loadOutput($0) },
            missingOutputText: missingOutputText,
            loadImage: { [weak chat] path in
                guard let chat else { throw ChatImagePreviewError.unavailable }
                return try await chat.readImage(at: path)
            },
            collapseAvailabilityChanged: { canCollapseTrajectory = $0 })
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
            agentIsIdle: ChatAgentActivity(agent.agent.status) == .idle,
            program: program)
    }

    private var skillNames: Set<String> {
        Set(skills?.skills.map(\.name) ?? [])
    }

    private var sendRules: ChatSendRules {
        ChatSendRules(program: program, commands: commands)
    }

    private var sendPolicy: ComposerDeliveryPolicy {
        .chat(
            rules: sendRules, activity: agentActivity, readScreen: readAgentScreen, confirmSession: confirmSession,
            sendConcern: sendConcern, willReadScreen: registerSends)
    }

    /// Whether the program still shows the conversation Chat shows, for a
    /// program that can leave it without herdr reporting it. Without a
    /// store there is nothing to check with, so nothing is sent.
    private var confirmSession: (@MainActor () async -> String?)? {
        guard program.confirmsSessionBeforeSend else { return nil }
        let chat = chat
        let program = program
        return {
            guard let chat else { return AgentChatStore.uncheckedSessionReason(program) }
            return await chat.confirmSessionBeforeSend()
        }
    }

    /// Hands Chat the Composer's messages as a send's check starts, ahead
    /// of the change that follows the next render, so a new send's witness
    /// mark is on its way before the screen read.
    private var registerSends: @MainActor () -> Void {
        let chat = chat
        let composer = composer
        let rules = sendRules
        return { chat?.updateSends(ChatComposerEchoes.sentMessages(composer.messages, rules: rules)) }
    }

    /// What holds a send the input box would take: a screen showing
    /// another session, or a send the Agent recorded in another one.
    private var sendConcern: @MainActor (String, ANSIScreen) -> String? {
        let chat = chat
        return { text, screen in chat?.sendConcern(for: text, after: screen) }
    }

    /// What herdr reports the Agent doing when asked, not when this view
    /// last rendered.
    private var agentActivity: @MainActor () -> ChatAgentActivity {
        let agentID = agent.id
        return { [console] in
            ChatAgentActivity(console.agents.first { $0.id == agentID }?.agent.status)
        }
    }

    /// The Agent's screen through `agent.read`, for a send and for Stop.
    private var readAgentScreen: @MainActor () async throws -> ANSIScreen {
        let paneID = agent.agent.paneID
        let hostID = agent.hostID
        let chat = chat
        return { [console] in
            let screen = try await console.readAgentScreen(paneID, on: hostID)
            // A steer shown as returned may since have left the box.
            chat?.inputBoxWasRead(screen)
            return screen
        }
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
            keyboardHeight: composerKeyboardLayout.availableToolsHeight,
            actions: composerActions,
            attachLinksPopover: AttachLinksPopover(
                origin: .composerChip, presentedOrigin: .constant(nil), links: [],
                open: { _ in }, copy: { _ in }),
            // The `/` menu takes the inline Skill suggestions' place.
            skills: nil,
            keyboardPresentation: $composerKeyboardPresentation,
            prepareKeyboardPresentation: prepareComposerKeyboardPresentation,
            sendPolicy: sendPolicy,
            commandMenu: commands,
            openAgentTerminal: { showAgentTerminal() },
            inputReplacement: blockedCard,
            focusRequest: chat?.blocked.composerFocusRequest ?? 0,
            collapsesWithoutKeyboard: true,
            interrupt: stopInterrupt)
        .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
        .frame(maxWidth: .infinity)
    }

    /// Chat's Stop: the program's Stop plan, in line with the Agent page's
    /// keys, as typed keys would arrive.
    private var stopInterrupt: AgentComposerInterrupt {
        ChatStopPlan.standard(for: program).composerInterrupt(context: stopContext, agentKeys: agentKeys)
    }

    /// What a Stop guard reads: the screen, then herdr's status.
    private var stopContext: @MainActor () async throws -> ChatStopContext {
        let readScreen = readAgentScreen
        let activity = agentActivity
        return {
            let screen = try await readScreen()
            return ChatStopContext(screen: screen, activity: activity())
        }
    }

    /// A Blocked Agent's dialog, answered in the Composer's place.
    private var blockedCard: AnyView? {
        guard let chat, chat.blocked.content != .none else { return nil }
        return AnyView(
            BlockedCardView(
                store: chat.blocked,
                // Leaves the conversation room above, keyboard up or not;
                // the Background Work line comes out of the card's share.
                maxHeight: max(
                    120, (surfaceHeight - composerKeyboardLayout.contentInset) * 0.4 - backgroundWorkHeight),
                openTerminal: { showAgentTerminal() }))
    }

    // MARK: Background Work

    /// Claude Code's Subagents and Workflows, over the Composer while the
    /// conversation shows. Always present, so its measured height drops to
    /// zero with the last row.
    private var backgroundWorkStrip: some View {
        VStack(spacing: 0) {
            if let chat, presentation == .timeline {
                BackgroundWorkInset(
                    chat: chat, isHostConnected: isHostConnected, isCondensed: condensesBackgroundWork
                ) { focus in
                    backgroundWorkFocus = focus
                    isShowingBackgroundWork = true
                }
            }
        }
        .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { backgroundWorkHeight = $0 }
    }

    /// One line while the Composer is open or a Blocked card stands in its
    /// place: the Composer's own fold, inverted, from what this surface
    /// holds. Focus always moves the keyboard presentation off `.hidden`.
    private var condensesBackgroundWork: Bool {
        !AgentComposerCollapse.isCollapsed(
            isEnabled: true,
            isInputFocused: false,
            keyboardPresentation: composerKeyboardPresentation,
            inheritsKeyboard: keyboardHandoff.mode(for: agent.id) != nil,
            hasInputReplacement: chat.map { $0.blocked.content != .none } ?? false)
    }

    private var isHostConnected: Bool {
        console.hostStatuses[agent.hostID] == .connected
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
            backToConsole: { backToConsole() },
            showAgentTerminal: { showAgentTerminal() },
            closeConfirmation: AgentCloseConfirmation(
                title: title,
                isPresented: $isConfirmingClose,
                close: { Task { await performClose() } }))
    }

    /// The edge swipe's destination, shared with the More menu's entry.
    private func backToConsole() {
        if let revealDetailSidebar { revealDetailSidebar() } else { dismiss() }
    }

    private var agentSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: TerminalAgentSwitcherItem.items(
                for: console.chatDisplayAgents, pins: console.pins,
                layout: { console.rowLayout(for: $0) }),
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
        if composerKeyboardPresentation == .tools, presentation != .tools {
            keyboardInset.skipKeyboardRideLeavingToolsDock()
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

    /// At the same height as the terminal's, so swapping surfaces leaves
    /// the header's controls in place.
    private var backHeaderTop: CGFloat {
        AgentDetailHeader.top(outputTop: topInset, barRow: barRow)
    }

    private var headerSharesBar: Bool { AgentDetailHeader.levelsWithBar(barRow) }

    private var terminalSurfaceSwitch: AgentDetailSurfaceSwitch {
        AgentDetailSurfaceSwitch(current: .chat) { _ in showAgentTerminal() }
    }

    private var backHeaderActions: [AgentDetailHeaderAction] {
        var actions: [AgentDetailHeaderAction] = []
        if workspaceDrawer != nil {
            actions.append(AgentDetailHeaderAction(
                title: "Terminals", systemImage: "apple.terminal.on.rectangle"
            ) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    // Folded, the menu unfolds the header the panel drops from.
                    isBackHeaderExpanded = true
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

/// Reads the Background Work itself, so a change redraws the strip, not the
/// whole surface.
private struct BackgroundWorkInset: View {
    let chat: AgentChatStore
    let isHostConnected: Bool
    let isCondensed: Bool
    let open: (String?) -> Void

    var body: some View {
        ChatBackgroundWorkStrip(
            work: chat.backgroundWork, isHostConnected: isHostConnected, isCondensed: isCondensed, open: open)
    }
}

/// The list's soft edge under chrome: rows passing beneath the status bar,
/// the header's controls or the Composer soften behind a thin material
/// rather than vanish. At full strength for `solid` from the screen's edge,
/// then fading out across the rest of `height`.
private struct ChatScrollEdgeEffect: View {
    let edge: VerticalEdge
    let height: CGFloat
    let solid: CGFloat
    /// How much of the material shows at full strength: rows stay visible
    /// through it, softened rather than hidden.
    var strength: Double = 0.6

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(strength), location: 0),
                        .init(color: .black.opacity(strength), location: height > 0 ? min(1, max(0, solid / height)) : 1),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: edge == .top ? .top : .bottom,
                    endPoint: edge == .top ? .bottom : .top)
            }
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Hides Chat once the router says it left, after a disappear. SwiftUI also
/// hands out disappears nobody caused, and after one it may never report the
/// real departure, so a disappear while Chat is still on stage keeps checking
/// until it isn't, or until the view appears again and cancels the wait.
@MainActor
enum ChatStageExit {
    static func watch(
        isOnStage: @escaping () -> Bool,
        interval: Duration = .seconds(1),
        hide: @escaping () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await Task.yield()
            while !Task.isCancelled {
                if !isOnStage() {
                    hide()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
