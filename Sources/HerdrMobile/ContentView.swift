import SwiftUI

/// Root view: the Console (#8), with Host management (#14) behind it. Scene
/// phase drives the events sessions' suspend/resume (spec #20): background
/// tears connections down deliberately, foreground re-syncs.
struct ContentView: View {
    @State private var hostStore = HostStore()
    @State private var console = ConsoleStore()
    /// The single on-device speech engine, composed once and shared by Settings'
    /// model management and the reply box's recording path so there is one
    /// microphone owner across the app (#34, #38).
    @State private var dictationEngine: any DictationEngine
    /// App-level Dictation settings: the selected language (persisted) and the
    /// on-device model lifecycle, shared by the Settings screen and the reply
    /// box's recording path (#38).
    @State private var dictationSettings: DictationSettingsStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let engine = SpeechDictationEngine()
        _dictationEngine = State(initialValue: engine)
        _dictationSettings = State(initialValue: DictationSettingsStore(engine: engine))
    }

    var body: some View {
        ConsoleView(
            hosts: hostStore, console: console,
            dictationSettings: dictationSettings, dictationEngine: dictationEngine)
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
