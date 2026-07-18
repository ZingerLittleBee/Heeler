import SwiftUI

/// Root view: Host management (#14) for now. The flat Console agent list
/// (#8) takes over as root once it exists; Hosts then move behind it.
struct ContentView: View {
    @State private var hostStore = HostStore()

    var body: some View {
        HostListView(store: hostStore)
    }
}

#Preview {
    ContentView()
}
