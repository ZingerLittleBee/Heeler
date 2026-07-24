import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. Scene
/// phase drives the events sessions' suspend/resume (spec #20): background
/// tears connections down deliberately, foreground re-syncs.
struct ContentView: View {
    let pushRegistration: PushRegistrationStore
    let notificationRouter: AgentNotificationRouter
    @State private var hostStore = HostStore()
    @State private var console: ConsoleStore
    @State private var notificationPreferences: NotificationPreferencesStore
    @State private var terminalThemes = TerminalThemeSettings()
    @Environment(\.scenePhase) private var scenePhase

    init(pushRegistration: PushRegistrationStore, notificationRouter: AgentNotificationRouter) {
        self.pushRegistration = pushRegistration
        self.notificationRouter = notificationRouter
        let console = ConsoleStore()
        _console = State(initialValue: console)
        // Preference reads/writes borrow the Console's live per-Host SSH
        // connections (#75); the token comes from push bootstrap (#71).
        _notificationPreferences = State(
            initialValue: NotificationPreferencesStore(
                transports: console,
                deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken }))
    }

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console, terminalThemes: terminalThemes,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            notificationRouter: notificationRouter
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
        // Feeds the router the Console's Agent list so a notification tap
        // that arrived before the Hosts synced (killed-state launch) routes
        // the moment its pane appears.
        .onChange(of: console.agents, initial: true) {
            notificationRouter.agentsDidChange(console.agents)
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                // Also re-probes notification permission: the user may have
                // flipped it in the Settings app while we were backgrounded.
                Task { await console.resume() }
                Task { await pushRegistration.refresh() }
            case .background:
                Task { await console.suspend() }
            default:
                break
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
