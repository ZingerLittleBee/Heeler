import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HerdrMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
