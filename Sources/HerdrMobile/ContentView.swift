import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. Scene
/// phase drives the events sessions' suspend/resume (spec #20): background
/// tears connections down deliberately, foreground re-syncs.
struct ContentView: View {
    let pushRegistration: PushRegistrationStore
    @State private var hostStore = HostStore()
    @State private var console = ConsoleStore()
    @State private var terminalThemes = TerminalThemeSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console, terminalThemes: terminalThemes,
            pushRegistration: pushRegistration
        )
        .task {
            console.setHosts(hostStore.hosts)
            await console.resume()
        }
        .onChange(of: hostStore.hosts) {
            console.setHosts(hostStore.hosts)
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
    ContentView(pushRegistration: PushRegistrationStore())
}
