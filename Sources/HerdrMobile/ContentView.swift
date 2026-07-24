import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. Scene
/// phase drives the events sessions' suspend/resume (spec #20): background
/// tears connections down deliberately, foreground re-syncs.
struct ContentView: View {
    let pushRegistration: PushRegistrationStore
    let notificationRouter: AgentNotificationRouter
    @State private var hostStore = HostStore()
    @State private var console = ConsoleStore()
    @State private var terminalThemes = TerminalThemeSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console, terminalThemes: terminalThemes,
            pushRegistration: pushRegistration, notificationRouter: notificationRouter
        )
        .task {
            console.setHosts(hostStore.hosts)
            await console.resume()
        }
        .onChange(of: hostStore.hosts) {
            console.setHosts(hostStore.hosts)
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
