import SwiftUI
import UIKit

/// One window's root: the Console (#8), with Host management (#14) behind it.
///
/// The stores behind it are app-wide (`HeelerAppModel`); what a window owns
/// is its navigation. On iPad every window is a scene with its own router,
/// so two windows can show two Agents, and each restores its own Agent after
/// the app is terminated: first from its scene storage, else from the value
/// the window was opened with, else from a dragged row's user activity.
struct ContentView: View {
    let app: HeelerAppModel
    /// The `WindowGroup` value: the Agent this window was opened on, kept in
    /// step with the window's navigation so opening that Agent again finds
    /// this window.
    @Binding var windowRoute: AgentRoute?
    @State private var notificationRouter = AgentNotificationRouter()
    @State private var sceneID = UUID()
    @State private var window = WindowReference()
    /// A dragged row's Agent that reached this scene before it restored.
    @State private var incomingActivityRoute: AgentRoute?
    @State private var hasRestoredRoute = false
    /// Replaced once restoration knows whether this window is new.
    @State private var activation = SceneActivationTracker(isRestored: false)
    /// `AgentRoute.sceneStorageValue`; nil while the window shows the Console.
    @SceneStorage("dev.bybee.heeler.agentRoute") private var storedRoute: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ConsoleView(
            hosts: app.hostStore, console: app.console, terminal: app.terminal,
            inputMode: app.inputMode,
            detailSurface: app.detailSurface,
            appearance: app.appearance,
            pushRegistration: app.pushRegistration,
            notificationPreferences: app.notificationPreferences,
            relaySettings: app.relaySettings,
            notificationRouter: notificationRouter,
            bannerStore: app.bannerStore,
            liveActivities: app.liveActivities,
            activity: app.activity
        )
        .environment(\.sceneWindow, window)
        .environment(
            \.agentSceneRouting,
            AgentSceneRouting(directory: app.sceneDirectory, sceneID: sceneID))
        // The one place the app's light/dark override is applied: it lands on
        // the window, so sheets, pushed screens, and the UIKit terminal
        // surfaces all resolve against the chosen appearance.
        .preferredColorScheme(app.appearance.preferredColorScheme)
        .background {
            WindowReader { window.attach($0) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            // Restored first, so a notification tap that launched the app
            // and is waiting for a window lands on top of it when the window
            // registers. A dragged row's Agent needs the registration to
            // route through the single-window rule, so it goes last.
            let draggedRoute = restoreRoute()
            app.sceneDirectory.register(
                sceneID: sceneID, router: notificationRouter, window: window,
                activate: { activateWindow() })
            window.observeInteraction { [directory = app.sceneDirectory, sceneID] in
                directory.sceneDidReceiveInteraction(sceneID: sceneID)
            }
            if scenePhase == .active {
                sceneDidBecomeActive()
            }
            if let draggedRoute {
                app.sceneDirectory.open(draggedRoute.target, preferredSceneID: sceneID)
            }
            app.start()
        }
        .onDisappear {
            app.sceneDirectory.unregister(sceneID: sceneID)
        }
        // A foreground return is not the user choosing this window; see
        // `SceneActivationTracker`. Moving between windows arrives through
        // `observeInteraction` instead.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                sceneDidBecomeActive()
            }
        }
        // Feeds the Console's Agent list to this window's router, so a
        // notification tap that arrived before the Hosts synced (killed-state
        // launch) routes the moment its pane appears.
        .onChange(of: app.console.agents, initial: true) {
            notificationRouter.agentsDidChange(app.console.agents)
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Every navigation is written back, so a relaunch restores the Agent
        // this window was last on.
        .onChange(of: notificationRouter.path) { _, path in
            let route = path.last.map(AgentRoute.init(agentID:))
            storedRoute = route?.sceneStorageValue
            if windowRoute != route {
                windowRoute = route
            }
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Live Activity row links name an Agent; surrounding chrome,
        // compact, and minimal presentations name only the Host and land on
        // the Console. Notification links share the same URL parser.
        .onOpenURL { url in
            guard let link = AgentActivityLink.target(from: url) else { return }
            app.sceneDirectory.open(
                link.paneID.map { AgentNotificationTarget(hostID: link.hostID, paneID: $0) },
                preferredSceneID: sceneID)
        }
        .onContinueUserActivity(AgentRoute.activityType) { activity in
            guard let route = AgentRoute(userActivity: activity) else { return }
            if hasRestoredRoute {
                app.sceneDirectory.open(route.target, preferredSceneID: sceneID)
            } else {
                incomingActivityRoute = route
            }
        }
        // An existing window prefers Heeler's own links, so a Live Activity
        // tap lands in a window that is already open instead of spawning
        // one. A dragged row's activity is not a `heeler://` link, so it
        // still gets the new window it was dropped to create.
        .handlesExternalEvents(
            preferring: [Self.linkEventPrefix], allowing: ["*"])
    }

    private static let linkEventPrefix = "\(AgentActivityLink.scheme)://"

    /// Counts only a newly opened window's first activation as the user
    /// working in it.
    private func sceneDidBecomeActive() {
        guard activation.sceneDidBecomeActive() else { return }
        app.sceneDirectory.sceneDidBecomeActive(sceneID: sceneID)
    }

    /// Applies the restoration precedence once, on the window's first
    /// appearance. A stored or window-value route is placed on the path
    /// directly rather than through `open`: the Agent detail then shows the
    /// Host connecting and the Agent loading, and says so if the pane is
    /// gone, instead of quietly falling back to the Console after a grace
    /// period. A dragged row's route is returned for the caller to open once
    /// this window is registered.
    private func restoreRoute() -> AgentRoute? {
        guard !hasRestoredRoute else { return nil }
        hasRestoredRoute = true
        let incoming = incomingActivityRoute
        incomingActivityRoute = nil
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: storedRoute, windowValue: windowRoute, userActivity: incoming)
        // A window back from its own scene storage is one the system
        // restored, not one the user just opened.
        activation = SceneActivationTracker(isRestored: restoration?.source == .sceneStorage)
        guard let restoration else { return nil }
        switch restoration.source {
        case .sceneStorage, .windowValue:
            notificationRouter.path = [restoration.route.agentID]
            return nil
        case .userActivity:
            return restoration.route
        }
    }

    /// Brings this window forward when a deep link picks it. A no-op for the
    /// window the user is already in.
    private func activateWindow() {
        guard let scene = window.window?.windowScene,
            scene.activationState != .foregroundActive
        else { return }
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(session: scene.session),
            errorHandler: nil)
    }
}

#Preview {
    ContentView(
        app: HeelerAppModel(
            pushRegistration: PushRegistrationStore(), sceneDirectory: AgentSceneDirectory()),
        windowRoute: .constant(nil))
}
