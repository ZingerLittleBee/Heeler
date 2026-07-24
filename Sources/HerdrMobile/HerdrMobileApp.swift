import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HerdrMobileApp: App {
    /// APNs delivers device tokens through UIApplicationDelegate callbacks
    /// only, so push bootstrap (#71) needs this adaptor.
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self)
    private var pushDelegate

    init() {
        try? ImagePreparer.cleanupRemnants()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                pushRegistration: pushDelegate.registration,
                notificationRouter: pushDelegate.notificationRouter)
        }
    }
}
