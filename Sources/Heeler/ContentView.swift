import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. App
/// activity drives the events sessions' suspend/resume (spec #20): the
/// connections survive a backgrounding for the length of the grace period
/// (see AppActivityCoordinator), then are torn down deliberately. Every
/// return to the foreground re-activates them — and, for a connection the
/// app was still holding, re-proves it, because a link can die while the app
/// is away without anything having noticed (#142).
struct ContentView: View {
    let pushRegistration: PushRegistrationStore
    let notificationRouter: AgentNotificationRouter
    @State private var hostStore: HostStore
    @State private var console: ConsoleStore
    @State private var notificationPreferences: NotificationPreferencesStore
    @State private var terminalThemes = TerminalThemeSettings()
    @State private var terminalZoom = TerminalZoomSettings()
    @State private var terminalFonts = TerminalFontSettings()
    @State private var snippets = SnippetStore()
    @State private var appearance = AppAppearanceSettings()
    @State private var relaySettings: NotificationRelaySettings
    @State private var bannerStore: AgentNotificationBannerStore
    @State private var liveActivities: HostLiveActivityCoordinator
    @State private var activity: AppActivityCoordinator
    @Environment(\.scenePhase) private var scenePhase

    /// `hostStore`, `console`, and `activity` are injectable so a test can
    /// drive the activity wiring below and observe that something consumed
    /// it: `ContentViewActivityDriverTests` is what turns deleting the
    /// `.task` that runs `ConsoleActivityDriver` red (#167). Defaults are
    /// the production values, so call sites and behavior are unchanged:
    /// `HostStore()` reads the real persisted catalog and `ConsoleStore()`
    /// reaches the real `sshSessionFactory()`.
    init(
        pushRegistration: PushRegistrationStore,
        notificationRouter: AgentNotificationRouter,
        hostStore: HostStore = HostStore(),
        console: ConsoleStore = ConsoleStore(),
        activity: AppActivityCoordinator = AppActivityCoordinator()
    ) {
        self.pushRegistration = pushRegistration
        self.notificationRouter = notificationRouter
        _hostStore = State(initialValue: hostStore)
        _console = State(initialValue: console)
        _activity = State(initialValue: activity)
        let relaySettings = NotificationRelaySettings()
        _relaySettings = State(initialValue: relaySettings)
        // Preference reads/writes borrow the Console's live per-Host SSH
        // connections (#75); the token comes from push bootstrap (#71), and
        // the custom relay URL (#76) rides along into each Host's notify.json.
        let notificationPreferences = NotificationPreferencesStore(
            transports: console,
            deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
            relayBaseURL: { [weak relaySettings] in relaySettings?.relayURL })
        _notificationPreferences = State(initialValue: notificationPreferences)
        // The in-app foreground banner (#77): presented-Agent suppression
        // reads the router's path at fire time; the preference gate reads
        // each Host's confirmed notify flags and fails closed on unknowns.
        _bannerStore = State(
            initialValue: AgentNotificationBannerStore(
                presentedAgent: { [weak notificationRouter] in notificationRouter?.path.last },
                triggers: { [weak notificationPreferences] in
                    notificationPreferences?.confirmedTriggers(for: $0)
                }))
        // One Live Activity per Host: the Console Agent list is the source
        // of truth while foregrounded; the plugin takes over over APNs
        // after the app suspends. Fail closed on a missing opt-in, key, or
        // device token — the same gates the registration write uses.
        _liveActivities = State(
            initialValue: HostLiveActivityCoordinator(
                controller: ActivityKitLiveActivityController(),
                preferences: LiveActivityPreferences(),
                transports: console,
                deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
                knownHostIDs: { [weak hostStore] in Set(hostStore?.hosts.map(\.id) ?? []) },
                hostDisplayName: { [weak hostStore] id in
                    hostStore?.hosts.first(where: { $0.id == id })?.displayName ?? ""
                },
                isAwaitingSnapshot: { [weak console] id in
                    console?.hostsAwaitingSnapshot.contains(id) ?? true
                },
                connectionStatus: { [weak console] id in
                    console?.hostStatuses[id]
                }))
    }

    private var terminal: TerminalSettings {
        TerminalSettings(
            themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
            snippets: snippets)
    }

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console, terminal: terminal,
            appearance: appearance,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            notificationRouter: notificationRouter,
            bannerStore: bannerStore,
            liveActivities: liveActivities,
            activity: activity
        )
        // The one place the app's light/dark override is applied: it lands on
        // the window, so sheets, pushed screens, and the UIKit terminal
        // surfaces all resolve against the chosen appearance.
        .preferredColorScheme(appearance.preferredColorScheme)
        .task {
            console.setHosts(hostStore.hosts)
            notificationPreferences.setHosts(hostStore.hosts)
            await console.resume()
        }
        .onChange(of: hostStore.hosts) {
            console.setHosts(hostStore.hosts)
            notificationPreferences.setHosts(hostStore.hosts)
        }
        // Feeds the Console's Agent list to the router — so a notification
        // tap that arrived before the Hosts synced (killed-state launch)
        // routes the moment its pane appears — and to the banner store,
        // which diffs it for foreground Blocked/Done transitions (#77).
        .onChange(of: console.agents, initial: true) {
            notificationRouter.agentsDidChange(console.agents)
            bannerStore.agentsDidChange(console.agents)
            liveActivities.agentsDidChange(console.agents)
        }
        // The banner's preference gate fails closed on unknown flags (#77),
        // so re-read each Host's registration file as its connection comes up
        // (and once the push token lands) instead of waiting for a Settings
        // visit that may never happen.
        .onChange(of: console.hostStatuses) {
            Task { await notificationPreferences.refresh() }
            liveActivities.connectionsDidChange()
        }
        .onChange(of: console.hostsAwaitingSnapshot) {
            liveActivities.connectionsDidChange()
        }
        .onChange(of: activity.activationCount) {
            liveActivities.reconcile()
        }
        .onChange(of: pushRegistration.deviceToken) {
            Task { await notificationPreferences.refresh() }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                activity.didBecomeActive()
                // Re-probes notification permission on every return, grace
                // period or not: the user may have flipped it in the
                // Settings app while we were backgrounded.
                Task { await pushRegistration.refresh() }
            case .background:
                activity.didEnterBackground()
            default:
                break
            }
        }
        // Only a real suspension moves the connections: a backgrounding the
        // grace period absorbed emits no `.suspended`, so a quick trip out of
        // the app leaves the events sessions and Attach terminals untouched.
        // Driven off the coordinator's event stream rather than an `onChange`
        // of its phase — the suspension happens while the app is in the
        // background and rendering nothing, and a view that only compares the
        // value it last saw misses both that edge and the resume behind it
        // (#142).
        .task {
            await ConsoleActivityDriver(activity: activity, console: console).run()
        }
        .task { await pushRegistration.refresh() }
        .task { liveActivities.start() }
    }
}

#Preview {
    ContentView(
        pushRegistration: PushRegistrationStore(),
        notificationRouter: AgentNotificationRouter())
}
