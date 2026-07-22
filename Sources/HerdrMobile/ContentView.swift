import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. Scene
/// phase drives the events sessions' suspend/resume (spec #20): background
/// tears connections down deliberately, foreground re-syncs.
struct ContentView: View {
    @State private var hostStore = HostStore()
    @State private var console = ConsoleStore()
    @State private var terminalThemes = TerminalThemeSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ConsoleView(hosts: hostStore, console: console, terminalThemes: terminalThemes)
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
                    Task { await console.resume() }
                case .background:
                    Task { await console.suspend() }
                default:
                    break
                }
            }
    }
}

#Preview {
    ContentView()
}
