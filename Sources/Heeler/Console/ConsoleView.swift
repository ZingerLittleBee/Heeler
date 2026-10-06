import SwiftUI

/// The Console home screen (#8): a bottom tab bar over Agents across every
/// Host (flat or grouped by Host, #245), their ordinary shell Terminals
/// grouped by Workspace or Host (#316), and one Search across both. Host
/// management (#14) and Settings are tabs too. An iPad beside its sidebar
/// has no tab bar: the sidebar switches lists at its top and opens Hosts
/// and Settings as sheets from its bottom. Every tab is its own
/// split view, but they share one selection and only the selected tab
/// mounts the detail column, so a terminal is never attached twice. In
/// regular width a list tab swaps its own last selection back in when it
/// returns.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let inputMode: AgentInputModeSettings
    let detailSurface: AgentDetailSurfaceSettings
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
    /// Hosts and Settings are tracked apart so neither is the tab a window
    /// comes back to.
    @SceneStorage("console.list-tab") private var sceneListTab = ""
    /// The last list tab any window picked: where a new window, or a
    /// relaunch that restored no scene state, starts.
    @AppStorage("console.last-list-tab") private var lastListTab: ConsoleTab = .agents
    /// The list tab this window shows, once it has picked one here. The
    /// tab bar reads it back within the tap that set it, and the two
    /// storages above can still answer with the old tab then: the bar
    /// reverted to it and then jumped forward again.
    @State private var listTab: ConsoleTab?
    @State private var isHostsTabSelected = false
    @State private var isSettingsTabSelected = false
    /// Hosts and Settings where the sidebar navigates instead of a tab bar.
    @State private var isShowingHostsSheet = false
    @State private var isShowingSettingsSheet = false
    @State private var isShowingListMenu = false
    /// Where the sidebar's title sits in the window, for its choices to
    /// point at.
    @State private var listMenuTitleFrame: CGRect?
    @State private var isStartingTerminal = false
    @State private var terminalPresentation = TerminalListPresentationStore()
    /// Where the detail column's navigation bar sits, from the column's top
    /// edge. In regular width it starts just below the status bar; see
    /// `detailTopChromeInset`.
    @State private var detailBar = NavigationBarBand()
    /// The Agent whose detail shows Changes in place of its terminal; the
    /// window's chrome then follows the app, not the terminal theme.
    @State private var agentShowingChanges: ConsoleAgent.ID?
    /// The Agent whose detail shows Chat in place of its terminal, for the
    /// same reason.
    @State private var agentShowingChat: ConsoleAgent.ID?
    /// Each list tab's last selection. In regular width both lists sit
    /// beside their own detail, so a list tab comes back to what it showed
    /// rather than to the other list's pick.
    @State private var rememberedSelections: [ConsoleTab: ParkedSelection] = [:]
    /// A request to open Hosts, as a tab or a sheet, on one Host's detail.
    /// Each request rebuilds the list so it lands there even when that Host
    /// is already on its stack.
    @State private var hostsTabRequest: HostsTabRequest?
    /// Bumped to rebuild the Hosts or Settings tab, taking down a sheet it
    /// presented when a deep link carries the window off to an Agent.
    @State private var hostsTabGeneration = 0
    @State private var settingsTabGeneration = 0
    @State private var isStartingAgent = false
    @State private var connectionDetailRequest: ConnectionDetailRequest?
    /// The flat lists' summary opened: every Host problem in one sheet.
    @State private var isShowingHostIssues = false
    /// Per Host, the failure its pushed detail showed at Retry Now.
    @State private var hostIssuesLastFailures: [Host.ID: TransportError] = [:]
    /// Hosts whose Host-detail Reconnect request is in flight, including the
    /// 1.2 s visual-feedback hold after `retryHost` returns. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    /// Narrows the Agent list to one Host; nil shows every Host. This is a
    /// filter in both presentations, not a second grouping mechanism.
    @State private var hostFilter: Host.ID?
    /// Each list's own search (#292, #316), after `hostFilter`. The field
    /// hides under the title until the list is pulled down.
    @State private var agentSearchText = ""
    @State private var terminalSearchText = ""
    @State private var isAgentSearchPresented = false
    @State private var isTerminalSearchPresented = false
    /// The list whose search field has focus.
    @FocusState private var focusedSearch: ConsoleTab?
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
    /// Per list tab: hiding one list's sidebar leaves the other's alone, and
    /// a split view coming back on screen cannot overwrite a hide made in
    /// the other tab with its own stale state.
    @State private var splitVisibilities: [ConsoleTab: ConsoleSplitVisibilityState] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sceneWindow) private var sceneWindow
    @State private var detailCrossfade = DetailCrossfade()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The window-aware entry into navigation; nil outside a scene root.
    @Environment(\.agentSceneRouting) private var sceneRouting

    var body: some View {
        TabView(selection: tabViewSelection) {
            Tab(ConsoleTab.agents.title, systemImage: "sparkles", value: ConsoleTab.agents) {
                splitView(for: usesSidebarNavigation ? shownListTab : .agents)
            }
            Tab(value: ConsoleTab.terminals) {
                // Beside an iPad's sidebar the Terminals list shows in the
                // Agents tab's split view; see `tabViewSelection`.
                if !usesSidebarNavigation { splitView(for: .terminals) }
            } label: {
                // The tab bar fills symbols; filled, this one is a solid
                // block beside the other tabs' line icons.
                Label(ConsoleTab.terminals.title, systemImage: "terminal")
                    .environment(\.symbolVariants, .none)
            }
            Tab(ConsoleTab.hosts.title, systemImage: "server.rack", value: ConsoleTab.hosts) {
                hostList(
                    origin: hostsTabRequest?.origin.map { origin in
                        HostListOrigin(title: origin.title) { selectedTab.wrappedValue = origin }
                    })
                .id(hostsTabGeneration)
            }
            Tab(value: ConsoleTab.settings) {
                settingsView()
                    .id(settingsTabGeneration)
            } label: {
                // Outlined, as Terminals is: filled, the gear is the heaviest
                // icon in the bar.
                Label(ConsoleTab.settings.title, systemImage: "gearshape")
                    .environment(\.symbolVariants, .none)
            }
        }
        // `lastListTab` is every window's; this window keeps the list tab it
        // opened on even when another window picks a different one.
        .onAppear {
            if listTab == nil { listTab = shownListTab }
        }
        // The detail's actions can present these even while the sidebar is hidden.
        .sheet(isPresented: $isStartingAgent) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                // StartAgentView brings its own NavigationStack.
                StartAgentView(hosts: hosts.hosts, console: console) { id in
                    // A fresh launch lands in its own terminal, exactly
                    // as tapping the new row would, on the list that has it.
                    if currentTab != .agents { selectedTab.wrappedValue = .agents }
                    notificationRouter.path = [id]
                    detailDidOpenFromSidebar()
                }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: presentation, fitsContent: true))
            }
        }
        // An Agent row's swipe or context menu asks here before closing.
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
            ConsoleSheetContent(sheetPresentation) { presentation in
                // NewTerminalView brings its own NavigationStack.
                NewTerminalView(
                    hosts: hosts.hosts, console: console, initialHostID: hostFilter
                ) {
                    // A new shell lands in its terminal, as tapping its row would.
                    selectTerminal($0)
                    detailDidOpenFromSidebar()
                }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: presentation, fitsContent: true))
            }
        }
        .sheet(item: $connectionDetailRequest) { request in
            ConsoleSheetContent(sheetPresentation) { presentation in
                if let host = hosts.hosts.first(where: { $0.id == request.id }),
                    let detail = connectionDetail(for: request)
                {
                    HostConnectionDetailView(
                        presentation: detail,
                        host: host,
                        catalog: hosts,
                        sheetPresentation: presentation,
                        isRetryInFlight: manualReconnectInFlightHostIDs.contains(host.id)
                    ) {
                        // Holds the sheet open through the retry's dial, which a
                        // reconnecting Host makes without a standing failure.
                        connectionDetailRequest?.lastFailure = detail.failure
                        Task { await reconnectHost(host.id) }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingHostIssues) {
            ConsoleSheetContent(sheetPresentation) { hostIssuesSheet(presentation: $0) }
        }
        .sheet(isPresented: $isShowingHostsSheet, onDismiss: { hostsTabRequest = nil }) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                hostList(onDone: { isShowingHostsSheet = false })
                    .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                settingsView(onDone: { isShowingSettingsSheet = false })
                    .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
        // Retries answered, the Host no longer failing, drop what they saw.
        .onChange(of: hostIssuesSheetExplained) { _, explained in
            hostIssuesLastFailures = hostIssuesLastFailures.filter { explained.contains($0.key) }
        }
        .onChange(of: filteredHostIssues.isEmpty) { _, isEmpty in
            if isEmpty { isShowingHostIssues = false }
        }
        // Once the Host connects again (or leaves the catalog) the sheet has
        // nothing left to explain.
        .onChange(of: connectionDetailRequest.flatMap { connectionDetail(for: $0) }) {
            _, detail in
            if detail == nil { connectionDetailRequest = nil }
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
        .onChange(of: notificationRouter.path) { old, path in
            guard !path.isEmpty else { return }
            bringAgentForward(
                parking: old.last.map { .agent($0) } ?? selectedTerminal.map { .terminal($0) })
        }
        // A deep link to the Agent already on the path leaves it unchanged,
        // and must still come forward from Hosts, Settings or a sheet.
        .onChange(of: notificationRouter.repeatLandings) {
            bringAgentForward(parking: parkedSelection)
        }
        // A Host opened on request belongs to that one visit: once the user
        // leaves the Hosts tab, it reopens on its list.
        .onChange(of: isHostsTabSelected) { _, isSelected in
            if !isSelected, !isShowingHostsSheet { hostsTabRequest = nil }
        }
        // A window widening past the tab bar carries Hosts or Settings over
        // into their sheet, over the list tab beneath them.
        .onChange(of: usesSidebarNavigation) { _, usesSidebar in
            guard usesSidebar else { return }
            if isHostsTabSelected {
                hostsTabRequest = hostsTabRequest.map {
                    HostsTabRequest(hostID: $0.hostID, origin: nil)
                }
                isShowingHostsSheet = true
                isHostsTabSelected = false
            }
            if isSettingsTabSelected {
                isShowingSettingsSheet = true
                isSettingsTabSelected = false
            }
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
                if isHostsTabSelected { return .hosts }
                if isSettingsTabSelected { return .settings }
                return shownListTab
            },
            set: { tab in
                let leavingList = shownListTab
                // A search field keeping first responder through the switch
                // can leave the arriving tab blank; its query stays.
                if tab != currentTab { focusedSearch = nil }
                isHostsTabSelected = tab == .hosts
                isSettingsTabSelected = tab == .settings
                guard tab.isList else { return }
                if tab != leavingList, horizontalSizeClass == .regular {
                    swapListSelection(from: leavingList, to: tab)
                }
                pinListTab(tab)
            })
    }

    private var currentTab: ConsoleTab { selectedTab.wrappedValue }

    /// The TabView's own selection. Beside an iPad's sidebar both lists
    /// share the Agents tab's split view, so switching lists keeps one
    /// sidebar and its bar rather than swapping in another tab's.
    private var tabViewSelection: Binding<ConsoleTab> {
        Binding(
            get: {
                let tab = currentTab
                return usesSidebarNavigation && tab.isList ? .agents : tab
            },
            set: { tab in
                guard !(usesSidebarNavigation && tab.isList) else { return }
                selectedTab.wrappedValue = tab
            })
    }

    /// An iPad beside its sidebar navigates from the sidebar instead of a
    /// tab bar. An iPhone, and an iPad window too narrow for a sidebar, keep
    /// the tab bar.
    private var usesSidebarNavigation: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Hosts, as a tab or a sheet. HostListView brings its own
    /// NavigationStack.
    private func hostList(
        origin: HostListOrigin? = nil, onDone: (@MainActor () -> Void)? = nil
    ) -> some View {
        HostListView(
            store: hosts,
            initialHostID: hostsTabRequest?.hostID,
            connectionStatuses: console.hostStatuses,
            standingFailures: console.hostStandingFailures,
            latencies: console.hostLatencies,
            syncIssues: console.hostSyncErrors,
            manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
            retryConnection: { await reconnectHost($0) },
            origin: origin,
            onDone: onDone)
        .id(hostsTabRequest?.id)
    }

    /// Settings, as a tab or a sheet. SettingsView brings its own
    /// NavigationStack.
    private func settingsView(onDone: (@MainActor () -> Void)? = nil) -> some View {
        SettingsView(
            terminal: terminal,
            appearance: appearance,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            liveActivities: liveActivities,
            console: console,
            hosts: hosts.hosts,
            onDone: onDone)
    }

    private func switchList(to tab: ConsoleTab) {
        guard tab != currentTab else { return }
        let leaving = splitVisibility(for: currentTab)
        selectedTab.wrappedValue = tab
        splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
            .keepSidebar(from: leaving)
    }

    private func showHosts() {
        if usesSidebarNavigation {
            isShowingHostsSheet = true
        } else {
            selectedTab.wrappedValue = .hosts
        }
    }

    private func showSettings() {
        if usesSidebarNavigation {
            isShowingSettingsSheet = true
        } else {
            selectedTab.wrappedValue = .settings
        }
    }

    /// The list tab on screen, or under Hosts or Settings.
    private var shownListTab: ConsoleTab {
        listTab ?? ConsoleTab(rawValue: sceneListTab) ?? lastListTab
    }

    private func pinListTab(_ tab: ConsoleTab) {
        listTab = tab
        sceneListTab = tab.rawValue
        lastListTab = tab
    }

    /// An Agent shows on the Agents list, whatever brought it on stage: the
    /// Terminals list has no row for it. The list it replaces keeps what it
    /// showed, as a tab switch would park it.
    private func showAgentsList(parking parked: ParkedSelection?) {
        let shown = shownListTab
        guard shown != .agents else { return }
        if horizontalSizeClass == .regular { rememberedSelections[shown] = parked }
        pinListTab(.agents)
    }

    /// Lands the path's Agent on Agent detail, even when one of the
    /// Console's sheets covers it. The only other push a sheet can cause is
    /// the new-agent flow's, which dismisses itself first, so clearing here
    /// is a no-op for it.
    private func bringAgentForward(parking parked: ParkedSelection?) {
        // Hosts and Settings tabs present their own sheets, which cover the
        // tab bar: one up now is theirs. Rebuilding the tab takes it down,
        // as closing them does where they are sheets.
        let ownsPresentation = isStartingAgent || isStartingTerminal
            || connectionDetailRequest != nil || isShowingHostIssues
            || isShowingHostsSheet || isShowingSettingsSheet
        if isPresentingOverConsole, !ownsPresentation {
            if isHostsTabSelected { hostsTabGeneration += 1 }
            if isSettingsTabSelected { settingsTabGeneration += 1 }
        }
        showAgentsList(parking: parked)
        selectedTerminal = nil
        // Hosts and Settings have no detail column; the Agent shows on its
        // list tab.
        isHostsTabSelected = false
        isSettingsTabSelected = false
        isStartingAgent = false
        isStartingTerminal = false
        connectionDetailRequest = nil
        isShowingHostIssues = false
        isShowingHostsSheet = false
        isShowingSettingsSheet = false
    }

    /// What the detail shows, as a list tab parks it.
    private var parkedSelection: ParkedSelection? {
        if let id = notificationRouter.path.last { return .agent(id) }
        return selectedTerminal.map { .terminal($0) }
    }

    /// Parks the leaving list's selection and puts back the arriving one's,
    /// if what it showed may still be there. No crossfade: behind a tab bar
    /// the detail column belongs to the other tab's split view.
    private func swapListSelection(from leaving: ConsoleTab, to arriving: ConsoleTab) {
        rememberedSelections[leaving] = parkedSelection
        switch rememberedSelections[arriving] {
        case .agent(let id)
        where console.agents.contains(where: { $0.id == id }) || isUnreported(id):
            selectedTerminal = nil
            notificationRouter.path = [id]
        case .terminal(let parked) where isRestorable(parked):
            notificationRouter.path = []
            selectedTerminal = console.terminals.first(where: { $0.id == parked.id }) ?? parked
        default:
            notificationRouter.path = []
            selectedTerminal = nil
        }
    }

    /// A shell that has since started an Agent shows on the Agents list
    /// instead, so the Terminals list does not come back to it.
    private func isRestorable(_ parked: ConsoleTerminal) -> Bool {
        if let live = console.terminals.first(where: { $0.id == parked.id }) {
            return !live.isAgent
        }
        return isUnreported(ConsoleAgent.ID(hostID: parked.hostID, paneID: parked.paneID))
    }

    /// A pane missing from the lists only because its Host has not reported
    /// since (paused, reconnecting, failed, loading) rather than because it
    /// went. The detail keeps such a selection through a reconnect; a tab
    /// switch in the meantime must too.
    private func isUnreported(_ id: ConsoleAgent.ID) -> Bool {
        MissingAgentPresentation(agentID: id, console: console, hosts: hosts).cause != .paneGone
    }

    private func splitVisibility(for tab: ConsoleTab) -> ConsoleSplitVisibilityState {
        splitVisibilities[tab] ?? ConsoleSplitVisibilityState()
    }

    /// The split view's own reports land in its tab's state only.
    private func splitVisibilityBinding(
        for tab: ConsoleTab, presentation: ConsoleSplitPresentation
    ) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { splitVisibility(for: tab).visibility },
            set: {
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .systemDidChangeVisibility($0, presentation: presentation)
            })
    }

    /// A wide iPhone's tab bar follows the terminal on stage, as the status
    /// bar does; in compact width the terminal is pushed clear of it.
    private var tabBarChromeScheme: ColorScheme? {
        horizontalSizeClass == .regular ? terminalStatusBarColorScheme : nil
    }

    /// A pushed detail owns the whole iPhone screen, as it did before the
    /// tab bar existed. A wide iPhone keeps the bar to switch lists; an
    /// iPad's sidebar switches them itself.
    private var hidesTabBar: Bool {
        usesSidebarNavigation
            || (horizontalSizeClass == .compact && selectedItem.wrappedValue != nil)
    }

    /// Beside an opaque sidebar, the detail's leading safe area lies under
    /// it, and its material would take on a terminal's color there. A glass
    /// sidebar floats over the terminal instead, which fills the window.
    private func detailSurfaceEdges(for tab: ConsoleTab) -> Edge.Set {
        !sidebarFloatsOverDetail && horizontalSizeClass == .regular
            && splitVisibility(for: tab).isSidebarVisible != false
            ? [.vertical, .trailing] : .all
    }

    /// iPadOS 26 draws the sidebar as glass over the detail column, so what
    /// lies behind it is the detail's; earlier releases give it an opaque
    /// column of its own, up to the window's top edge.
    private var sidebarFloatsOverDetail: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }

    /// Output starts below the detail's bar row, or below the whole bar
    /// while it carries the Show Sidebar button.
    private func detailTopInset(for tab: ConsoleTab) -> CGFloat {
        splitVisibility(for: tab).isSidebarVisible == false ? detailBar.bottom : detailBar.top
    }

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
            NavigationSplitView(
                columnVisibility: splitVisibilityBinding(for: tab, presentation: presentation)
            ) {
                sidebarLists(showing: tab)
                    // The sidebar column reports a compact size class even
                    // beside a detail, so the lists are told outright.
                    .environment(\.isSidebarColumn, presentation.usesRegularColumns)
                    .environment(\.consoleListShowsDisclosure, !presentation.usesRegularColumns)
                    .navigationTitle(tab.title)
                    .navigationSplitViewColumnWidth(
                        min: presentation.sidebarWidth.minimum,
                        ideal: presentation.sidebarWidth.ideal,
                        max: presentation.sidebarWidth.maximum)
                    .navigationBarTitleDisplayMode(usesSidebarNavigation ? .inline : .automatic)
                    .toolbar { toolbar(for: tab) }
                    // `toolbar(for:)` puts the list's title at the bar's
                    // leading edge itself.
                    .toolbar(removing: usesSidebarNavigation ? .title : nil)
                    .bottomBar {
                        if usesSidebarNavigation { sidebarFooter(for: tab) }
                    }
                    // iPadOS 27 draws the system's button on its own glass;
                    // the sidebar has a bare one beside its others, and the
                    // detail one to bring the sidebar back. Removed here, it
                    // leaves the whole split view.
                    .toolbar(removing: usesSidebarNavigation ? .sidebarToggle : nil)
            } detail: {
                // Every tab keeps its split view alive; only the selected one
                // may mount the detail, or a terminal would attach twice.
                if tab == currentTab {
                    // An explicit stack, so a detail can push its own screens
                    // (Changes over an Agent) with the system's Back and swipe.
                    NavigationStack {
                        detail(in: tab)
                            .environment(
                                \.detailTopChromeInset,
                                horizontalSizeClass == .regular ? detailTopInset(for: tab) : 0)
                            .environment(\.detailSurfaceEdges, detailSurfaceEdges(for: tab))
                            .environment(\.revealDetailSidebar, sidebarReveal(for: tab))
                            .environment(
                                \.showsDetailBackHeader, !presentation.usesRegularColumns)
                            .toolbar {
                                if usesSidebarNavigation,
                                    splitVisibility(for: tab).isSidebarVisible == false
                                {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Show Sidebar", systemImage: "sidebar.left") {
                                            withAnimation(reduceMotion ? nil : .snappy) {
                                                splitVisibilities[
                                                    tab, default: ConsoleSplitVisibilityState()
                                                ].showSidebar()
                                            }
                                        }
                                    }
                                }
                            }
                            .background {
                                if horizontalSizeClass == .regular {
                                    NavigationBarTopReader { detailBar = $0 }
                                }
                            }
                            .overlay(alignment: .top) {
                                if horizontalSizeClass == .regular, !terminalOwnsTopEdge {
                                    Color(uiColor: .systemBackground)
                                        .frame(height: detailBar.top)
                                        .ignoresSafeArea(.container, edges: .top)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
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
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .update(from: presentation)
            }
            // A sidebar's switch hands this split view the other list, whose
            // state may predate the layout.
            .onChange(of: tab) { _, tab in
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .update(from: presentation)
            }
        }
        // Up to the window's top edge, as a split view alone in a window
        // runs: a terminal then reaches under the status bar, while the
        // columns' own bars still clear it.
        .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .top : [])
        // In every width, so a window turning compact drops the style.
        .background {
            ConsoleTabBarBridge(chromeScheme: tabBarChromeScheme, hidesBar: hidesTabBar)
        }
        .toolbarVisibility(hidesTabBar ? .hidden : .automatic, for: .tabBar)
    }

    /// Beside an iPad's sidebar both lists stay built, the one not shown
    /// out of sight and out of reach: a split view whose sidebar swaps its
    /// list rebuilds the whole column, its bar included, and each list keeps
    /// its scroll position and tucked search field across a switch.
    @ViewBuilder
    private func sidebarLists(showing tab: ConsoleTab) -> some View {
        if usesSidebarNavigation {
            ZStack {
                ForEach([ConsoleTab.agents, .terminals], id: \.self) { list in
                    sidebar(for: list)
                        .modifier(SidebarListShown(isShown: tab == list))
                }
            }
            // One field for both lists, searching the one on show.
            .searchable(
                text: tab == .terminals ? $terminalSearchText : $agentSearchText,
                isPresented: tab == .terminals
                    ? $isTerminalSearchPresented : $isAgentSearchPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: tab == .terminals ? "Search Terminals" : "Search Agents")
            .searchFocused($focusedSearch, equals: tab)
            .sidebarSearchDrawer(following: tab)
            // The title's list menu opens from here rather than from the
            // title: anything a bar item presents folds back onto the item's
            // frame, which lingers as a rectangle around a bare title for
            // about a second and a half after it closes.
            .overlay {
                GeometryReader { proxy in
                    let anchor = SidebarListMenu.anchor(
                        under: listMenuTitleFrame, in: proxy.frame(in: .global))
                    Color.clear
                        .frame(width: 1, height: 1)
                        .popover(isPresented: $isShowingListMenu, arrowEdge: .top) {
                            SidebarListChoices(
                                shown: tab, lists: [.agents, .terminals],
                                isPresented: $isShowingListMenu, select: switchList(to:))
                        }
                        .position(anchor)
                }
                // Measured from the column's top, under the bar.
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
            }
        } else {
            sidebar(for: tab)
        }
    }

    @ViewBuilder
    private func sidebar(for tab: ConsoleTab) -> some View {
        switch tab {
        case .agents:
            content
                .modifier(ConsoleListSearch(
                    text: $agentSearchText, isPresented: $isAgentSearchPresented,
                    focus: $focusedSearch, tab: .agents,
                    prompt: "Search Agents", showsField: !usesSidebarNavigation))
        case .terminals:
            if hosts.hosts.isEmpty {
                noHostsView
            } else {
                TerminalListView(
                    hosts: hosts.hosts,
                    console: console,
                    presentation: terminalPresentation,
                    filteredHostID: hostFilter,
                    searchQuery: terminalSearchText,
                    selection: selectedItem,
                    onOpen: { openTerminal($0, from: .terminals, bySidebar: true) },
                    onOpenHost: { openHostIssue($0) },
                    onShowHostIssues: { isShowingHostIssues = true },
                    onNewTerminal: { isStartingTerminal = true })
                .modifier(ConsoleListSearch(
                    text: $terminalSearchText, isPresented: $isTerminalSearchPresented,
                    focus: $focusedSearch, tab: .terminals,
                    prompt: "Search Terminals", showsField: !usesSidebarNavigation))
            }
        case .hosts, .settings:
            // These tabs show their own screens, not a split view.
            EmptyView()
        }
    }

    /// A filter is meaningless with a single Host.
    private var filtersByHost: Bool { hosts.hosts.count > 1 }

    /// At the largest text sizes a bar cannot fit its title beside three
    /// buttons, so the Host filter joins the presentation menu. An iPad
    /// sidebar keeps both menus at its foot, which has room for them.
    private var foldsHostFilter: Bool {
        filtersByHost && !usesSidebarNavigation && dynamicTypeSize >= .xxLarge
    }

    private var hostFilterPicker: some View {
        Picker("Host", selection: $hostFilter) {
            Text("All Hosts").tag(Host.ID?.none)
            ForEach(hosts.hosts) { host in
                Text(host.displayName).tag(Host.ID?.some(host.id))
            }
        }
    }

    @ViewBuilder
    private var foldedHostFilter: some View {
        if foldsHostFilter {
            Section("Filter by Host") { hostFilterPicker }
        }
    }

    private var hostFilterMenu: some View {
        Menu(
            "Filter by Host",
            systemImage: hostFilter == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill"
        ) {
            hostFilterPicker
        }
    }

    @ViewBuilder
    private func presentationMenu(for tab: ConsoleTab) -> some View {
        if tab == .terminals {
            Menu {
                Picker("Terminal presentation", selection: terminalPresentationBinding) {
                    ForEach(TerminalListPresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                foldedHostFilter
            } label: {
                Label("Presentation", systemImage: terminalPresentation.mode.systemImage)
            }
            .accessibilityLabel("Terminal list presentation")
            .accessibilityValue(terminalPresentation.mode.title)
        } else {
            Menu {
                Picker("Presentation", selection: presentationModeBinding) {
                    ForEach(ConsoleListPresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                foldedHostFilter
            } label: {
                Label("Presentation", systemImage: listPresentation.mode.systemImage)
            }
            .accessibilityLabel("Agent list presentation")
            .accessibilityValue(listPresentation.mode.title)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(for tab: ConsoleTab) -> some ToolbarContent {
        // An iPad sidebar's title, always at the bar's leading edge: the
        // bar's own title centers itself wherever it fits, so it would move
        // as the list, and the title's width, changes.
        if usesSidebarNavigation {
            ToolbarItem(placement: .topBarLeading) {
                SidebarListMenu(
                    shown: tab, lists: [.agents, .terminals],
                    isPresented: $isShowingListMenu, frame: $listMenuTitleFrame)
            }
            .sidebarItemBackground(.hidden)
        }
        // A sidebar keeps its list menus at its foot.
        if !usesSidebarNavigation, filtersByHost, !foldsHostFilter {
            ToolbarItem(placement: .primaryAction) {
                hostFilterMenu.hoverEffect(.highlight)
            }
        }
        if !usesSidebarNavigation, !hosts.hosts.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                presentationMenu(for: tab).hoverEffect(.highlight)
            }
        }
        if usesSidebarNavigation {
            // One item, so the bar sets no gap between the two, and neither
            // folds into its overflow menu without the other: beside a
            // window's controls a sidebar at its narrowest has room for both
            // only this way.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 0) {
                    if !hosts.hosts.isEmpty { newItemButton(for: tab) }
                    Button("Hide Sidebar", systemImage: "sidebar.left") {
                        withAnimation(reduceMotion ? nil : .snappy) {
                            splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                                .hideSidebar()
                        }
                    }
                }
                .buttonStyle(SidebarIconButtonStyle())
            }
            .sidebarItemBackground(.hidden)
        } else if !hosts.hosts.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                newItemButton(for: tab).hoverEffect(.highlight)
            }
        }
    }

    /// One button for both lists, so a sidebar switching lists keeps its
    /// bar as it is.
    private func newItemButton(for tab: ConsoleTab) -> some View {
        Button(tab == .terminals ? "New Terminal" : "New Agent", systemImage: "plus") {
            if tab == .terminals { isStartingTerminal = true } else { isStartingAgent = true }
        }
    }

    /// An iPad sidebar's foot, standing in for the tab bar: Hosts and
    /// Settings, then the list's menus.
    private func sidebarFooter(for tab: ConsoleTab) -> some View {
        HStack(spacing: 4) {
            Button(ConsoleTab.hosts.title, systemImage: "server.rack") { showHosts() }
            Button(ConsoleTab.settings.title, systemImage: "gearshape") { showSettings() }
            Spacer(minLength: 0)
            // A menu's pointer target is its own, not its button style's
            // label, so it takes the round highlight here.
            if filtersByHost, !foldsHostFilter {
                hostFilterMenu.roundPointerHighlight()
            }
            if !hosts.hosts.isEmpty {
                presentationMenu(for: tab).roundPointerHighlight()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(SidebarIconButtonStyle())
        .menuStyle(.button)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                    // Hosts and Settings show no detail to act on.
                    selection: !currentTab.isList
                        ? nil
                        : notificationRouter.path.last ?? selectedTerminal.map {
                            ConsoleAgent.ID(hostID: $0.hostID, paneID: $0.paneID)
                        },
                    agents: listPresentation.mode == .flat
                        ? filteredAgents.map(\.id)
                        : hostSections.filter { !$0.isCollapsed }.flatMap { $0.agents.map(\.id) },
                    isSearchFocused: focusedSearch != nil,
                    // Tabs are navigation, not cover: only sheets and alerts
                    // are, including the ones Hosts, Settings and the
                    // Terminals list present, which register nowhere.
                    isCovered: isStartingAgent || isStartingTerminal
                        || connectionDetailRequest != nil || isShowingHostIssues
                        || isShowingHostsSheet || isShowingSettingsSheet
                        || isPresentingOverConsole,
                    inputMode: inputMode.mode,
                    navigationAnchor: agentsListAnchor)
            },
            titles: ConsoleCommandTitles(
                listsTerminals: currentTab == .terminals,
                showsShell: currentTab.isList && notificationRouter.path.isEmpty
                    && selectedTerminal != nil),
            navigate: { id in
                // Agent shortcuts land on the Agents list from any tab.
                if currentTab != .agents { selectedTab.wrappedValue = .agents }
                guard id != notificationRouter.path.last else { return }
                if commandRegistry.terminal?.isFocused == true
                    || commandRegistry.composer?.isFocused == true
                {
                    keyboardHandoff.arm(for: id)
                }
                notificationRouter.path = [id]
            },
            focusSearch: {
                // Hosts and Settings have no search; ⌘F lands on Agents.
                let tab: ConsoleTab = currentTab == .terminals ? .terminals : .agents
                selectedTab.wrappedValue = tab
                // The field lives in the sidebar, which may be hidden.
                if horizontalSizeClass == .regular {
                    splitVisibilities[tab, default: ConsoleSplitVisibilityState()].showSidebar()
                }
                if tab == .terminals {
                    isTerminalSearchPresented = true
                } else {
                    isAgentSearchPresented = true
                }
                focusedSearch = tab
            },
            // ⌘N creates what the list on screen holds.
            newAgent: {
                if currentTab == .terminals {
                    isStartingTerminal = true
                } else {
                    isStartingAgent = true
                }
            },
            settings: { showSettings() },
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
                if selection != nil { detailDidOpenFromSidebar() }
            })
    }

    /// A pick in portrait hides the sidebar shown for it, whether a row
    /// was tapped or something made from the sidebar opened.
    private func detailDidOpenFromSidebar() {
        withAnimation(reduceMotion ? nil : .snappy) {
            splitVisibilities[currentTab]?.selectionDidOpenDetail()
        }
    }

    /// A shell made from `tab` (its list's New Terminal row, or the drawer
    /// of a shell it shows) opens there. Made after the user moved to the
    /// other list, it waits as `tab`'s pick instead of replacing what that
    /// list shows.
    private func openTerminal(
        _ terminal: ConsoleTerminal, from tab: ConsoleTab, bySidebar: Bool = false
    ) {
        if shownListTab == tab {
            selectTerminal(terminal)
            if bySidebar, currentTab == tab { detailDidOpenFromSidebar() }
        } else if horizontalSizeClass == .regular, !terminal.isAgent {
            rememberedSelections[tab] = .terminal(terminal)
        }
    }

    /// Something the window presents over the Console that registers
    /// nowhere: a sheet or alert from Hosts, Settings or a list. An active
    /// search field presents on some layouts too, and is not cover.
    private var isPresentingOverConsole: Bool {
        guard let presented = sceneWindow?.window?.rootViewController?.presentedViewController
        else { return false }
        return !(presented is UISearchController)
    }

    /// Where previous and next start from off the Agents list: the Agent
    /// it keeps, on stage under Hosts or Settings or parked under Terminals.
    private var agentsListAnchor: ConsoleAgent.ID? {
        guard currentTab != .agents else { return nil }
        if shownListTab == .agents { return notificationRouter.path.last }
        if case .agent(let id) = rememberedSelections[.agents] { return id }
        return nil
    }

    private func selectAgent(_ id: ConsoleAgent.ID) {
        changeSelection {
            showAgentsList(parking: parkedSelection)
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
        terminalOwnsTopEdge ? stagedTerminalChromeScheme : nil
    }

    /// A terminal reaches the window's top edge unless an opaque sidebar
    /// shares that edge and the two disagree: the status bar spans both
    /// columns and takes one scheme, so white text over a dark terminal
    /// would vanish over a light sidebar. The detail then keeps the app's
    /// own band above the terminal, with the status bar in it. A glass
    /// sidebar floats below the status bar, over the terminal. An iPhone
    /// wide enough for both columns shows no status bar in landscape.
    private var terminalOwnsTopEdge: Bool {
        horizontalSizeClass != .regular
            || UIDevice.current.userInterfaceIdiom != .pad
            || sidebarFloatsOverDetail
            || splitVisibility(for: currentTab).isSidebarVisible != true
            || stagedTerminalChromeScheme.map { $0 == colorScheme } ?? true
    }

    /// What an edge swipe on an iPad's detail does instead of going back:
    /// the detail stands beside its list there, so the swipe brings the
    /// sidebar out rather than leaving the screen. Nil on an iPhone and in
    /// a compact window, where the detail is pushed and the swipe goes back.
    private func sidebarReveal(for tab: ConsoleTab) -> (@MainActor @Sendable () -> Void)? {
        guard horizontalSizeClass == .regular, UIDevice.current.userInterfaceIdiom == .pad
        else { return nil }
        return { [splitVisibilities = $splitVisibilities, reduceMotion] in
            withAnimation(reduceMotion ? nil : .snappy) {
                splitVisibilities.wrappedValue[tab, default: ConsoleSplitVisibilityState()]
                    .showSidebar()
            }
        }
    }

    /// The chrome scheme of the terminal the detail shows, if any.
    private var stagedTerminalChromeScheme: ColorScheme? {
        // Hosts and Settings keep the selection but show no terminal.
        guard currentTab.isList else { return nil }
        if selectedTerminal != nil {
            return terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme)
        }
        guard let id = notificationRouter.path.last, agentShowingChanges != id,
            agentShowingChat != id
        else { return nil }
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
                    detailSurface: detailSurface,
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
                    onSelectTerminal: { selectTerminal($0) },
                    onShowsChanges: { shows in
                        if shows {
                            agentShowingChanges = id
                        } else if agentShowingChanges == id {
                            agentShowingChanges = nil
                        }
                    },
                    onShowsChat: { shows in
                        if shows {
                            agentShowingChat = id
                        } else if agentShowingChat == id {
                            agentShowingChat = nil
                        }
                    }
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
                onSelectTerminal: { openTerminal($0, from: tab) },
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
                    showsAgentsAction: splitVisibility(for: tab).showsAgentsAction,
                    listsTerminals: tab == .terminals)
            ) { action in
                switch action {
                case .showAgents:
                    withAnimation(reduceMotion ? nil : .snappy) {
                        splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                            .showSidebar()
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
                    .ignoresSafeArea(edges: detailSurfaceEdges(for: currentTab))
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
            ContentUnavailableView.search(text: agentSearchText)
        case .rows:
            List(selection: selectedItem) {
                if listPresentation.mode == .flat {
                    flatAgentListRows
                } else {
                    groupedAgentListRows
                }
            }
            .listStyle(.plain)
            .modifier(ConsoleSidebarListTint())
            .searchDrawerStartsTucked()
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

    @ViewBuilder
    private var flatAgentListRows: some View {
        if !visibleHostIssues.isEmpty {
            // On the Agent rows' edges; the list's own separator sets it
            // apart from the first Agent.
            ConsoleHostIssueList(
                issues: visibleHostIssues, onOpenHost: { openHostIssue($0) },
                onShowAll: { isShowingHostIssues = true })
                .modifier(ListRowVerticalInsetsRemoved())
                .listRowBackground(Color.clear)
                // Under the title nothing needs a rule; below, it runs from
                // the edge the Agent rows' rules do.
                .listRowSeparator(.hidden, edges: .top)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        ForEach(filteredAgents) { agent in
            agentRow(agent)
                // Right under an iPad sidebar's bar, a rule over the
                // first row would crowd it.
                .listRowSeparator(
                    usesSidebarNavigation && visibleHostIssues.isEmpty
                        && agent.id == filteredAgents.first?.id ? .hidden : .automatic,
                    edges: .top)
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
                    hostID: agent.hostID, paneID: agent.agent.paneID),
                changes: console.rowChanges.store(for: agent))
            .modifier(ConsoleRowSelectionContent())
        }
        // The list reads what it shows: a row on screen reads its Agent's
        // Checkout, and an exit from Working while none does waits for one.
        .onAppear { console.rowChanges.rowAppeared(agent) }
        .onDisappear { console.rowChanges.rowDisappeared(agent.id) }
        .onChange(of: agent.directory == nil) { _, lacksDirectory in
            if !lacksDirectory { console.rowChanges.agentReportedDirectory(agent) }
        }
        .modifier(
            ConsoleRowSelectionBackground(
                isSelected: notificationRouter.path.last == agent.id))
        .hoverEffect(.highlight)
        .modifier(
            ConsoleRowContextMenu {
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
                // Asks first, like the swipe. A menu item can be destructive:
                // the row stays put until the close succeeds.
                Divider()
                Button(
                    "Close \(closeScope(for: agent))", systemImage: "trash",
                    role: .destructive
                ) {
                    pendingTabClose = agent
                }
            } preview: {
                AgentCardView(
                    agent: agent,
                    layout: console.rowLayout(for: agent.hostID),
                    isPinned: console.pins.isPinned(
                        hostID: agent.hostID, paneID: agent.agent.paneID))
            })
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
    /// or context menu queued.
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

    /// What closing this Agent takes down, widest first.
    private func closeScope(for agent: ConsoleAgent) -> String {
        if console.closesWorkspaceWithTab(of: agent) { return "Workspace" }
        return console.closesTab(of: agent) ? "Tab" : "Pane"
    }

    private var pendingCloseScope: String {
        pendingTabClose.map(closeScope(for:)) ?? "Tab"
    }

    private var tabCloseDialogTitle: String { "Close \(pendingCloseScope)?" }

    private var tabCloseConfirmLabel: String { "Close \(pendingCloseScope)" }

    /// Confirmation copy naming the Agent as its row does, and the
    /// workspace when it dies with the tab.
    private func tabCloseMessage(for agent: ConsoleAgent) -> String {
        let name = AgentCardPresentation(
            agent: agent, layout: console.rowLayout(for: agent.hostID)
        ).switcherTitle
        if console.closesWorkspaceWithTab(of: agent) {
            let workspace = agent.workspaceLabel ?? "this workspace"
            return "Are you sure you want to also close workspace \(workspace)? It is the workspace's last tab."
        }
        if console.closesTab(of: agent) {
            return "Closes the tab running \u{201C}\(name)\u{201D}."
        }
        return "Closes the pane running \u{201C}\(name)\u{201D}. The tab's other panes stay open."
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
            searchQuery: agentSearchText)
    }

    private var hostSections: [ConsoleHostSection] {
        listPresentation.sections(
            hosts: hosts.hosts,
            console: console,
            filteredHostID: hostFilter,
            searchQuery: agentSearchText)
    }

    private var presentationModeBinding: Binding<ConsoleListPresentationMode> {
        Binding(
            get: { listPresentation.mode },
            set: { listPresentation.select($0) })
    }

    private func toggleHostSection(_ hostID: Host.ID) {
        // A search opens every Host holding a match, so a toggle then would
        // change nothing on screen, only what the list returns to after.
        guard agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
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
        let needle = agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return hostFiltered }
        return hostFiltered.filter { $0.matchesAgentSearch(needle) }
    }

    /// Host issues shown in the list: all of them, or the filtered Host's
    /// only — a filtered Console should not nag about other machines — and
    /// none while searching, where they would only bury the matches.
    private var visibleHostIssues: [ConsoleHostStatusPresentation] {
        guard agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return filteredHostIssues
    }

    /// Every Host problem under the Host filter, as the flat lists show
    /// them outside a search, and as their summary's sheet lists them.
    private var filteredHostIssues: [ConsoleHostStatusPresentation] {
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

    /// How the Console's sheets present, resolved against this view.
    private var sheetPresentation: ConsoleSheetPresentation {
        ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)
    }

    private func hostIssuesSheet(presentation sheetPresentation: ConsoleSheetPresentation)
        -> some View
    {
        ConsoleHostIssuesSheet(
            issues: filteredHostIssues,
            explained: hostIssuesSheetExplained,
            sheetPresentation: sheetPresentation,
            onOpenHost: { id in
                isShowingHostIssues = false
                presentHosts(id)
            }
        ) { id in
            if let host = hosts.hosts.first(where: { $0.id == id }),
                let detail = hostIssuesSheetDetail(for: id)
            {
                HostConnectionDetailContent(
                    presentation: detail,
                    host: host,
                    catalog: hosts,
                    sheetPresentation: sheetPresentation,
                    isRetryInFlight: manualReconnectInFlightHostIDs.contains(id)
                ) {
                    // As in the single Host's sheet: stays through the dial.
                    hostIssuesLastFailures[id] = detail.failure
                    Task { await reconnectHost(id) }
                }
            }
        }
    }

    private var hostIssuesSheetExplained: Set<Host.ID> {
        Set(filteredHostIssues.map(\.hostID).filter { hostIssuesSheetDetail(for: $0) != nil })
    }

    private func hostIssuesSheetDetail(for id: Host.ID) -> HostConnectionDetailPresentation? {
        connectionDetail(
            for: ConnectionDetailRequest(id: id, lastFailure: hostIssuesLastFailures[id]))
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

    /// Opens Hosts, on one Host's detail when `id` is given. A sheet
    /// closes back where it was opened, so only the tab names its origin.
    private func presentHosts(_ id: Host.ID? = nil) {
        if let id {
            hostsTabRequest = HostsTabRequest(
                hostID: id,
                origin: usesSidebarNavigation || currentTab == .hosts ? nil : currentTab)
        }
        showHosts()
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

private extension ToolbarContent {
    /// The glass a toolbar item shares with its neighbors; before iOS 26
    /// items draw none.
    @ToolbarContentBuilder
    func sidebarItemBackground(_ visibility: Visibility) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(visibility)
        } else {
            self
        }
    }
}

/// A list's search field under its title. An iPad's sidebar keeps one
/// field for both its lists instead; see `sidebarLists(showing:)`.
private struct ConsoleListSearch: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    var focus: FocusState<ConsoleTab?>.Binding
    let tab: ConsoleTab
    let prompt: LocalizedStringKey
    let showsField: Bool

    func body(content: Content) -> some View {
        if showsField {
            content
                .searchable(
                    text: $text, isPresented: $isPresented,
                    placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
                .searchFocused(focus, equals: tab)
        } else {
            content
        }
    }
}

/// An iPad sidebar's title as its list menu, drawn as the bar's own title
/// menu: the list's name and a chevron in a small disc. It only asks for
/// the choices; `sidebarLists(showing:)` presents them.
private struct SidebarListMenu: View {
    let shown: ConsoleTab
    /// Every list the menu switches between.
    let lists: [ConsoleTab]
    @Binding var isPresented: Bool
    /// The button's frame in the window.
    @Binding var frame: CGRect?

    /// Where the choices point from, in a sidebar column whose frame in the
    /// window is `column`: under the title, just above its bottom edge. The
    /// bar sits lower in a floating sidebar (iPadOS 26) than in one flush
    /// with the top (iPadOS 27), so it follows the title's own frame, with
    /// a guess for the pass before the title reports one.
    static func anchor(under title: CGRect?, in column: CGRect) -> CGPoint {
        guard let title, !title.isEmpty else { return CGPoint(x: 44, y: 40) }
        return CGPoint(x: title.midX - column.minX, y: title.maxY - column.minY - 4)
    }

    var body: some View {
        // As wide as the widest title throughout: the bar lays its items
        // out again only a while after a title changes, so a wider one
        // would be clipped. The width is held outside the button, whose own
        // frame, which its pointer highlight follows, fits the title on show.
        ZStack(alignment: .leading) {
            ForEach(lists) { SidebarListTitle(title: $0.title).hidden() }
            Button { isPresented = true } label: { SidebarListTitle(title: shown.title) }
                // A style of its own keeps the label SwiftUI's: bridged to a
                // bar button, it would show only its image.
                .buttonStyle(SidebarListTitleButtonStyle())
                // On the button itself: set inside its label, the highlight
                // gives way to one over the bar item's whole frame.
                .contentShape(.hoverEffect, Capsule().inset(by: 4))
                .hoverEffect(.highlight)
                .accessibilityHint("Switches between Agents and Terminals")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frame = $0
                }
        }
    }
}

/// The lists an iPad sidebar's title menu switches between, laid out as
/// a menu's rows.
private struct SidebarListChoices: View {
    let shown: ConsoleTab
    let lists: [ConsoleTab]
    @Binding var isPresented: Bool
    let select: (ConsoleTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lists) { list in
                Button {
                    isPresented = false
                    select(list)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .opacity(list == shown ? 1 : 0)
                            .accessibilityHidden(true)
                        Image(systemName: Self.symbol(for: list))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(list.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(list == shown ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
        .presentationCompactAdaptation(.popover)
    }

    private static func symbol(for list: ConsoleTab) -> String {
        list == .terminals ? "terminal" : "sparkles"
    }
}

private struct SidebarListTitle: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        // Fixed, as the bar's own title is: a larger one would push the
        // trailing buttons into the bar's overflow menu.
        .dynamicTypeSize(.large)
        // The leading inset puts the name in line with the rows' own
        // leading edge, as the bar's title is. The trailing one only clears
        // the pointer highlight: beside a window's controls the bar has
        // little width to spare.
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

private struct SidebarListTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.35 : 1)
    }
}

/// One of an iPad sidebar's two lists, shown or kept out of sight, touch,
/// focus, and VoiceOver; see `sidebarLists(showing:)`.
private struct SidebarListShown: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }
}

/// An iPad sidebar's bare buttons and menus, in its bar and at its foot:
/// symbols as bar buttons draw them, each with a bar button's hit area.
private struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .imageScale(.large)
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.35 : 1)
            .roundPointerHighlight()
    }
}

extension View {
    /// The pointer highlight every icon in an iPad sidebar takes: round,
    /// as a bare bar button's is.
    fileprivate func roundPointerHighlight() -> some View {
        contentShape(.hoverEffect, .circle).hoverEffect(.highlight)
    }
}

extension View {
    /// Content pinned to the bottom edge that the list scrolls under, with
    /// the system's scroll edge effect where there is one.
    @ViewBuilder
    fileprivate func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom) { content().background(.bar) }
        }
    }
}

/// Drops a row's vertical insets and keeps the list's own side margins, so
/// the row's edges and chevron meet the Agent rows' at every width: the
/// margins are 20 points on the widest iPhones, not 16.
private struct ListRowVerticalInsetsRemoved: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.listRowInsets(.vertical, 0)
        } else {
            content.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
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
                // The Workspace chevrons' weight and ink: a header's
                // hierarchical secondary draws a level lighter than theirs.
                Image(systemName: presentation.disclosureSystemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12, alignment: .center)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
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

/// What a list tab showed when the other list took the stage.
private enum ParkedSelection {
    case agent(ConsoleAgent.ID)
    /// The terminal itself, not its id: a reconnecting Host lists none of
    /// its terminals, and the tab still comes back to this one.
    case terminal(ConsoleTerminal)
}

extension EnvironmentValues {
    /// How far a full-bleed detail screen must start below the detail
    /// column's top edge to clear the chrome above its navigation bar. Zero
    /// in compact width; the screens still clear the status bar themselves.
    @Entry var detailTopChromeInset: CGFloat = 0
    /// The edges a detail screen's full-bleed surface fills past the safe
    /// area. Beside an opaque sidebar the leading one lies under the
    /// sidebar; every other edge, an iPhone's landscape insets included, is
    /// the surface's to fill.
    @Entry var detailSurfaceEdges: Edge.Set = .all
    /// A Console list shown as the sidebar beside a detail column, where it
    /// draws its own selection, focus ring, and lifted rows, sits on the
    /// sidebar's glass, and keeps its search field in view, or on an iPad
    /// searches from the sidebar's foot.
    @Entry var isSidebarColumn = false
    /// Brings out the sidebar beside an iPad's detail column. A detail's
    /// edge swipe calls it in place of going back; nil where the detail has
    /// no sidebar to show.
    @Entry var revealDetailSidebar: (@MainActor @Sendable () -> Void)? = nil
    /// The detail is pushed over the list, on an iPhone or in a compact iPad
    /// window, so it shows its own floating header with a Back button. A
    /// window's resize edge takes touches near its side, so in a narrow iPad
    /// window an edge swipe alone would leave no way back. False in regular
    /// columns, including a large iPhone in landscape, where the sidebar
    /// stands beside the detail.
    @Entry var showsDetailBackHeader = false
}

/// A navigation bar's vertical extent in its column's own coordinates.
struct NavigationBarBand: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

/// Reports where the enclosing navigation bar sits within its column, a
/// frame SwiftUI does not expose.
private struct NavigationBarTopReader: UIViewRepresentable {
    let onChange: @MainActor (NavigationBarBand) -> Void

    func makeUIView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: UIView {
        var onChange: @MainActor (NavigationBarBand) -> Void
        private var reported: NavigationBarBand?

        init(onChange: @escaping @MainActor (NavigationBarBand) -> Void) {
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
            guard window != nil, let navigation = enclosingNavigationController() else {
                return
            }
            // The column's own space: the terminal pads from the column's
            // top edge, wherever the column sits in the window.
            let bar = navigation.navigationBar
            let frame = bar.convert(bar.bounds, to: navigation.view)
            let band = NavigationBarBand(top: frame.minY, bottom: frame.maxY)
            guard band != reported else { return }
            reported = band
            let onChange = onChange
            Task { @MainActor in onChange(band) }
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                    let navigation = controller.navigationController
                {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}
