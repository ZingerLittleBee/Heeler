import Foundation
import Testing
import os

@testable import Heeler

/// Agent Notifications, Live Activity and seen marks on a tmux Host (ADRs 0033
/// and 0044): this device's registration (`"session": "tmux/<socket>"`), Live
/// Activity token and seen marks (`"core": "tmux-<pid>-<start>"`) live in the
/// Host Helper's directory, over `ScriptedTmuxHost` and `ScriptedHelperHost`.
@MainActor
@Suite("Agent Notifications on a tmux Host through the Host Helper", .timeLimit(.minutes(1)))
struct TmuxHostHelperNotificationsTests {
    private static let directory = "\(ScriptedTmuxHost.home)/.local/share/heeler/host-helper"
    private static let registrationPath = "\(directory)/notifications.json"
    private static let configPath = "\(directory)/notify.json"
    private static let relay = URL(string: "https://relay.example")
    private nonisolated static let stoppedServer = TransportError.tmuxServerNotRunning(socketName: "work")

    private let host = Host(
        name: "box",
        address: "box.example",
        username: "dev",
        serverKind: .tmux,
        sessionName: "  work ",
        tmuxPaths: ScriptedTmuxHost.paths("work"))
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let keys = NotificationKeyStore(secrets: InMemorySecretStore(), mirror: nil)
    private let viewer = UUID()
    private let window = UUID()

    private struct Rig {
        let tmux: ScriptedTmuxHost
        let helper: ScriptedHelperHost
        let console: ConsoleStore
        let preferences: NotificationPreferencesStore
    }

    private nonisolated static func claude(
        session: Int = 0,
        sessionName: String = "api",
        window: Int = 0,
        pane: Int = 0,
        _ status: String
    ) -> TmuxInventory.Pane {
        .make(
            session: session,
            sessionName: sessionName,
            window: window,
            windowIndex: window,
            pane: pane,
            command: "claude",
            status: status,
            arguments: ["claude"])
    }

    private func installedTmuxHost(
        sockets: [String] = ["work"],
        version: String = "\(HostHelperCompatibility.bundled)"
    ) async throws -> ScriptedTmuxHost {
        let tmux = ScriptedTmuxHost(sockets: sockets, kernel: "Linux")
        let installer = HostHelperInstaller(host: tmux.helper)
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: version))
        await tmux.helper.configure { $0.clearLog() }
        return tmux
    }

    private func rig(
        _ tmux: ScriptedTmuxHost,
        panes: [TmuxInventory.Pane] = [Self.claude("state=done:app=claude-code:turn=3:blocked=0")]
    ) async throws -> Rig {
        await tmux.setPanes(panes, on: "work")
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(50)))
            })
        console.setHosts([host])
        await console.resume()
        let host = host
        try await waitUntil("the first tmux inventory") { !console.hostsAwaitingSnapshot.contains(host.id) }
        let token = self.token
        let preferences = NotificationPreferencesStore(
            transports: console, deviceToken: { token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.followSeenMarks(of: console)
        preferences.setHosts([host])
        return Rig(tmux: tmux, helper: tmux.helper, console: console, preferences: preferences)
    }

    private func registeredRig(
        panes: [TmuxInventory.Pane] = [Self.claude("state=done:app=claude-code:turn=3:blocked=0")]
    ) async throws -> Rig {
        let rig = try await rig(try await installedTmuxHost(), panes: panes)
        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)
        #expect(isRegistered(rig))
        await rig.helper.configure { $0.clearLog() }
        return rig
    }

    private func isRegistered(_ rig: Rig) -> Bool {
        if case .idle(let settings) = rig.preferences.states[host.id] { return settings.isRegistered }
        return false
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func keyID(for hostID: Host.ID? = nil) throws -> String {
        try #require(try keys.record(forHost: hostID ?? host.id)?.keyID)
    }

    private func markPath(for hostID: Host.ID? = nil) throws -> String {
        "\(Self.directory)/seen-\(try keyID(for: hostID)).json"
    }

    private func id(_ pane: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host.id, paneID: pane)
    }

    private func markWrites(_ helper: ScriptedHelperHost) async -> [String] {
        await helper.writes.map(\.path).filter { ($0 as NSString).lastPathComponent.hasPrefix("seen-") }
    }

    private func entries(_ helper: ScriptedHelperHost) async throws -> [JSONValue] {
        try NotificationRegistrationFile.decode(await helper.files[Self.registrationPath]?.contents).devices
    }

    private func settleWrites(_ rig: Rig) async throws {
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func report(
        _ rig: Rig, pane: Int = 0, _ status: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let mark = UUID().uuidString
        await rig.tmux.changePanes(on: "work") { panes in
            guard let index = panes.firstIndex(where: { $0.paneID == "%\(pane)" }) else { return }
            panes[index].status = status
            panes[index].windowName = mark
        }
        try await waitUntil(
            "pane %\(pane) update",
            { rig.console.terminals.first { $0.paneID == "%\(pane)" }?.tabLabel == mark },
            sourceLocation: sourceLocation)
    }

    // MARK: Registration & session namespace

    @Test(arguments: [("", "tmux/default"), ("  ", "tmux/default"), (" work ", "tmux/work")])
    func aTmuxHostsNotificationSessionNamesItsNormalizedSocketUnderTmux(_ written: String, _ session: String) {
        let host = Host(address: "box.example", username: "dev", serverKind: .tmux, sessionName: written)
        #expect(host.notificationSession == session)
    }

    @Test func turningOnWritesTmuxSocketSessionAndRefreshesStoredPaths() async throws {
        let rig = try await rig(try await installedTmuxHost())
        defer { rig.console.setHosts([]) }
        let pathsFile = "\(Self.directory)/tmux/work/paths.json"
        #expect(await rig.helper.files[pathsFile] == nil)

        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)

        #expect(isRegistered(rig))
        let entries = try await entries(rig.helper)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry["session"] == .string("tmux/work"))
        #expect(entry["token"] == .string(token.hex))
        let config = try NotificationConfigFile.decode(await rig.helper.files[Self.configPath]?.contents)
        #expect(config.relayURL == "https://relay.example")
        let storedPaths = try #require(await rig.helper.files[pathsFile]?.contents)
        #expect(String(decoding: storedPaths, as: UTF8.self).contains(ScriptedTmuxHost.socketPath("work")))
        await #expect(throws: HeelerPluginUnavailableError.self) {
            try await rig.console.withNotificationTransport(for: host.id) { _ in () }
        }
    }

    @Test func aTmuxHostAndACoreHostWithTheSameNameShareRegistrationsWithoutClobbering() async throws {
        let tmux = try await installedTmuxHost(sockets: ["default", "work"])
        await tmux.setPanes([Self.claude("state=idle:app=claude-code:turn=0:blocked=0")], on: "work")
        await tmux.setPanes([Self.claude("state=idle:app=claude-code:turn=0:blocked=0")], on: "default")
        let coreHost = Host(address: "box.example", username: "dev", serverKind: .herdrCore, sessionName: "work")
        let defaultTmuxHost = Host(
            address: "box.example", username: "dev", serverKind: .tmux, sessionName: "",
            tmuxPaths: ScriptedTmuxHost.paths("default"))
        let coreTransport = ScriptedCoreTransport(
            subscribeResults: [.object(["seq": .number(1), "channel": .number(1), "terminals": .array([])])],
            helper: tmux.helper)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectCore: { _ in coreTransport },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { coreTransport }, keepalive: nil) },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    keepalive: nil)
            })
        let allHosts = [coreHost, host, defaultTmuxHost]
        console.setHosts(allHosts)
        await console.resume()
        defer { console.setHosts([]) }
        try await waitUntil("all three Hosts to load") { console.hostsAwaitingSnapshot.isEmpty }

        let token = self.token
        let preferences = NotificationPreferencesStore(
            transports: console, deviceToken: { token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts(allHosts)
        await preferences.refresh()

        await preferences.setNotificationsEnabled(true, for: coreHost)
        await preferences.setNotificationsEnabled(true, for: host)
        await preferences.setNotificationsEnabled(true, for: defaultTmuxHost)

        let registeredSessions = Set(
            try await entries(tmux.helper).compactMap { entry -> String? in
                guard case .string(let session)? = entry["session"] else { return nil }
                return session
            })
        #expect(registeredSessions == ["work", "tmux/work", "tmux/default"])

        await preferences.setNotificationsEnabled(false, for: host)

        let remainingSessions = Set(
            try await entries(tmux.helper).compactMap { entry -> String? in
                guard case .string(let session)? = entry["session"] else { return nil }
                return session
            })
        #expect(remainingSessions == ["work", "tmux/default"])
    }

    @Test func resolvingTmuxPathsDuringARegistrationReadKeepsTheReadAlive() async throws {
        let tmux = try await installedTmuxHost()
        await tmux.setPanes([Self.claude("state=idle:app=claude-code:turn=0:blocked=0")], on: "work")
        let unresolved = Host(
            id: host.id, name: "box", address: "box.example", username: "dev",
            serverKind: .tmux, sessionName: "work", tmuxPaths: nil)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    keepalive: nil)
            })
        console.setHosts([unresolved])
        await console.resume()
        defer { console.setHosts([]) }
        try await waitUntil("the inventory") { !console.hostsAwaitingSnapshot.contains(unresolved.id) }

        let hold = TmuxFileAccessHold()
        await hold.close()
        let token = self.token
        let preferences = NotificationPreferencesStore(
            transports: HeldTmuxNotificationFiles(provider: console, hold: hold),
            deviceToken: { token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts([unresolved])
        let load = Task { await preferences.refresh() }
        try await waitUntil("the read to start") { preferences.states[unresolved.id] == .loading }

        var resolved = unresolved
        resolved.tmuxPaths = ScriptedTmuxHost.paths("work")
        preferences.setHosts([resolved])

        await hold.open()
        await load.value

        if case .idle = preferences.states[unresolved.id] {
            // Expected: resolving tmuxPaths did not cancel or drop the registration read.
        } else {
            Issue.record("Expected .idle after resolving tmuxPaths, got \(String(describing: preferences.states[unresolved.id]))")
        }
    }

    // MARK: Banners & Settings

    private func bannerStore(
        _ rig: Rig, preferences: NotificationPreferencesStore? = nil
    ) -> AgentNotificationBannerStore {
        let preferences = preferences ?? rig.preferences
        let store = AgentNotificationBannerStore(
            holdDuration: .milliseconds(5), presentedAgent: { nil },
            triggers: { preferences.confirmedTriggers(for: $0) }, playSound: {})
        store.agentsDidChange(rig.console.agents)
        return store
    }

    @Test func aRegisteredTmuxHostBannersBlockedErrorAndDoneWithSessionWorkspace() async throws {
        let rig = try await registeredRig(
            panes: [Self.claude(sessionName: "api", "state=idle:app=claude-code:turn=0:blocked=0")])
        defer { rig.console.setHosts([]) }
        let store = bannerStore(rig)

        try await report(rig, "state=working:app=claude-code:turn=0:blocked=0")
        store.agentsDidChange(rig.console.agents)
        try await report(rig, "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1")
        store.agentsDidChange(rig.console.agents)
        try await waitUntil("the Blocked banner") { store.banner != nil }
        #expect(store.banner?.alert.title == "api · Claude")
        #expect(store.banner?.alert.body == "Blocked — waiting for input")
        store.dismiss()

        try await report(rig, "state=error:app=claude-code:turn=0:blocked=1")
        store.agentsDidChange(rig.console.agents)
        try await waitUntil("the Error banner") { store.banner != nil }
        #expect(store.banner?.target == AgentNotificationTarget(hostID: host.id, paneID: "%0"))
        #expect(store.banner?.alert.body == "Error")
        store.dismiss()

        try await report(rig, "state=working:app=claude-code:turn=0:blocked=1")
        store.agentsDidChange(rig.console.agents)
        try await report(rig, "state=done:app=claude-code:turn=1:blocked=1")
        store.agentsDidChange(rig.console.agents)
        try await waitUntil("the Done banner") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done")
    }

    @Test func aBannerDueDuringAReReadOfARegisteredTmuxHostStillShows() async throws {
        let rig = try await registeredRig(
            panes: [Self.claude(sessionName: "api", "state=idle:app=claude-code:turn=0:blocked=0")])
        defer { rig.console.setHosts([]) }
        let hold = TmuxFileAccessHold()
        let token = self.token
        let preferences = NotificationPreferencesStore(
            transports: HeldTmuxNotificationFiles(provider: rig.console, hold: hold),
            deviceToken: { token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts([host])
        await preferences.refresh()
        #expect(preferences.confirmedTriggers(for: host.id) != nil)
        let store = bannerStore(rig, preferences: preferences)

        await hold.close()
        let reread = Task { await preferences.refresh() }
        try await waitUntil("the re-read to begin") { preferences.states[host.id] == .loading }

        try await report(rig, "state=working:app=claude-code:turn=0:blocked=0")
        store.agentsDidChange(rig.console.agents)
        try await report(rig, "state=error:app=claude-code:turn=0:blocked=0")
        store.agentsDidChange(rig.console.agents)

        try await waitUntil("the Error banner during re-read") { store.banner != nil }
        #expect(store.banner?.alert.body == "Error")
        #expect(preferences.liveActivityGate(forCoreHost: host.id) == .unknown)

        await hold.open()
        await reread.value
    }

    @Test func aTmuxHostSettingsModelExposesHelperAndLiveActivityGates() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        let hostStore = HostStore(volatileHosts: [host])
        #expect(hostStore.supportsLiveActivities(for: host.id))
        #expect(rig.preferences.offersLiveActivity(for: host))
        #expect(rig.preferences.coreLiveActivityGates[host.id] == .open)

        let suite = "tmux-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = HostLiveActivityCoordinator(
            controller: FakeLiveActivityController(),
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: rig.console,
            keys: keys,
            deviceToken: { [token] in token },
            knownHostIDs: { [host.id] },
            hostDisplayName: { _ in "box" },
            isAwaitingSnapshot: { _ in false },
            connectionStatus: { _ in .connected })
        let settings = HostNotificationSettings(
            host: host,
            preferences: rig.preferences,
            liveActivities: coordinator,
            pluginStatuses: HeelerPluginStatusStore(),
            openHostHelper: nil)
        #expect(settings.helper != nil)
        #expect(settings.offersLiveActivity)
    }

    // MARK: Live Activity

    private func coordinator(
        _ rig: Rig,
        hostStore: HostStore,
        preferences: NotificationPreferencesStore? = nil,
        controller: FakeLiveActivityController,
        connectionStatus: (@MainActor (Host.ID) -> EventsSessionStatus?)? = nil
    ) throws -> HostLiveActivityCoordinator {
        let suite = "tmux-activity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let console = rig.console
        let registrations = preferences ?? rig.preferences
        let token = token
        let coordinator = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: console,
            keys: keys,
            ceremony: NotificationRegistrationCeremony(
                keys: keys,
                hostSession: { [weak hostStore] id in
                    hostStore?.hosts.first(where: { $0.id == id })?.notificationSession
                }),
            deviceToken: { token },
            knownHostIDs: { [weak hostStore] in Set(hostStore?.hosts.map(\.id) ?? []) },
            hostDisplayName: { _ in "box" },
            isAwaitingSnapshot: { console.hostsAwaitingSnapshot.contains($0) },
            connectionStatus: connectionStatus ?? { console.hostStatuses[$0] },
            supportsHost: { [weak hostStore] id in hostStore?.supportsLiveActivities(for: id) ?? false },
            registrationGate: { [weak hostStore, weak registrations] id in
                let kind = hostStore?.hosts.first(where: { $0.id == id })?.serverKind
                guard kind == .herdrCore || kind == .tmux else { return .open }
                return registrations?.liveActivityGate(forCoreHost: id) ?? .unknown
            },
            settleDuration: .milliseconds(5))
        coordinator.setEnabled(true, for: host.id)
        coordinator.start()
        return coordinator
    }

    private func finish(
        _ coordinator: HostLiveActivityCoordinator, _ controller: FakeLiveActivityController
    ) async {
        await coordinator.stop()
        controller.finishStreams()
    }

    @Test func aRegisteredTmuxHostGetsAnActivityWithSessionWorkspaceAndTokenInHelperDirectory() async throws {
        let rig = try await registeredRig(
            panes: [Self.claude(sessionName: "api", "state=working:app=claude-code:turn=1:blocked=0")])
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        let hostStore = HostStore(volatileHosts: [host])
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, hostStore: hostStore, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the Live Activity") { !controller.requestedHandles.isEmpty }
        let handle = try #require(controller.requestedHandles.first)
        #expect(handle.hostID == host.id)
        let content = try #require(controller.requested.first)
        #expect(content.counts == .init(working: 1, blocked: 0, done: 0))

        let key = try #require(try keys.record(forHost: host.id)?.key)
        let opened = try AgentActivityEnvelope.open(JSONEncoder().encode(content.envelope), using: key)
        #expect(opened.agents.count == 1)
        #expect(opened.agents.first?.workspace == "api")
        #expect(opened.agents.first?.paneID == "%0")

        controller.emitToken(id: handle.id, Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89]))
        try await waitUntil("the Live Activity token in notifications.json") {
            guard let entry = (try? await entries(rig.helper))?.first,
                entry["session"] == .string("tmux/work"),
                case .object(let live)? = entry["live_activity"],
                case .string(let hex)? = live["token"]
            else { return false }
            return hex == "abcdef0123456789"
        }

        await finish(coordinator, controller)
    }

    @Test func anUnregisteredTmuxHostGetsNoActivityAndTurningOffWhileStoppedEndsIt() async throws {
        let unregisteredRig = try await rig(
            try await installedTmuxHost(),
            panes: [Self.claude("state=working:app=claude-code:turn=1:blocked=0")])
        defer { unregisteredRig.console.setHosts([]) }
        try keys.save(NotificationKeyRecord(
            hostID: host.id, hostName: host.displayName, key: NotificationKeyStore.generateKey()))
        await unregisteredRig.preferences.refresh()
        let hostStore = HostStore(volatileHosts: [host])
        let unregisteredController = FakeLiveActivityController()
        let unregisteredCoordinator = try coordinator(
            unregisteredRig, hostStore: hostStore, controller: unregisteredController)
        unregisteredCoordinator.agentsDidChange(unregisteredRig.console.agents)
        try await settleWrites(unregisteredRig)
        #expect(unregisteredController.requestedHandles.isEmpty)
        await finish(unregisteredCoordinator, unregisteredController)

        // Now register and verify turning off while the tmux server is stopped ends the activity.
        await unregisteredRig.preferences.setNotificationsEnabled(true, for: host)
        await unregisteredRig.preferences.refresh()
        let activeController = FakeLiveActivityController()
        let connection = TmuxConnectionBox()
        let activeCoordinator = try coordinator(
            unregisteredRig, hostStore: hostStore, controller: activeController,
            connectionStatus: { _ in connection.status })
        activeCoordinator.agentsDidChange(unregisteredRig.console.agents)
        try await waitUntil("the activity") { !activeController.requestedHandles.isEmpty }

        connection.status = .reconnecting(attempt: 1, delay: .seconds(1), failure: Self.stoppedServer)
        activeCoordinator.connectionsDidChange()
        activeCoordinator.registrationsDidChange()
        try await settleWrites(unregisteredRig)
        #expect(activeController.ended.isEmpty)

        await unregisteredRig.preferences.setNotificationsEnabled(false, for: host)
        activeCoordinator.registrationsDidChange()
        try await waitUntil("the activity end") { !activeController.ended.isEmpty }
        await finish(activeCoordinator, activeController)
    }

    // MARK: Seen marks, server replacement & stopped server

    @Test func openingAnAgentAndEndingATurnWhileOpenWriteSeenMarksForTheServerInstance() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }

        rig.console.setAgentShown(id("%0"), viewer: viewer, scene: window)

        let path = try markPath()
        try await waitUntil("the initial seen mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper) == [path])
        let expectedCore = "tmux-\(ScriptedTmuxHost.instance.pid)-\(ScriptedTmuxHost.instance.startTime)"
        let initial = (await rig.helper.files[path]?.contents).map { String(decoding: $0, as: UTF8.self) }
        #expect(
            initial
                == #"{"core":"\#(expectedCore)","device":"\#(try keyID())","marks":[{"terminal":"%0","turn":3,"word":"done"}],"v":1}"#)

        await rig.helper.configure { $0.clearLog() }
        try await report(rig, "state=working:app=claude-code:turn=3:blocked=0")
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)

        try await report(rig, "state=done:app=claude-code:turn=4:blocked=0")
        try await waitUntil("the updated seen mark") {
            let contents = await rig.helper.files[path]?.contents ?? Data()
            return String(decoding: contents, as: UTF8.self).contains(#""turn":4"#)
        }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper) == [path])
    }

    @Test func turningOnWritesWhatThisDeviceAlreadySawOnTheTmuxHost() async throws {
        let rig = try await rig(try await installedTmuxHost())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        rig.console.setAgentShown(id("%0"), viewer: viewer, scene: window)
        try await waitUntil("%0 read as seen") { rig.console.agents.first?.agent.status == .idle }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)

        await rig.preferences.setNotificationsEnabled(true, for: host)

        let path = try markPath()
        try await waitUntil("the seen mark on registration") { await rig.helper.files[path] != nil }
        let contents = try #require(await rig.helper.files[path]?.contents)
        #expect(String(decoding: contents, as: UTF8.self).contains(#""terminal":"%0","turn":3,"word":"done""#))
    }

    @Test func replacingTheTmuxServerInstanceResetsSeenMarksForTheNewInstance() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("%0"), viewer: viewer, scene: window)
        let path = try markPath()
        try await waitUntil("the initial seen mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)

        let next = TmuxServerInstance(pid: 9001, startTime: 1_800_000_000)
        await rig.tmux.startServer(
            "work", instance: next, panes: [Self.claude("state=done:app=claude-code:turn=1:blocked=0")])

        try await waitUntil("the replaced server's Done") {
            rig.console.agents.first?.agent.status == .done
        }
        try await waitUntil("the replaced server's seen-mark reset") {
            let contents = await rig.helper.files[path]?.contents ?? Data()
            return String(decoding: contents, as: UTF8.self)
                == #"{"core":"tmux-9001-1800000000","device":"\#((try? keyID()) ?? "")","marks":[],"v":1}"#
        }
    }

    @Test func removingAHostWhoseTmuxServerIsStoppedRevokesRegistrationAndRemovesSeenMarks() async throws {
        let tmux = try await installedTmuxHost()
        await tmux.stopServer("work")
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .seconds(60), multiplier: 1, maxDelay: .seconds(60)),
                    keepalive: nil)
            })
        console.setHosts([host])
        await console.resume()
        defer { console.setHosts([]) }
        let host = host
        try await waitUntil("stopped-server reconnect") {
            if case .reconnecting(_, _, .tmuxServerNotRunning) = console.hostStatuses[host.id] {
                return true
            }
            return false
        }
        #expect(console.canReachNotificationFiles(host.id))

        let token = token
        let preferences = NotificationPreferencesStore(
            transports: console, deviceToken: { token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts([host])
        await preferences.refresh()
        await preferences.setNotificationsEnabled(true, for: host)
        #expect(preferences.confirmedTriggers(for: host.id) != nil)
        let path = try markPath()
        await tmux.helper.seedFile(path, Data("{}".utf8))

        let suite = "tmux-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostStore = HostStore(volatileHosts: [host])
        let liveActivities = HostLiveActivityCoordinator(
            controller: FakeLiveActivityController(),
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: console,
            keys: keys,
            deviceToken: { token },
            knownHostIDs: { Set(hostStore.hosts.map(\.id)) },
            hostDisplayName: { _ in host.displayName },
            isAwaitingSnapshot: { _ in false },
            connectionStatus: { console.hostStatuses[$0] })
        let dependencies = HostRemovalDependencies.app(
            console: console, notificationPreferences: preferences, liveActivities: liveActivities)
        let removal = HostRemovalStore(store: hostStore)

        removal.requestRemoval([host.id], dependencies: dependencies)
        let request = try #require(removal.pendingRequest)
        #expect(!request.leavesNotificationsBehind)
        await removal.confirmRemoval(request, dependencies: dependencies)

        #expect(try await entries(tmux.helper).isEmpty)
        #expect(await tmux.helper.files[path] == nil)
    }

    @Test func aStoppedTmuxServersRetriesDoNotReReadRegistrations() async throws {
        let first = EventsSessionStatus.reconnecting(attempt: 1, delay: .seconds(1), failure: Self.stoppedServer)
        let later = EventsSessionStatus.reconnecting(attempt: 8, delay: .seconds(30), failure: Self.stoppedServer)
        #expect(first.forRegistrationRead == later.forRegistrationRead)

        let tmux = try await installedTmuxHost()
        await tmux.stopServer("work")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeTmuxSession: { _ in
                TmuxHostSession(
                    storedPaths: ScriptedTmuxHost.paths("work"),
                    connect: { _ in
                        attempts.withLock { $0 += 1 }
                        throw Self.stoppedServer
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(5), multiplier: 1, maxDelay: .milliseconds(5)),
                    keepalive: nil)
            })
        defer { console.setHosts([]) }
        let registration = PushRegistrationStore(client: ScriptedPushRegistrationClient(), environment: .sandbox)
        registration.deviceTokenDidArrive(Data([0x0A, 0x1B, 0x2C, 0x3D]))
        let app = HeelerAppModel(
            pushRegistration: registration, sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [host]), console: console)
        app.start()
        let host = host
        try await waitUntil("the first read") {
            switch app.notificationPreferences.states[host.id] {
            case .idle, .unavailable: true
            default: false
            }
        }
        try await waitUntil("the tmux session to retry") {
            if case .reconnecting = console.hostStatuses[host.id] { return true }
            return false
        }
        let probesBefore = await tmux.helper.steps.filter { $0 == .probe }.count
        let attemptsBefore = attempts.withLock { $0 }

        try await waitUntil("twenty more retries") { attempts.withLock { $0 } >= attemptsBefore + 20 }

        #expect(await tmux.helper.steps.filter { $0 == .probe }.count <= probesBefore + 1)
    }
}

@MainActor
private final class TmuxConnectionBox {
    var status: EventsSessionStatus? = .connected
}

private actor TmuxFileAccessHold {
    private var isClosed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func close() { isClosed = true }

    func open() {
        isClosed = false
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    func pass() async {
        guard isClosed else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private struct HeldTmuxNotificationFiles: NotificationTransportProvider {
    let provider: any NotificationTransportProvider
    let hold: TmuxFileAccessHold

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID, _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        await hold.pass()
        return try await provider.withNotificationTransport(for: hostID, operation)
    }

    func withNotificationFiles<Value: Sendable>(
        for hostID: Host.ID, _ operation: @escaping @Sendable (any HostNotificationFiles) async throws -> Value
    ) async throws -> Value {
        await hold.pass()
        return try await provider.withNotificationFiles(for: hostID, operation)
    }
}
