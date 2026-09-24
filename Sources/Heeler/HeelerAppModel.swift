import Observation
import SwiftUI

/// The stores every window shares, and the app-wide wiring between them.
///
/// On iPad each window is its own scene with its own `ContentView`, but there
/// is still one Host catalog, one set of Host connections, one Live Activity
/// per Host, and one app activity: building these per window would open every
/// connection once per window and let two coordinators fight over the same
/// Live Activity. So the composition root lives here, once per process, and a
/// window adds only what is genuinely its own — its navigation router and its
/// restored Agent.
///
/// App activity drives the events sessions' suspend/resume (spec #20): the
/// connections survive a backgrounding for the length of the grace period
/// (see AppActivityCoordinator), then are torn down deliberately. Every
/// return to the foreground re-activates them — and, for a connection the
/// app was still holding, re-proves it, because a link can die while the app
/// is away without anything having noticed (#142). The phase that feeds it
/// is the app's aggregate one, so backgrounding one window while another
/// stays on screen suspends nothing.
@MainActor
final class HeelerAppModel {
    let pushRegistration: PushRegistrationStore
    let sceneDirectory: AgentSceneDirectory
    let hostStore: HostStore
    let console: ConsoleStore
    let notificationPreferences: NotificationPreferencesStore
    let terminalThemes: TerminalThemeSettings
    let terminalZoom: TerminalZoomSettings
    let terminalFonts: TerminalFontSettings
    let terminalEdgeDock: EdgeDockSettings
    let snippets: SnippetStore
    let appearance: AppAppearanceSettings
    let inputMode: AgentInputModeSettings
    let relaySettings: NotificationRelaySettings
    let bannerStore: AgentNotificationBannerStore
    let liveActivities: HostLiveActivityCoordinator
    let activity: AppActivityCoordinator

    private var isStarted = false
    private var observers: [AnyObject] = []

    /// `hostStore`, `console`, and `activity` are injectable so a test can
    /// drive the activity wiring and observe that something consumed it:
    /// `AppModelActivityDriverTests` is what turns deleting the task that
    /// runs `ConsoleActivityDriver` red (#167). Defaults are the production
    /// values: `HostStore()` reads the real persisted catalog and
    /// `ConsoleStore()` reaches the real `sshSessionFactory()`.
    init(
        pushRegistration: PushRegistrationStore,
        sceneDirectory: AgentSceneDirectory,
        hostStore: HostStore = HostStore(),
        console: ConsoleStore = ConsoleStore(),
        activity: AppActivityCoordinator = AppActivityCoordinator()
    ) {
        self.pushRegistration = pushRegistration
        self.sceneDirectory = sceneDirectory
        self.hostStore = hostStore
        self.console = console
        self.activity = activity
        terminalThemes = TerminalThemeSettings()
        terminalZoom = TerminalZoomSettings()
        terminalFonts = TerminalFontSettings()
        terminalEdgeDock = EdgeDockSettings()
        snippets = SnippetStore()
        appearance = AppAppearanceSettings()
        inputMode = AgentInputModeSettings()
        let relaySettings = NotificationRelaySettings()
        self.relaySettings = relaySettings
        // Preference reads/writes borrow the Console's live per-Host SSH
        // connections (#75); the token comes from push bootstrap (#71), and
        // the custom relay URL (#76) rides along into each Host's notify.json.
        let notificationPreferences = NotificationPreferencesStore(
            transports: console,
            deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
            relayBaseURL: { [weak relaySettings] in relaySettings?.relayURL })
        self.notificationPreferences = notificationPreferences
        // The in-app foreground banner (#77): presented-Agent suppression
        // reads the key window's Agent at fire time; the preference gate
        // reads each Host's confirmed notify flags and fails closed on
        // unknowns.
        bannerStore = AgentNotificationBannerStore(
            presentedAgent: { [weak sceneDirectory] in sceneDirectory?.keyScenePresentedAgent },
            triggers: { [weak notificationPreferences] in
                notificationPreferences?.confirmedTriggers(for: $0)
            })
        // One Live Activity per Host: the Console Agent list is the source
        // of truth while foregrounded; the plugin takes over over APNs
        // after the app suspends. Fail closed on a missing opt-in, key, or
        // device token — the same gates the registration write uses.
        liveActivities = HostLiveActivityCoordinator(
            controller: ActivityKitLiveActivityController(),
            preferences: LiveActivityPreferences(),
            transports: console,
            deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
            knownHostIDs: { [weak hostStore] in Set(hostStore?.hosts.map(\.id) ?? []) },
            hostDisplayName: { [weak hostStore] id in
                hostStore?.hosts.first(where: { $0.id == id })?.displayName ?? ""
            },
            isAwaitingSnapshot: { [weak console] id in
                console?.hostsAwaitingSnapshot.contains(id) ?? true
            },
            connectionStatus: { [weak console] id in
                console?.hostStatuses[id]
            },
            pinnedPaneIDs: { [weak console] id in
                console?.pins.pinnedPaneIDs(for: id) ?? []
            },
            rowLayout: { [weak console] id in console?.rowLayout(for: id) })
    }

    var terminal: TerminalSettings {
        TerminalSettings(
            themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
            snippets: snippets, edgeDock: terminalEdgeDock)
    }

    /// Starts the app-wide work exactly once, however many windows ask. Every
    /// window calls this as it appears; only the first call does anything.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // The banner store diffs the Agent list for foreground Blocked/Done
        // transitions (#77); both it and the Live Activities take the
        // current list as their baseline before the Hosts connect. Shell
        // rows have no Agent Status, so neither ever sees them.
        bannerStore.agentsDidChange(console.agents.excludingShells)
        liveActivities.agentsDidChange(console.agents.excludingShells)

        Task {
            console.setHosts(hostStore.hosts)
            notificationPreferences.setHosts(hostStore.hosts)
            await console.resume()
        }
        // Only a real suspension moves the connections: a backgrounding the
        // grace period absorbed emits no `.suspended`, so a quick trip out of
        // the app leaves the events sessions and Attach terminals untouched.
        // Driven off the coordinator's event stream rather than an observation
        // of its phase — the suspension happens while the app is in the
        // background and rendering nothing, and a consumer that only compares
        // the value it last saw misses both that edge and the resume behind
        // it (#142). The stream has one consumer for the life of the process.
        Task {
            await ConsoleActivityDriver(activity: activity, console: console).run()
        }
        Task { await pushRegistration.refresh() }
        // Existing installs' Notification Keys predate the app-group
        // mirror; refresh it before a locked widget render needs it.
        NotificationKeyStore().refreshMirror()
        liveActivities.start()

        observeStores()
    }

    /// The app's aggregate scene phase: active while any window is.
    func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            activity.didBecomeActive()
            // Re-probes notification permission on every return, grace
            // period or not: the user may have flipped it in the Settings
            // app while we were backgrounded.
            Task { await pushRegistration.refresh() }
        case .background:
            activity.didEnterBackground()
        default:
            break
        }
    }

    /// Store-to-store wiring that used to hang off the single window's view.
    /// Observed here instead, so it runs once rather than once per window,
    /// and keeps running while no window is rendering.
    private func observeStores() {
        let hostStore = self.hostStore
        let console = self.console
        let activity = self.activity
        let pushRegistration = self.pushRegistration

        observe({ hostStore.hosts }) { [weak self] hosts in
            guard let self else { return }
            console.setHosts(hosts)
            notificationPreferences.setHosts(hosts)
            liveActivities.layoutsDidChange()
        }
        // Shells have no Agent Status, and their titles change constantly:
        // observing the shell-free list keeps that churn from restarting the
        // Live Activity settle timer.
        observe({ console.agents.excludingShells }) { [weak self] statusAgents in
            self?.bannerStore.agentsDidChange(statusAgents)
            self?.liveActivities.agentsDidChange(statusAgents)
        }
        observe({ console.rowLayouts.hostLayouts }) { [weak self] _ in
            self?.liveActivities.layoutsDidChange()
        }
        observe({ console.sidebarSnapshots.states }) { [weak self] _ in
            self?.liveActivities.layoutsDidChange()
        }
        observe({ console.pins.revision }) { [weak self] _ in
            self?.liveActivities.pinsDidChange()
        }
        // The banner's preference gate fails closed on unknown flags (#77),
        // so re-read each Host's registration file as its connection comes up
        // (and once the push token lands) instead of waiting for a Settings
        // visit that may never happen.
        observe({ console.hostStatuses }) { [weak self] _ in
            guard let self else { return }
            Task { await self.notificationPreferences.refresh() }
            liveActivities.connectionsDidChange()
        }
        observe({ console.hostsAwaitingSnapshot }) { [weak self] _ in
            self?.liveActivities.connectionsDidChange()
        }
        observe({ activity.activationCount }) { [weak self] _ in
            self?.liveActivities.reconcile()
        }
        observe({ pushRegistration.deviceToken }) { [weak self] _ in
            guard let self else { return }
            Task { await self.notificationPreferences.refresh() }
        }
    }

    private func observe<Value: Equatable>(
        _ read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        observers.append(StoreChangeObserver(read: read, onChange: onChange))
    }
}

/// Calls `onChange` after each change to an observed value, like a view's
/// `onChange(of:)` but without a view: re-arms `withObservationTracking`
/// after every change and delivers the value on the next main-actor turn,
/// once the mutation that triggered it has finished. Changes that land
/// before that turn coalesce into one call with the latest value.
@MainActor
private final class StoreChangeObserver<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var lastValue: Value

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        lastValue = read()
        track()
    }

    private func track() {
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        guard value != lastValue else { return }
        lastValue = value
        onChange(value)
    }
}
