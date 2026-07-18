import SwiftUI

/// Placeholder root view. Exists only to make the skeleton build and launch;
/// the flat Console agent list replaces it in M1 (#8).
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "herdr",
            systemImage: "terminal",
            description: Text("Console coming soon.")
        )
    }
}

#Preview {
    ContentView()
}
