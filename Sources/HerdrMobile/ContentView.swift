import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. App
/// activity drives the events sessions' suspend/resume (spec #20): the
/// connections survive a backgrounding for the length of the grace period
/// (see AppActivityCoordinator), then are torn down deliberately; returning
/// to the foreground after a real suspension re-syncs.
struct ContentView: View {
    let pushRegistration: PushRegistrationStore
    let notificationRouter: AgentNotificationRouter
    @State private var hostStore = HostStore()
    @State private var console: ConsoleStore
    @State private var notificationPreferences: NotificationPreferencesStore
    @State private var terminalThemes = TerminalThemeSettings()
    @State private var terminalZoom = TerminalZoomSettings()
    @State private var relaySettings: NotificationRelaySettings
    @State private var bannerStore: AgentNotificationBannerStore
    @State private var activity = AppActivityCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init(pushRegistration: PushRegistrationStore, notificationRouter: AgentNotificationRouter) {
        self.pushRegistration = pushRegistration
        self.notificationRouter = notificationRouter
        let console = ConsoleStore()
        _console = State(initialValue: console)
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
    }

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console, terminalThemes: terminalThemes,
            terminalZoom: terminalZoom,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            notificationRouter: notificationRouter,
            bannerStore: bannerStore,
            activity: activity
        )
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
        }
        // The banner's preference gate fails closed on unknown flags (#77),
        // so re-read each Host's registration file as its connection comes up
        // (and once the push token lands) instead of waiting for a Settings
        // visit that may never happen.
        .onChange(of: console.hostStatuses) {
            Task { await notificationPreferences.refresh() }
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
        // Only a real suspension moves the connections. A backgrounding the
        // grace period absorbed never reaches here, so a quick trip out of
        // the app leaves the events sessions and Attach terminals untouched.
        .onChange(of: activity.phase) {
            switch activity.phase {
            case .active:
                Task { await console.resume() }
            case .suspended:
                // The background assertion is held until this returns, so
                // the SSH teardown finishes before the process freezes.
                Task {
                    await console.suspend()
                    activity.didFinishSuspending()
                }
            }
        }
        .task { await pushRegistration.refresh() }
    }
}

#Preview {
    ContentView(
        pushRegistration: PushRegistrationStore(),
        notificationRouter: AgentNotificationRouter())
}
