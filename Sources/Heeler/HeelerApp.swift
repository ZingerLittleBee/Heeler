import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HeelerApp: App {
    /// APNs delivers device tokens through UIApplicationDelegate callbacks
    /// only, so push bootstrap (#71) needs this adaptor.
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self)
    private var pushDelegate
    /// The aggregate phase across every window: active while any one is.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? ImagePreparer.cleanupRemnants()
        try? FilePreparer.cleanupRemnants()
    }

    var body: some Scene {
        // Valued by the Agent a window shows, so Open in New Window and a
        // dragged Console row each get a window restored to their Agent. A
        // cold launch opens the Console with no value.
        WindowGroup(for: AgentRoute.self) { $route in
            #if DEBUG && targetEnvironment(simulator)
                if DemoScreenshotMode.isEnabled {
                    DemoScreenshotRootView()
                } else {
                    productionContent(route: $route)
                }
            #else
                productionContent(route: $route)
            #endif
        }
        .commands { ConsoleCommands() }
        // Keeps the Usage widgets current while the app is closed.
        .backgroundTask(.appRefresh(AgentUsageBackgroundRefresh.identifier)) { [pushDelegate] in
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            await pushDelegate.appModel.refreshUsageInBackground()
        }
        .onChange(of: scenePhase) {
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            pushDelegate.appModel.scenePhaseDidChange(scenePhase)
        }
    }

    private func productionContent(route: Binding<AgentRoute?>) -> some View {
        ContentView(app: pushDelegate.appModel, windowRoute: route)
    }
}
