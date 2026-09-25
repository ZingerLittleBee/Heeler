import SwiftUI

/// The Console home screen (#8): a bottom tab bar over Agents across every
/// Host (flat or grouped by Host, #245), their ordinary shell Terminals
/// grouped by Workspace or Host (#316), and one Search across both. Host
/// management (#14) lives behind the toolbar button. Every tab is its own
/// split view, but they share one selection and only the selected tab
/// mounts the detail column, so a terminal is never attached twice.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let inputMode: AgentInputModeSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    /// Owns the navigation path (#74): user taps and notification deep links
    /// drive the same stack.
    @Bindable var notificationRouter: AgentNotificationRouter
    /// Announces foreground Blocked/Done transitions in-app (#77).
    let bannerStore: AgentNotificationBannerStore
    /// Per-Host Live Activity start/update/end and the Settings toggle.
    let liveActivities: HostLiveActivityCoordinator
    /// Scene phase widened by the background grace period; an Attach screen
    /// pauses its work on real suspensions only.
    let activity: AppActivityCoordinator
    /// A shell terminal chosen from the Terminals tab or Agent detail's
    /// drawer. It shares the detail column with the router's Agent path;
    /// only one is ever set.
    @State private var selectedTerminal: ConsoleTerminal?
    /// Agents or Terminals, per window; empty until this window picks one.
    /// Search is tracked apart so it is never the tab a window comes back to.
    @SceneStorage("console.list-tab") private var sceneListTab = ""
    /// The last list tab any window picked: where a new window, or a
    /// relaunch that restored no scene state, starts.
    @AppStorage("console.last-list-tab") private var lastListTab: ConsoleTab = .agents
    @State private var isSearchTabSelected = false
    @State private var isHostsTabSelected = false
    @State private var isStartingTerminal = false
    @State private var terminalPresentation = TerminalListPresentationStore()
    /// Where the detail column's navigation bar starts, in window
    /// coordinates. In regular width that is just below the floating tab
    /// bar; see `detailTopChromeInset`.
    @State private var detailTopInset: CGFloat = 0
    /// A request to open the Hosts tab on one Host's detail. Each request
    /// rebuilds the tab so it lands there even when that Host is already
    /// on its stack.
    @State private var hostsTabRequest: HostsTabRequest?
    @State private var isStartingAgent = false
    @State private var isShowingSettings = false
    @State private var connectionDetailRequest: ConnectionDetailRequest?
    /// Hosts whose Host-detail Reconnect request is in flight, including the
    /// 1.2 s visual-feedback hold after `retryHost` returns. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    /// Narrows the Agent list to one Host; nil shows every Host. This is a
    /// filter in both presentations, not a second grouping mechanism.
    @State private var hostFilter: Host.ID?
    /// The Search tab's query (#292, #316): Agents and Terminals together,
    /// after `hostFilter`.
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var commandRegistry = ConsoleCommandRegistry()
    /// Row-level `tab.close` failure text; non-nil shows the error alert.
    @State private var tabCloseError: String?
    /// The Agent whose tab the swipe action would close; non-nil shows the
    /// close confirmation.
    @State private var pendingTabClose: ConsoleAgent?
    /// Owns flat/grouped mode and per-Host collapsed state (#245).
    @State private var listPresentation = ConsoleListPresentationStore()
    /// Outlives the detail column's rebuilds, which is the whole point: it
    /// carries the raised keyboard from one Attach screen to the next.
    @State private var keyboardHandoff = TerminalKeyboardHandoff()
    /// Outlives those rebuilds for the same reason. A per-screen inset starts
    /// every switch at zero and only learns the keyboard's height once UIKit
    /// posts the next frame notification, so the terminal that inherits a
    /// raised keyboard would lay out full height first and shrink a moment
    /// later — an extra reflow, and a Connecting dialog that visibly jumps
    /// from the middle of the screen to the middle of the terminal.
    @State private var keyboardInset = TerminalKeyboardInset()
    @State private var splitVisibility = ConsoleSplitVisibilityState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sceneWindow) private var sceneWindow
    @State private var detailCrossfade = DetailCrossfade()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The window-aware entry into navigation; nil outside a scene root.
    @Environment(\.agentSceneRouting) private var sceneRouting

    var body: some View {
        TabView(selection: selectedTab) {
            Tab(ConsoleTab.agents.title, systemImage: "sparkles", value: ConsoleTab.agents) {
                splitView(for: .agents)
            }
            Tab(ConsoleTab.terminals.title, systemImage: "terminal", value: ConsoleTab.terminals) {
                splitView(for: .terminals)
            }
            Tab(ConsoleTab.hosts.title, systemImage: "server.rack", value: ConsoleTab.hosts) {
                // HostListView brings its own NavigationStack.
                HostListView(
                    store: hosts,
                    initialHostID: hostsTabRequest?.hostID,
                    connectionStatuses: console.hostStatuses,
                    standingFailures: console.hostStandingFailures,
                    latencies: console.hostLatencies,
                    manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
                    retryConnection: { await reconnectHost($0) },
                    origin: hostsTabRequest?.origin.map { origin in
                        HostListOrigin(title: origin.title) { selectedTab.wrappedValue = origin }
                    })
                .id(hostsTabRequest?.id)
            }
            // The system search tab: on iPhone it turns the tab bar into the
            // search field, which only works when `searchable` sits inside
            // this tab rather than around the TabView.
            Tab(value: ConsoleTab.search, role: .search) {
                splitView(for: .search)
            }
        }
        // The detail's actions can present these even while the sidebar is hidden.
        .sheet(isPresented: $isStartingAgent) {
            // StartAgentView brings its own NavigationStack.
            StartAgentView(hosts: hosts.hosts, console: console) { id in
                // A fresh launch lands in its own terminal, exactly
                // as tapping the new row would.
                notificationRouter.path = [id]
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        // Agent rows close from the Agents and Search tabs alike.
        .alert(tabCloseDialogTitle, isPresented: tabCloseDialogPresented) {
            Button(tabCloseConfirmLabel, role: .destructive) { confirmTabClose() }
            Button("Cancel", role: .cancel) { pendingTabClose = nil }
        } message: {
            Text(pendingTabClose.map(tabCloseMessage(for:)) ?? "")
        }
        .alert("Could Not Close", isPresented: tabCloseErrorPresented) {
            Button("OK", role: .cancel) { tabCloseError = nil }
        } message: {
            Text(tabCloseError ?? "")
        }
        .sheet(isPresented: $isStartingTerminal) {
            // NewTerminalView brings its own NavigationStack.
            NewTerminalView(hosts: hosts.hosts, console: console, initialHostID: hostFilter) {
                // A new shell lands in its terminal, as tapping its row would.
                selectTerminal($0)
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(item: $connectionDetailRequest) { request in
            if let host = hosts.hosts.first(where: { $0.id == request.id }),
                let detail = connectionDetail(for: request)
            {
                HostConnectionDetailView(
                    presentation: detail,
                    host: host,
                    catalog: hosts,
                    isRetryInFlight: manualReconnectInFlightHostIDs.contains(host.id)
                ) {
                    // Holds the sheet open through the retry's dial, which a
                    // reconnecting Host makes without a standing failure.
                    connectionDetailRequest?.lastFailure = detail.failure
                    Task { await reconnectHost(host.id) }
                }
            }
        }
        // Once the Host connects again (or leaves the catalog) the sheet has
        // nothing left to explain.
        .onChange(of: connectionDetailRequest.flatMap { connectionDetail(for: $0) }) {
            _, detail in
            if detail == nil { connectionDetailRequest = nil }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                terminal: terminal,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                liveActivities: liveActivities,
                console: console,
                hosts: hosts.hosts)
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .modifier(
            ConsoleStatusBarModifier(
                scheme: terminalStatusBarColorScheme
            )
        )
        // Above the NavigationStack so a banner also shows over a pushed
        // Agent detail; a tap deep-links exactly like a push tap would.
        .overlay(alignment: .top) {
            if let banner = bannerStore.banner {
                AgentNotificationBannerView(banner: banner) {
                    bannerStore.dismiss()
                    openNotificationTarget(banner.target)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: bannerStore.banner)
        // A notification deep link must land on Agent detail even when one of
        // the Console's sheets covers it. The only other push a sheet can
        // cause is the new-agent flow's, which dismisses itself first, so
        // clearing here is a no-op for it.
        .onChange(of: notificationRouter.path) { _, path in
            guard !path.isEmpty else { return }
            selectedTerminal = nil
            // Hosts has no detail column; the Agent shows on its list tab.
            isHostsTabSelected = false
            isStartingAgent = false
            isStartingTerminal = false
            isShowingSettings = false
        }
        // A Host opened on request belongs to that one visit: once the user
        // leaves the Hosts tab, it reopens on its list.
        .onChange(of: isHostsTabSelected) { _, isSelected in
            if !isSelected { hostsTabRequest = nil }
        }
        // A filter pointing at a removed Host would silently hide every
        // Agent; fall back to All Hosts instead.
        .onChange(of: hosts.hosts) { _, hosts in
            if let hostFilter, !hosts.contains(where: { $0.id == hostFilter }) {
                self.hostFilter = nil
            }
        }
        .environment(\.consoleCommandRegistry, commandRegistry)
        .focusedSceneValue(\.consoleCommandTarget, commandTarget)
    }

    /// The TabView's selection: Search on top of the remembered list tab.
    private var selectedTab: Binding<ConsoleTab> {
        Binding(
            get: {
                if isSearchTabSelected { return .search }
                if isHostsTabSelected { return .hosts }
                return ConsoleTab(rawValue: sceneListTab) ?? lastListTab
            },
            set: { tab in
                isSearchTabSelected = tab == .search
                isHostsTabSelected = tab == .hosts
                guard tab.isList else { return }
                sceneListTab = tab.rawValue
                lastListTab = tab
            })
    }

    private var currentTab: ConsoleTab { selectedTab.wrappedValue }

    /// One tab's split view. A split view instead of a plain stack for the
    /// iPad's sake: regular width shows the list beside the Attach terminal;
    /// compact width collapses into the familiar push navigation. The
    /// router's path stays the single source of truth — the sidebar selection
    /// is a projection of it, so notification deep links keep working.
    private func splitView(for tab: ConsoleTab) -> some View {
        GeometryReader { geometry in
            let presentation = ConsoleSplitPresentation(
                horizontalSizeClass: horizontalSizeClass,
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets)
            NavigationSplitView(columnVisibility: Binding(
                get: { splitVisibility.visibility },
                set: { splitVisibility.systemDidChangeVisibility($0, presentation: presentation) })
            ) {
                sidebar(for: tab)
                    .navigationTitle(tab.title)
                    .navigationSplitViewColumnWidth(
                        min: presentation.sidebarWidth.minimum,
                        ideal: presentation.sidebarWidth.ideal,
                        max: presentation.sidebarWidth.maximum)
                    .toolbar { toolbar(for: tab) }
            } detail: {
                // Every tab keeps its split view alive; only the selected one
                // may mount the detail, or a terminal would attach twice.
                if tab == currentTab {
                    detail(in: tab)
                        .environment(
                            \.detailTopChromeInset,
                            horizontalSizeClass == .regular ? detailTopInset : 0)
                        .background {
                            if horizontalSizeClass == .regular {
                                NavigationBarTopReader { detailTopInset = $0 }
                            }
                        }
                }
            }
            // Keep structural identity stable across rotation and size-class changes.
            .navigationSplitViewStyle(.automatic)
            // The detail column swapping its content dissolves from the
            // leaving screen to the arriving one; see `DetailCrossfade`.
            .environment(\.detailCrossfade, detailCrossfade)
            .onChange(of: presentation, initial: true) { _, presentation in
                splitVisibility.update(from: presentation)
            }
        }
        // A pushed detail owns the whole iPhone screen, as it did before
        // the tab bar existed. Regular width keeps the bar to switch lists.
        .toolbarVisibility(
            horizontalSizeClass == .compact && selectedItem.wrappedValue != nil
                ? .hidden : .automatic,
            for: .tabBar)
    }

    @ViewBuilder
    private func sidebar(for tab: ConsoleTab) -> some View {
        switch tab {
        case .agents:
            content
        case .terminals:
            if hosts.hosts.isEmpty {
                noHostsView
            } else {
                TerminalListView(
                    hosts: hosts.hosts,
                    console: console,
                    presentation: terminalPresentation,
                    filteredHostID: hostFilter,
                    selection: selectedItem,
                    onOpen: { selectTerminal($0) },
                    onOpenHost: { openHostIssue($0) },
                    onNewTerminal: { isStartingTerminal = true })
            }
        case .hosts:
            // The Hosts tab shows HostListView, not a split view.
            EmptyView()
        case .search:
            searchResults
                .searchable(
                    text: $searchText, isPresented: $isSearchPresented,
                    prompt: "Agents and Terminals")
                .searchFocused($isSearchFocused)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(for tab: ConsoleTab) -> some ToolbarContent {
        // A filter is meaningless with a single Host.
        if hosts.hosts.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Menu(
                    "Filter by Host",
                    systemImage: hostFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                ) {
                    Picker("Host", selection: $hostFilter) {
                        Text("All Hosts").tag(Host.ID?.none)
                        ForEach(hosts.hosts) { host in
                            Text(host.displayName).tag(Host.ID?.some(host.id))
                        }
                    }
                }
                .hoverEffect(.highlight)
            }
        }
        if !hosts.hosts.isEmpty, tab == .agents {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Presentation", selection: presentationModeBinding) {
                        ForEach(ConsoleListPresentationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label(
                        "Presentation",
                        systemImage: listPresentation.mode == .grouped
                            ? "list.bullet.rectangle"
                            : "list.bullet")
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("Agent list presentation")
                .accessibilityValue(listPresentation.mode.title)
            }
        }
        if !hosts.hosts.isEmpty, tab == .terminals {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Terminal presentation", selection: terminalPresentationBinding) {
                        ForEach(TerminalListPresentationMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                } label: {
                    Label(
                        "Presentation",
                        systemImage: terminalPresentation.mode == .byWorkspace
                            ? "list.bullet.rectangle"
                            : "list.bullet")
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("Terminal list presentation")
                .accessibilityValue(terminalPresentation.mode.title)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Settings", systemImage: "gearshape") {
                isShowingSettings = true
            }
            .hoverEffect(.highlight)
        }
        if !hosts.hosts.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                if tab == .terminals {
                    Button("New Terminal", systemImage: "plus") {
                        isStartingTerminal = true
                    }
                    .hoverEffect(.highlight)
                } else {
                    Button("New Agent", systemImage: "plus") {
                        isStartingAgent = true
                    }
                    .hoverEffect(.highlight)
                }
            }
        }
    }

    private var terminalPresentationBinding: Binding<TerminalListPresentationMode> {
        Binding(
            get: { terminalPresentation.mode },
            set: { mode in
                withAnimation(reduceMotion ? nil : .snappy) { terminalPresentation.select(mode) }
            })
    }

    private var commandTarget: ConsoleCommandTarget {
        ConsoleCommandTarget(
            registry: commandRegistry,
            context: {
                .init(
                    selection: notificationRouter.path.last ?? selectedTerminal.map {
                        ConsoleAgent.ID(hostID: $0.hostID, paneID: $0.paneID)
                    },
                    agents: listPresentation.mode == .flat
                        ? filteredAgents.map(\.id)
                        : hostSections.filter { !$0.isCollapsed }.flatMap { $0.agents.map(\.id) },
                    isSearchFocused: isSearchFocused,
                    isCovered: isHostsTabSelected || isStartingAgent || isStartingTerminal
                        || isShowingSettings || connectionDetailRequest != nil,
                    inputMode: inputMode.mode)
            },
            navigate: { id in
                guard id != notificationRouter.path.last else { return }
                if commandRegistry.terminal?.isFocused == true
                    || commandRegistry.composer?.isFocused == true
                {
                    keyboardHandoff.arm(for: id)
                }
                notificationRouter.path = [id]
            },
            focusSearch: {
                isSearchTabSelected = true
                isSearchPresented = true
                isSearchFocused = true
            },
            newAgent: { isStartingAgent = true },
            settings: { isShowingSettings = true },
            hosts: { presentHosts() },
            closeAgent: { clearSelection() })
    }

    /// The sidebar selection as a projection of the router's path, or of the
    /// drawer terminal on stage. Setting it (a row tap, or the collapsed
    /// stack popping) writes the path back, so user navigation and deep
    /// links keep one source of truth. A drawer terminal has no row, but it
    /// must still be *a* selection: on iPhone the split view shows the
    /// detail column only while this is non-nil, so clearing it to present
    /// a terminal would pop straight back to the Agent list.
    private var selectedItem: Binding<ConsoleSelection?> {
        Binding(
            get: {
                if let id = notificationRouter.path.last { return .agent(id) }
                return selectedTerminal.map { .terminal($0.id) }
            },
            set: { selection in
                switch selection {
                case .agent(let id): selectAgent(id)
                case .terminal(let id):
                    if let terminal = console.terminals.first(where: { $0.id == id }) {
                        selectTerminal(terminal)
                    }
                case nil: clearSelection()
                }
            })
    }

    private func selectAgent(_ id: ConsoleAgent.ID) {
        changeSelection {
            selectedTerminal = nil
            notificationRouter.path = [id]
        }
    }

    private func selectTerminal(_ terminal: ConsoleTerminal) {
        if let agentID = terminal.agentID {
            selectAgent(agentID)
        } else {
            changeSelection {
                notificationRouter.path = []
                selectedTerminal = terminal
            }
        }
    }

    private func clearSelection() {
        changeSelection {
            notificationRouter.path = []
            selectedTerminal = nil
        }
    }

    /// A selection that replaces one detail screen with another dissolves
    /// between them. A first selection or a cleared one is the split view's
    /// own navigation and needs nothing from here.
    private func changeSelection(_ change: () -> Void) {
        let before = selectedItem.wrappedValue
        change()
        let after = selectedItem.wrappedValue
        guard let before, let after, before != after,
              let window = sceneWindow?.window
        else { return }
        detailCrossfade.beginSwap(in: window)
    }

    /// The split view owns the window's status-bar appearance on iPhone. A
    /// pushed terminal cannot reliably override it from the detail subtree.
    private var terminalStatusBarColorScheme: ColorScheme? {
        if selectedTerminal != nil {
            return terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme)
        }
        guard let id = notificationRouter.path.last else { return nil }
        let showsTerminalSurface = console.agents.contains(where: { $0.id == id })
        let showsTerminalSyncSurface = !showsTerminalSurface
            && MissingAgentPresentation(agentID: id, console: console, hosts: hosts)
                .renderingMode == .progress
        guard showsTerminalSurface || showsTerminalSyncSurface else { return nil }
        return terminal.themes.selection(for: colorScheme)
            .chromeColorScheme(for: colorScheme)
    }

    /// The detail column. Not keyed off the live Agent list alone: the
    /// selection must survive the list emptying while an Agent is shown
    /// (a reconnect empties it briefly), so a vanished Agent shows a
    /// placeholder instead of clearing the selection.
    @ViewBuilder
    private func detail(in tab: ConsoleTab) -> some View {
        if let id = notificationRouter.path.last {
            if let receipt = matchingRemovedWorktreeReceipt(for: id) {
                removedWorktreeSurface(receipt)
            } else if let agent = console.agents.first(where: { $0.id == id }) {
                AgentDetailView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    inputMode: inputMode,
                    hosts: hosts.hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    stage: AgentDetailStage(
                        // The router's truth, not SwiftUI's appear/disappear:
                        // only the screen still selected may rebuild its
                        // terminal on a spurious reappearance.
                        isVisible: { [notificationRouter] in
                            notificationRouter.path.last == id
                                && console.agents.contains(where: { $0.id == id })
                                && currentTab == tab
                        },
                        terminalAccess: { [sceneRouting] in
                            sceneRouting?.terminalAccess(for: id.hostID) ?? .holds
                        }),
                    onSwitch: { selectAgent($0) },
                    onClosed: { clearSelection() },
                    onSelectTerminal: { selectTerminal($0) }
                )
                // Selecting another Agent must tear down the previous terminal
                // pipeline; without the explicit identity the detail column
                // would reuse the old view's state.
                .id(id)
            } else {
                // The Agent is gone from the list, but not necessarily
                // because its pane went: a failed Host empties the list the
                // same way, and blaming the Agent for that hides the only
                // text that says what to do about it (#146).
                // The stores, not their contents: which collections this reads
                // is the part a test can then assert, and the part #146 got
                // wrong.
                let presentation = MissingAgentPresentation(
                    agentID: id, console: console, hosts: hosts)
                missingAgentSurface(presentation)
            }
        } else if let selectedTerminal {
            WorkspaceTerminalDetailView(
                terminal: console.terminals.first(where: { $0.id == selectedTerminal.id })
                    ?? selectedTerminal,
                console: console,
                settings: terminal,
                activity: activity,
                onSelectAgent: { selectAgent($0) },
                onSelectTerminal: { selectTerminal($0) },
                // The tab too: a tab switch remounts this in the next tab's
                // split view, and the leaving one must let the terminal go.
                isSelected: {
                    self.selectedTerminal?.id == selectedTerminal.id
                        && notificationRouter.path.isEmpty
                        && currentTab == tab
                },
                keyboardHandoff: keyboardHandoff,
                onBack: { clearSelection() })
                .id(selectedTerminal.id)
        } else {
            ConsoleEmptyDetailView(
                presentation: ConsoleEmptyDetailPresentation(
                    hasHosts: !hosts.hosts.isEmpty,
                    showsAgentsAction: splitVisibility.showsAgentsAction,
                    listsTerminals: tab == .terminals)
            ) { action in
                switch action {
                case .showAgents:
                    withAnimation(reduceMotion ? nil : .snappy) {
                        splitVisibility.showSidebar()
                    }
                case .newAgent:
                    if tab == .terminals { isStartingTerminal = true } else { isStartingAgent = true }
                case .hosts: presentHosts()
                }
            }
        }
    }

    /// A receipt is keyed by the Agent set captured at the authorized write.
    /// If the same pane id has already returned, require the live row to match
    /// the exact removed workspace/worktree identity before showing it.
    private func matchingRemovedWorktreeReceipt(
        for id: ConsoleAgent.ID
    ) -> WorktreeRemovalReceipt? {
        RemovedWorktreeSelection.receipt(
            for: id,
            agents: console.agents,
            receipts: console.removedWorktreesByAgent)
    }

    private func removedWorktreeSurface(
        _ receipt: WorktreeRemovalReceipt
    ) -> some View {
        ContentUnavailableView {
            Label("Worktree Removed", systemImage: "checkmark.circle")
        } description: {
            Text(
                "The checkout at \(receipt.request.identity.checkoutPath) was removed and its workspace was closed. No branch was deleted."
            )
        } actions: {
            Button("Back to Console") { notificationRouter.path = [] }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
        }
    }

    @ViewBuilder
    private func missingAgentSurface(_ presentation: MissingAgentPresentation) -> some View {
        if presentation.renderingMode == .progress {
            let theme = terminal.themes.selection(for: colorScheme)
            ZStack {
                theme.surfaceBackground(for: colorScheme)
                    .ignoresSafeArea()
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: theme.palette(for: colorScheme),
                    dimsBackground: false)
            }
        } else {
            ContentUnavailableView(
                presentation.title, systemImage: presentation.systemImage,
                description: Text(presentation.message))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch agentsSurface {
        case .noHosts:
            noHostsView
        case .noAgents:
            ContentUnavailableView {
                Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text("Agents detected on your Hosts appear here.")
            }
        case .noAgentsOnHost(let hostName):
            ContentUnavailableView {
                Label(
                    "No Agents on \(hostName)",
                    systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("Show All Hosts") { hostFilter = nil }
                    .hoverEffect(.highlight)
            }
        case .noSearchResults:
            // Search moved to its own tab; the Agents list never filters.
            EmptyView()
        case .rows:
            List(selection: selectedItem) {
                if listPresentation.mode == .flat {
                    flatAgentListRows
                } else {
                    groupedAgentListRows
                }
            }
            .listStyle(.plain)
        }
    }

    private var noHostsView: some View {
        ContentUnavailableView {
            Label("No Hosts", systemImage: "server.rack")
        } description: {
            Text("Add a machine that runs herdr to see its Agents and Terminals here.")
        } actions: {
            Button("Add Host") { presentHosts() }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
        }
    }

    /// The Search tab: Agents and ordinary shells matching one query, each
    /// under its own heading, with the Host filter still applied.
    @ViewBuilder
    private var searchResults: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if hosts.hosts.isEmpty {
            noHostsView
        } else if query.isEmpty {
            ContentUnavailableView(
                "Search Agents and Terminals", systemImage: "magnifyingglass",
                description: Text("Titles, Workspaces, tabs, and directories on your Hosts."))
        } else {
            let agents = filteredAgents.filter { $0.matchesAgentSearch(query) }
            let terminalCards = TerminalListProjection(hosts: hosts.hosts, console: console)
                .workspaces(filteredHostID: hostFilter, searchQuery: query)
            let terminals = terminalCards.flatMap(\.terminals)
            // Search drops non-matching shells, so a Tab is named whenever its
            // Workspace keeps several matches.
            let sharedWorkspaces = Set(terminalCards.filter { $0.terminals.count > 1 }.map(\.id))
            if agents.isEmpty && terminals.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: selectedItem) {
                    if !agents.isEmpty {
                        Section {
                            ForEach(agents) { agentRow($0) }
                        } header: {
                            searchResultsHeader("Agents")
                        }
                    }
                    if !terminals.isEmpty {
                        Section {
                            ForEach(terminals) { terminal in
                                NavigationLink(value: ConsoleSelection.terminal(terminal.id)) {
                                    TerminalRowView(
                                        terminal: terminal, showsWorkspace: true,
                                        showsTab: sharedWorkspaces.contains(
                                            TerminalWorkspaceGroup.ID(
                                                hostID: terminal.hostID,
                                                workspaceID: terminal.workspaceID)))
                                }
                                .hoverEffect(.highlight)
                            }
                        } header: {
                            searchResultsHeader("Terminals")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func searchResultsHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }

    @ViewBuilder
    private var flatAgentListRows: some View {
        ForEach(visibleHostIssues) { issue in
            ConsoleHostIssueRow(issue: issue) { openHostIssue($0) }
        }
        ForEach(filteredAgents) { agent in
            agentRow(agent)
        }
    }

    @ViewBuilder
    private var groupedAgentListRows: some View {
        ForEach(hostSections) { section in
            let opensDetail = connectionDetail(for: section.hostID) != nil
            Section {
                if !section.isCollapsed && !opensDetail {
                    // As in the Terminals tab: an expanded Host with a
                    // condition says what it is before any Agents it lists.
                    if let issue = section.statusPresentation {
                        ConsoleHostIssueRow(issue: issue) { openHostIssue($0) }
                    }
                    ForEach(section.agents) { agent in
                        agentRow(agent)
                    }
                }
            } header: {
                ConsoleHostSectionHeaderView(
                    presentation: ConsoleHostSectionHeaderPresentation(
                        section: section, opensConnectionDetail: opensDetail)
                ) {
                    if opensDetail {
                        openHostIssue(section.hostID)
                    } else {
                        toggleHostSection(section.hostID)
                    }
                }
                .textCase(nil)
            }
        }
    }

    private func agentRow(_ agent: ConsoleAgent) -> some View {
        NavigationLink(value: ConsoleSelection.agent(agent.id)) {
            AgentCardView(
                agent: agent,
                layout: console.rowLayout(for: agent.hostID),
                isPinned: console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID))
        }
        .hoverEffect(.highlight)
        .contextMenu {
            let pinned = console.pins.isPinned(
                hostID: agent.hostID, paneID: agent.agent.paneID)
            Button(
                pinned ? "Unpin" : "Pin",
                systemImage: pinned ? "pin.slash" : "pin"
            ) {
                console.togglePin(
                    hostID: agent.hostID, paneID: agent.agent.paneID)
            }
            // Never on iPhone, and not for the Agent this window already shows.
            if supportsMultipleWindows, notificationRouter.path.last != agent.id {
                Button("Open in New Window", systemImage: "plus.rectangle.on.rectangle") {
                    openInNewWindow(agent)
                }
            }
        }
        .modifier(
            AgentWindowDrag(
                route: AgentRoute(agentID: agent.id),
                title: agent.agent.displayName,
                isEnabled: supportsMultipleWindows))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let pinned = console.pins.isPinned(
                hostID: agent.hostID, paneID: agent.agent.paneID)
            Button {
                togglePinAfterSwipe(agent)
            } label: {
                Label(
                    pinned ? "Unpin" : "Pin",
                    systemImage: pinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        // A full swipe makes closing one gesture away, so every close asks
        // first. No `.destructive` role: List would animate the row out
        // while the confirmation is still up, even if the user cancels.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                pendingTabClose = agent
            } label: {
                Label("Close", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Pinning moves the row. Reordering while the swipe is still closing
    /// tears the action button away from its row, and for a while after the
    /// collapse the swiped cell still cannot move: List removes and
    /// reinserts it instead, so it vanishes and pops in at the new slot.
    /// Measured on iOS 27 that settles after ~0.8 s; the wait keeps margin.
    private func togglePinAfterSwipe(_ agent: ConsoleAgent) {
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            withAnimation(reduceMotion ? nil : .snappy) {
                console.togglePin(hostID: agent.hostID, paneID: agent.agent.paneID)
            }
        }
    }

    private func closeTabNow(_ agent: ConsoleAgent) {
        Task {
            do {
                try await console.closeAgent(agent)
            } catch {
                tabCloseError = ConsoleStore.tabCloseFailureMessage(for: error)
            }
        }
    }

    /// Whether the close confirmation is up for whichever Agent the swipe
    /// action queued.
    private var tabCloseDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingTabClose != nil },
            set: { shown in if !shown { pendingTabClose = nil } })
    }

    private var tabCloseErrorPresented: Binding<Bool> {
        Binding(
            get: { tabCloseError != nil },
            set: { shown in if !shown { tabCloseError = nil } })
    }

    private func confirmTabClose() {
        guard let agent = pendingTabClose else { return }
        pendingTabClose = nil
        closeTabNow(agent)
    }

    /// What the pending close takes down, widest first.
    private var pendingCloseScope: String {
        guard let agent = pendingTabClose else { return "Tab" }
        if console.closesWorkspaceWithTab(of: agent) { return "Workspace" }
        return console.closesTab(of: agent) ? "Tab" : "Pane"
    }

    private var tabCloseDialogTitle: String { "Close \(pendingCloseScope)?" }

    private var tabCloseConfirmLabel: String { "Close \(pendingCloseScope)" }

    /// Confirmation copy naming the Agent, and the workspace when it dies
    /// with the tab.
    private func tabCloseMessage(for agent: ConsoleAgent) -> String {
        let name = agent.agent.displayName
        if console.closesWorkspaceWithTab(of: agent) {
            let workspace = agent.workspaceLabel ?? "this workspace"
            return "Are you sure you want to also close workspace \(workspace)? It is the workspace's last tab."
        }
        if console.closesTab(of: agent) {
            return "Closes the tab running \(name)."
        }
        return "Closes the pane running \(name). The tab's other panes stay open."
    }

    /// A window already showing this Agent comes forward instead of a second
    /// one opening: two windows on one Agent would contend for its Host's
    /// single terminal channel.
    private func openInNewWindow(_ agent: ConsoleAgent) {
        if sceneRouting?.directory.activateScene(presenting: agent.id) == true { return }
        openWindow(value: AgentRoute(agentID: agent.id))
    }

    /// Deep links raised inside this window obey the same single-window rule
    /// as a notification tap.
    private func openNotificationTarget(_ target: AgentNotificationTarget?) {
        if let sceneRouting {
            sceneRouting.open(target)
        } else {
            notificationRouter.open(target)
        }
    }

    private var agentsSurface: ConsoleAgentsSurface {
        ConsoleAgentsSurface(
            hostCount: hosts.hosts.count,
            filteredHostName: hostFilter == nil ? nil : filteredHostName,
            filteredAgentCount: filteredAgents.count,
            visibleIssueCount: visibleHostIssues.count,
            presentationMode: listPresentation.mode,
            projectedSectionCount: hostSections.count,
            searchQuery: "")
    }

    private var hostSections: [ConsoleHostSection] {
        listPresentation.sections(
            hosts: hosts.hosts,
            console: console,
            filteredHostID: hostFilter)
    }

    private var presentationModeBinding: Binding<ConsoleListPresentationMode> {
        Binding(
            get: { listPresentation.mode },
            set: { listPresentation.select($0) })
    }

    private func toggleHostSection(_ hostID: Host.ID) {
        if reduceMotion {
            listPresentation.toggleCollapsed(hostID)
        } else {
            withAnimation(.snappy) {
                listPresentation.toggleCollapsed(hostID)
            }
        }
    }

    private var filteredAgents: [ConsoleAgent] {
        let hostFiltered: [ConsoleAgent]
        if let hostFilter {
            hostFiltered = console.agents.filter { $0.hostID == hostFilter }
        } else {
            hostFiltered = console.agents
        }
        return hostFiltered
    }

    /// Host issues shown in the list: all of them, or the filtered Host's
    /// only — a filtered Console should not nag about other machines.
    private var visibleHostIssues: [ConsoleHostStatusPresentation] {
        guard let hostFilter else { return hostIssues }
        return hostIssues.filter { $0.hostID == hostFilter }
    }

    private var filteredHostName: String {
        hosts.hosts.first(where: { $0.id == hostFilter })?.displayName ?? "this Host"
    }

    private struct HostsTabRequest {
        let id = UUID()
        let hostID: Host.ID
        /// The tab the Host was opened from; its back button returns there.
        /// Nil when opened from the Hosts tab itself.
        let origin: ConsoleTab?
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC.
    private var hostIssues: [ConsoleHostStatusPresentation] {
        hosts.hosts.compactMap { host in
            ConsoleHostStatusPresentation(
                host: host,
                status: console.hostStatuses[host.id],
                standingFailure: console.hostStandingFailures[host.id],
                isAwaitingSnapshot: console.hostsAwaitingSnapshot.contains(host.id),
                syncError: console.hostSyncErrors[host.id])
        }
    }

    private struct ConnectionDetailRequest: Identifiable {
        let id: Host.ID
        /// The failure shown when the sheet's Retry Now was tapped.
        var lastFailure: TransportError?
    }

    private func connectionDetail(for id: Host.ID) -> HostConnectionDetailPresentation? {
        connectionDetail(for: ConnectionDetailRequest(id: id))
    }

    private func connectionDetail(
        for request: ConnectionDetailRequest
    ) -> HostConnectionDetailPresentation? {
        guard let host = hosts.hosts.first(where: { $0.id == request.id }) else { return nil }
        return HostConnectionDetailPresentation(
            host: host,
            status: console.hostStatuses[request.id],
            standingFailure: console.hostStandingFailures[request.id],
            lastFailure: request.lastFailure)
    }

    /// A Host that cannot connect explains itself in a sheet; any other Host
    /// condition opens the Host in the Hosts tab.
    private func openHostIssue(_ id: Host.ID) {
        if connectionDetail(for: id) != nil {
            connectionDetailRequest = ConnectionDetailRequest(id: id)
        } else {
            presentHosts(id)
        }
    }

    /// Switches to the Hosts tab, on one Host's detail when `id` is given.
    private func presentHosts(_ id: Host.ID? = nil) {
        if let id {
            hostsTabRequest = HostsTabRequest(
                hostID: id, origin: currentTab == .hosts ? nil : currentTab)
        }
        isSearchTabSelected = false
        isHostsTabSelected = true
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

private struct ConsoleStatusBarModifier: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarColorScheme(scheme, for: .statusBar)
        } else {
            content
                .toolbarColorScheme(scheme, for: .navigationBar)
        }
        #else
        content
            .toolbarColorScheme(scheme, for: .navigationBar)
        #endif
    }
}

/// What the detail column shows when the selected Agent is no longer in the
/// Console list. Six conditions empty that list and they need six answers
/// (#141, #146, #154, #155).
///
/// Read Host Connection Status first, then Standing Failure, then the Agent
/// Inventory. A Standing Failure changes only what `.connecting` looks like.
/// The inventory is consulted only under `.connected`.
struct MissingAgentPresentation: Equatable {
    /// Which situation emptied the list. Explicit so that collapsing them
    /// into a single message cannot happen by accident.
    enum Cause: Hashable {
        case hostSuspended
        case hostConnecting
        case hostReconnecting
        /// A stopped Host, or a `.connecting` Host that still carries a
        /// Standing Failure.
        case hostFailed
        /// The Host is Connected, but its first snapshot for this connection
        /// has not landed yet.
        case hostLoadingAgents
        case paneGone
    }

    enum RenderingMode: Equatable {
        case progress
        case staticUnavailable
    }

    let cause: Cause
    let title: String
    let systemImage: String
    let message: String

    var renderingMode: RenderingMode {
        switch cause {
        case .hostConnecting, .hostReconnecting, .hostLoadingAgents:
            .progress
        case .hostSuspended, .hostFailed, .paneGone:
            .staticUnavailable
        }
    }

    /// Resolves the Host from the selection rather than taking a status the
    /// caller looked up: the pane address alone is not unique across Hosts,
    /// so `ConsoleAgent.ID` carries the `hostID`, and keeping the resolution
    /// here means no call site can apply a *different* rule to it.
    ///
    /// This initializer takes the *contents* and so cannot police where they
    /// came from — passing an empty `hostStatuses` restores #146's defect
    /// outright, since every failed Host then falls back to the placeholder.
    /// The detail column therefore does not call it; it calls the store-taking
    /// initializer below, which is the one under test (#152).
    init(
        agentID: ConsoleAgent.ID,
        hostStatuses: [Host.ID: EventsSessionStatus],
        hosts: [Host],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostStandingFailures: [Host.ID: TransportError] = [:]
    ) {
        let hostName = hosts.first { $0.id == agentID.hostID }?.displayName
        func named(_ text: String) -> String {
            hostName.map { "\($0): \(text)" } ?? text
        }
        func applyFailed(_ failure: TransportError) -> (
            Cause, String, String, String
        ) {
            (
                .hostFailed,
                "Host Unavailable",
                failure.isHostKeySecurityFailure
                    ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
                named(failure.presentation.message)
            )
        }
        let hostStatus = hostStatuses[agentID.hostID]
        let standingFailure = hostStandingFailures[agentID.hostID]
        switch hostStatus {
        case .suspended:
            cause = .hostSuspended
            title = "Connection Paused"
            systemImage = "pause.circle"
            message = named("The connection is paused until Heeler becomes active.")
        case .connecting:
            if let standingFailure {
                (cause, title, systemImage, message) = applyFailed(standingFailure)
            } else {
                cause = .hostConnecting
                title = "Connecting…"
                systemImage = "dot.radiowaves.left.and.right"
                message = named("Opening the connection.")
            }
        case .reconnecting(_, _, let failure):
            cause = .hostReconnecting
            title = "Reconnecting…"
            systemImage = "arrow.trianglehead.2.clockwise"
            message = named(failure.presentation.summary)
        case .failed(let failure):
            (cause, title, systemImage, message) = applyFailed(failure)
        case .connected:
            if hostsAwaitingSnapshot.contains(agentID.hostID) {
                cause = .hostLoadingAgents
                title = "Loading Agents…"
                systemImage = "hourglass"
                message = named("Fetching the latest Agents.")
            } else {
                cause = .paneGone
                title = "Agent Gone"
                systemImage = "rectangle.on.rectangle.slash"
                message = "This Agent's pane is no longer reported."
            }
        case .ended, nil:
            cause = .paneGone
            title = "Agent Gone"
            systemImage = "rectangle.on.rectangle.slash"
            message = "This Agent's pane is no longer reported."
        }
    }

    /// What the Console's detail column shows when the selected Agent is not
    /// in the list.
    ///
    /// This exists to be called from a test, and deleting it would cost real
    /// coverage rather than tidy up an unused overload. The defect it guards
    /// (#146) is *which collections the view reads*, not what the rule does
    /// with them, and that could not be reached: a hosted `NavigationSplitView`
    /// builds its columns and navigation bar but never the SwiftUI content
    /// inside them, so the detail column cannot be rendered in a test and
    /// asserted against (measured under #152).
    ///
    /// Taking the stores instead of their contents is what makes the seam
    /// worth having. The reader is now written once, here, where a test calls
    /// exactly what the view calls — rather than at a call site that no test
    /// can reach.
    @MainActor
    init(agentID: ConsoleAgent.ID, console: ConsoleStore, hosts: HostStore) {
        self.init(
            agentID: agentID,
            hostStatuses: console.hostStatuses,
            hosts: hosts.hosts,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostStandingFailures: console.hostStandingFailures)
    }
}

/// Collapsible Host-section header for the grouped Console list (#245).
private struct ConsoleHostSectionHeaderView: View {
    let presentation: ConsoleHostSectionHeaderPresentation
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                HostStatusGlyph(tone: presentation.readiness.tone)
                Text(presentation.hostDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.readiness.nameEmphasis.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if presentation.showsStatusPills {
                    ConsoleHostStatusCountPills(items: presentation.statusItems)
                        .accessibilityHidden(true)
                }
                Image(systemName: presentation.disclosureSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The two ways a selected Agent detail can be on stage. A window whose Host
/// channel is live in another window still shows its detail, so that detail's
/// presentations keep covering the window's keyboard commands, while its
/// Attach stays off stage until the window holds the channel again.
struct AgentDetailStage {
    /// The detail is the window's selected, still-listed Agent.
    let isVisible: () -> Bool
    let terminalAccess: () -> HostTerminalAccess

    /// Attach start, resize and rejoin: visible and holding the Host's channel.
    func isOnStage() -> Bool {
        isVisible() && terminalAccess() == .holds
    }
}

/// Mirrors the Live Activity count chips so a collapsed Host communicates
/// the same status distribution at a glance.
private struct ConsoleHostStatusCountPills: View {
    let items: [ConsoleHostAgentStatusCount]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items) { item in
                Text("\(item.count) \(item.status.rawValue)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(item.status.inkUIColor))
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(item.status.tintUIColor).opacity(0.15),
                        in: Capsule())
            }
        }
    }
}

/// What the Console sidebar's split-view selection can hold. Only Agents
/// have rows; a terminal chosen from Agent detail's Workspace drawer takes
/// the `terminal` case so the detail column stays presented on iPhone
/// (see `ConsoleView.selectedItem`).
enum ConsoleSelection: Hashable {
    case agent(ConsoleAgent.ID)
    case terminal(ConsoleTerminal.ID)
}

extension EnvironmentValues {
    /// How far a full-bleed detail screen must start below the window's top
    /// edge to clear the Console's floating tab bar. Zero where the tab bar
    /// sits at the bottom; the screens still clear the status bar themselves.
    @Entry var detailTopChromeInset: CGFloat = 0
}

/// Reports where the enclosing navigation bar starts, in window coordinates.
/// The Console's regular-width tab bar floats above the detail column's bar,
/// and SwiftUI exposes neither frame.
private struct NavigationBarTopReader: UIViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: UIView {
        var onChange: @MainActor (CGFloat) -> Void
        private var reported: CGFloat?

        init(onChange: @escaping @MainActor (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        /// Deferred: this runs inside layout, where SwiftUI state must not
        /// change.
        func report() {
            guard let window, let bar = enclosingNavigationBar() else { return }
            let top = bar.convert(bar.bounds, to: window).minY
            guard top != reported else { return }
            reported = top
            let onChange = onChange
            Task { @MainActor in onChange(top) }
        }

        private func enclosingNavigationBar() -> UINavigationBar? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                    let navigation = controller.navigationController
                {
                    return navigation.navigationBar
                }
                responder = current.next
            }
            return nil
        }
    }
}
