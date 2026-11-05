import Foundation
import Testing
import os

@testable import Heeler

/// Agent Notifications on a herdr-core Host (ADR 0033): this device's registration
/// and seen marks live in the Host Helper's directory, through the real Console and
/// preferences stores over a scripted core and an in-memory Host.
@MainActor
@Suite("Agent Notifications through the Host Helper", .timeLimit(.minutes(1)))
struct HostHelperNotificationsTests {
    private static let directory = ScriptedHelperHost.helperDirectory
    private static let registrationPath = "\(directory)/notifications.json"
    private static let configPath = "\(directory)/notify.json"
    private static let relay = URL(string: "https://relay.example")

    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore, sessionName: "  work ")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let keys = NotificationKeyStore(secrets: InMemorySecretStore(), mirror: nil)
    private let viewer = UUID()
    private let window = UUID()

    /// One live core Host with both stores following it, as the app has them.
    private struct Rig {
        let helper: ScriptedHelperHost
        let core: ScriptedCoreTransport
        let console: ConsoleStore
        let preferences: NotificationPreferencesStore
    }

    private static func record(_ address: String, state: String, turn: Int) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7), "name": .null, "reason": .null,
            "labels": .object([:]), "turn": .number(Double(turn)), "reported": .bool(true),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string(state), "app": .string("claude-code")]),
        ])
    }

    private static func frame(seq: Int, type: String, _ terminal: String, _ data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(seq)), "type": .string(type), "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    /// A Host with a working Helper of `version`.
    private func installedHelper(version: String = "\(HostHelperCompatibility.bundled)") async throws -> ScriptedHelperHost {
        let helper = ScriptedHelperHost()
        let installer = HostHelperInstaller(host: helper)
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: version))
        await helper.configure { $0.clearLog() }
        return helper
    }

    private func rig(_ helper: ScriptedHelperHost) async throws -> Rig {
        let core = ScriptedCoreTransport(
            subscribeResults: [
                .object([
                    "seq": .number(1), "channel": .number(1),
                    "terminals": .array([Self.record("t1", state: "done", turn: 3)]),
                ])
            ],
            helper: helper)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectCore: { _ in core },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { core }, keepalive: nil) })
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the first snapshot") { !console.hostsAwaitingSnapshot.contains(host.id) }
        let token = self.token
        let preferences = NotificationPreferencesStore(
            transports: console, deviceToken: { token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.followSeenMarks(of: console)
        preferences.setHosts([host])
        return Rig(helper: helper, core: core, console: console, preferences: preferences)
    }

    /// A rig with this device registered on its Helper, and a clean log.
    private func registeredRig() async throws -> Rig {
        let rig = try await rig(try await installedHelper())
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

    private func keyID() throws -> String {
        try #require(try keys.record(forHost: host.id)?.keyID)
    }

    private func markPath() throws -> String {
        "\(Self.directory)/seen-\(try keyID()).json"
    }

    private func id(_ address: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host.id, paneID: address)
    }

    private func markWrites(_ helper: ScriptedHelperHost) async -> [String] {
        await helper.writes.map(\.path).filter { ($0 as NSString).lastPathComponent.hasPrefix("seen-") }
    }

    private func entries(_ helper: ScriptedHelperHost) async throws -> [JSONValue] {
        try NotificationRegistrationFile.decode(await helper.files[Self.registrationPath]?.contents).devices
    }

    private func requirement(_ rig: Rig) -> String? {
        rig.preferences.helperRequirement(for: host.id)
    }

    private func unavailableMessage(_ rig: Rig) -> String? {
        if case .unavailable(let message) = rig.preferences.states[host.id] { return message }
        return nil
    }

    /// Lets a write the store may have started run to its end.
    private func settleWrites(_ rig: Rig) async throws {
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Registration

    @Test func turningOnWritesThisDevicesEntryInTheHelperDirectoryForTheNormalizedSession() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)

        #expect(isRegistered(rig))
        let entries = try await entries(rig.helper)
        #expect(entries.count == 1)
        guard case .object(let entry)? = entries.first else {
            Issue.record("No entry in the Helper's file")
            return
        }
        #expect(entry["session"] == .string("work"))
        #expect(entry["token"] == .string(token.hex))
        let config = try NotificationConfigFile.decode(await rig.helper.files[Self.configPath]?.contents)
        #expect(config.relayURL == "https://relay.example")
        // Nothing the plugin reads: everything landed in the Helper's directory.
        #expect(await rig.helper.writes.map(\.path).allSatisfy { $0.hasPrefix(Self.directory + "/") })
        #expect(await rig.helper.reads.allSatisfy { $0.hasPrefix(Self.directory + "/") })
        await #expect(throws: HeelerPluginUnavailableError.self) {
            try await rig.console.withNotificationTransport(for: host.id) { _ in () }
        }
    }

    /// The folder name the Helper follows, which is never empty.
    @Test(arguments: [("", "default"), ("  ", "default"), (" work ", "work")])
    func aCoreHostsNotificationSessionIsItsCoreSessionsFolderName(_ written: String, _ folder: String) {
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore, sessionName: written)
        #expect(host.notificationSession == folder)
    }

    @Test func aFileAlreadyInTheHelperDirectoryReadsAsThisDevicesRegistration() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        #expect(isRegistered(rig))
        #expect(requirement(rig) == nil)
    }

    @Test func turningOnFailsWithTheHelpersWordsWhenItWentAwayMeanwhile() async throws {
        let helper = try await installedHelper()
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        await helper.configure {
            $0.node = .missing
            $0.activeState = "failed"
        }

        await rig.preferences.setNotificationsEnabled(true, for: host)

        #expect(try await entries(helper).isEmpty)
        guard case .failed(let message, _)? = rig.preferences.states[host.id] else {
            Issue.record("Expected the failure to show, got \(String(describing: rig.preferences.states[host.id]))")
            return
        }
        #expect(message.contains("Node.js Missing"))
    }

    // MARK: Banners

    /// A banner store fed from the Console as the app feeds it, on the rig's triggers.
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

    private func report(_ rig: Rig, seq: Int, _ state: String) async {
        await rig.core.deliver(Self.frame(
            seq: seq, type: "status", "t1",
            .object([
                "status": .object(["state": .string(state), "app": .string("claude-code")]),
                "records": .object([:]), "reported": .bool(true),
            ])))
    }

    /// Lets `store` hear each status `t1` moves through, up to `status`.
    private func follow(
        _ rig: Rig, into store: AgentNotificationBannerStore, until status: AgentStatus
    ) async throws {
        try await waitUntil("\(status.rawValue) to reach the Console") {
            store.agentsDidChange(rig.console.agents)
            return rig.console.agents.first?.agent.status == status
        }
    }

    private func expectNoBanner(_ store: AgentNotificationBannerStore) async throws {
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.banner == nil)
    }

    @Test func aRegisteredCoreHostBannersBlockedErrorAndDone() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let store = bannerStore(rig)

        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 3, "blocked")
        try await follow(rig, into: store, until: .blocked)
        try await waitUntil("the Blocked banner") { store.banner != nil }
        #expect(store.banner?.alert.body == "Blocked — waiting for input")
        store.dismiss()

        await report(rig, seq: 4, "error")
        try await follow(rig, into: store, until: .error)
        try await waitUntil("the Error banner") { store.banner != nil }
        #expect(store.banner?.target == AgentNotificationTarget(hostID: host.id, paneID: "t1"))
        #expect(store.banner?.alert.body == "Error")
        store.dismiss()

        await report(rig, seq: 5, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 6, "done")
        try await follow(rig, into: store, until: .done)
        try await waitUntil("the Done banner") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done")
    }

    @Test func anOpenAgentsDoneMakesNoBanner() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        try await waitUntil("t1 read as seen") { rig.console.agents.first?.agent.status == .idle }
        let store = bannerStore(rig)

        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        // The Program Status says done, but this device saw the turn end.
        await report(rig, seq: 3, "done")
        try await follow(rig, into: store, until: .idle)

        try await expectNoBanner(store)
    }

    @Test func doneNotificationsOffMakesNoDoneBannerWhileErrorStillShows() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.preferences.setDoneEnabled(false, for: host)
        let store = bannerStore(rig)

        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 3, "done")
        try await follow(rig, into: store, until: .done)
        try await expectNoBanner(store)

        await report(rig, seq: 4, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 5, "error")
        try await follow(rig, into: store, until: .error)
        try await waitUntil("the Error banner") { store.banner != nil }
    }

    @Test func aCoreHostWithoutARegistrationGetsNoBanner() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        #expect(!isRegistered(rig))
        let store = bannerStore(rig)

        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 3, "error")
        try await follow(rig, into: store, until: .error)
        try await expectNoBanner(store)

        await report(rig, seq: 4, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 5, "done")
        try await follow(rig, into: store, until: .done)
        try await expectNoBanner(store)
    }

    @Test func aCoreHostWithoutTheHelperGetsNoBanner() async throws {
        let rig = try await rig(ScriptedHelperHost())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        let store = bannerStore(rig)

        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 3, "error")
        try await follow(rig, into: store, until: .error)
        try await expectNoBanner(store)
    }

    // MARK: A re-read of a registration

    /// A preferences store whose reads and writes can be held at the door.
    private func heldPreferences(
        over provider: any NotificationTransportProvider, hold: FileAccessHold
    ) -> NotificationPreferencesStore {
        let token = token
        return NotificationPreferencesStore(
            transports: HeldNotificationFiles(provider: provider, hold: hold), deviceToken: { token },
            relayBaseURL: { Self.relay }, ceremony: NotificationRegistrationCeremony(keys: keys))
    }

    @Test func aBannerDueDuringAReReadOfARegisteredHostStillShows() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let hold = FileAccessHold()
        let preferences = heldPreferences(over: rig.console, hold: hold)
        preferences.setHosts([host])
        await preferences.refresh()
        #expect(preferences.confirmedTriggers(for: host.id) != nil)
        let store = bannerStore(rig, preferences: preferences)

        await hold.close()
        let reread = Task { await preferences.refresh() }
        try await waitUntil("the re-read to begin") { preferences.states[host.id] == .loading }
        await report(rig, seq: 2, "working")
        try await follow(rig, into: store, until: .working)
        await report(rig, seq: 3, "error")
        try await follow(rig, into: store, until: .error)

        try await waitUntil("the Error banner") { store.banner != nil }
        #expect(store.banner?.alert.body == "Error")
        // Only the banner's gate holds: the toggles wait for the read.
        #expect(preferences.liveActivityGate(forCoreHost: host.id) == .unknown)
        #expect(preferences.helperRequirement(for: host.id) == nil)

        await hold.open()
        await reread.value
    }

    @Test func aReReadThatFindsTheRegistrationGoneClosesTheBannerGate() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let hold = FileAccessHold()
        let preferences = heldPreferences(over: rig.console, hold: hold)
        preferences.setHosts([host])
        await preferences.refresh()

        await hold.close()
        let reread = Task { await preferences.refresh() }
        try await waitUntil("the re-read to begin") { preferences.states[host.id] == .loading }
        await rig.preferences.setNotificationsEnabled(false, for: host)
        await hold.open()
        await reread.value

        #expect(preferences.confirmedTriggers(for: host.id) == nil)
    }

    @Test func aFirstReadStillFailsClosed() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let hold = FileAccessHold()
        await hold.close()
        let preferences = heldPreferences(over: rig.console, hold: hold)
        preferences.setHosts([host])

        let read = Task { await preferences.refresh() }
        try await waitUntil("the read to begin") { preferences.states[host.id] == .loading }
        #expect(preferences.confirmedTriggers(for: host.id) == nil)

        await hold.open()
        await read.value
    }

    /// A removal during a read is not undone by what that read still holds.
    @Test func forgettingTheKeyDuringAReReadClosesTheBannerGate() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let hold = FileAccessHold()
        let preferences = heldPreferences(over: rig.console, hold: hold)
        preferences.setHosts([host])
        await preferences.refresh()

        await hold.close()
        let reread = Task { await preferences.refresh() }
        try await waitUntil("the re-read to begin") { preferences.states[host.id] == .loading }
        try preferences.forgetNotificationKey(for: host.id)
        #expect(preferences.confirmedTriggers(for: host.id) == nil)

        await hold.open()
        await reread.value
    }

    /// Herdr TUI's gate fails closed for its read, as it always has.
    @Test func aHerdrTUIHostsBannerGateStillFailsClosedDuringAReRead() async throws {
        let host = Host.fixture()
        let token = token
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let ceremony = NotificationRegistrationCeremony(keys: keys)
        try await ceremony.register(host: host, deviceToken: token, over: transport)
        let hold = FileAccessHold()
        let preferences = NotificationPreferencesStore(
            transports: HeldNotificationFiles(
                provider: ScriptedTransportProvider(transports: [host.id: transport]), hold: hold),
            deviceToken: { token }, ceremony: ceremony)
        preferences.setHosts([host])
        await preferences.refresh()
        #expect(preferences.confirmedTriggers(for: host.id) != nil)

        await hold.close()
        let reread = Task { await preferences.refresh() }
        try await waitUntil("the re-read to begin") { preferences.states[host.id] == .loading }
        #expect(preferences.confirmedTriggers(for: host.id) == nil)

        await hold.open()
        await reread.value
    }

    // MARK: What can drive an activity

    @Test func aNewerHelperThatFailedClosesBothGates() async throws {
        let helper = try await installedHelper(version: "9.9.9")
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)
        await rig.preferences.refresh()
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .open)

        await helper.configure {
            $0.activeState = "failed"
            $0.result = "start-limit-hit"
        }
        await rig.preferences.refresh()

        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
        #expect(!rig.preferences.offersLiveActivity(for: host))
    }

    @Test func aNewerHelperThatFailedTakesNoNewRegistration() async throws {
        let helper = try await installedHelper(version: "9.9.9")
        await helper.configure {
            $0.activeState = "failed"
            $0.result = "start-limit-hit"
        }
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        #expect(try #require(unavailableMessage(rig)).hasPrefix("Host Helper: Service Failed."))
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
    }

    @Test func aUserManagerNobodyCanReachWithLingerOffClosesTheActivityGate() async throws {
        let helper = try await installedHelper()
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)
        await rig.preferences.refresh()
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .open)

        await helper.configure {
            $0.userManagerReachable = false
            $0.lingerOn = false
        }
        await rig.preferences.refresh()

        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
    }

    @Test func removingTheHelperFromHostDetailClosesBothGatesWhileTheConsoleStaysConnected() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        #expect(rig.preferences.confirmedTriggers(for: host.id) != nil)
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .open)
        let helperHost = ScriptedCoreHost(helper: rig.helper, channel: .refused)
        let bundle = HostHelperFixture.bundle()
        let store = HostHelperStore(connect: { helperHost.transport() }, bundle: { bundle })
        let preferences = rig.preferences
        store.onChanged = { Task { await preferences.refresh() } }
        await store.refresh()

        await store.remove()

        try await waitUntil("the gates to close") {
            preferences.confirmedTriggers(for: host.id) == nil
                && preferences.liveActivityGate(forCoreHost: host.id) == .closed
        }
        #expect(rig.console.hostStatuses[host.id] == .connected)
    }

    // MARK: Live Activity

    /// A coordinator wired to the rig's stores as the app wires them, already started.
    private func coordinator(
        _ rig: Rig, preferences: NotificationPreferencesStore? = nil, controller: FakeLiveActivityController,
        connectionStatus: (@MainActor (Host.ID) -> EventsSessionStatus?)? = nil
    ) throws -> HostLiveActivityCoordinator {
        let suite = "core-activity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let console = rig.console
        let registrations = preferences ?? rig.preferences
        let token = token
        let host = host
        let coordinator = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: console,
            keys: keys,
            ceremony: NotificationRegistrationCeremony(
                keys: keys, hostSession: { $0 == host.id ? host.notificationSession : nil }),
            deviceToken: { token },
            knownHostIDs: { [host.id] },
            hostDisplayName: { _ in "box" },
            isAwaitingSnapshot: { console.hostsAwaitingSnapshot.contains($0) },
            connectionStatus: connectionStatus ?? { console.hostStatuses[$0] },
            registrationGate: { registrations.liveActivityGate(forCoreHost: $0) },
            settleDuration: .milliseconds(5))
        coordinator.setEnabled(true, for: host.id)
        coordinator.start()
        return coordinator
    }

    private func liveActivityToken(_ helper: ScriptedHelperHost) async throws -> String? {
        guard case .object(let entry)? = try await entries(helper).first,
            case .object(let live)? = entry["live_activity"],
            case .string(let token)? = live["token"]
        else { return nil }
        return token
    }

    private func finish(
        _ coordinator: HostLiveActivityCoordinator, _ controller: FakeLiveActivityController
    ) async {
        await coordinator.stop()
        controller.finishStreams()
    }

    @Test func aRegisteredCoreHostGetsAnActivityWithItsTokenInTheHelperDirectory() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }
        let handle = try #require(controller.requestedHandles.first)
        #expect(handle.hostID == host.id)
        controller.emitToken(id: handle.id, Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89]))
        try await waitUntil("the token") { (try? await liveActivityToken(rig.helper)) == "abcdef0123456789" }

        #expect(await rig.helper.writes.map(\.path).allSatisfy { $0.hasPrefix(Self.directory + "/") })
        await finish(coordinator, controller)
    }

    @Test func aCoreHostsErrorAgentCountsUnderBlockedInItsActivity() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await report(rig, seq: 2, "working")
        await report(rig, seq: 3, "error")
        try await waitUntil("the Error") { rig.console.agents.first?.agent.status == .error }
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }

        #expect(controller.requested.first?.counts == .init(working: 0, blocked: 1, done: 0))
        await finish(coordinator, controller)
    }

    @Test func aCoreHostWithoutTheHelperGetsNoActivity() async throws {
        let rig = try await rig(ScriptedHelperHost())
        defer { rig.console.setHosts([]) }
        // A key left from an earlier registration opens nothing by itself.
        try keys.save(NotificationKeyRecord(
            hostID: host.id, hostName: host.displayName, key: NotificationKeyStore.generateKey()))
        await rig.preferences.refresh()
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
        #expect(!rig.preferences.offersLiveActivity(for: host))
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await settleWrites(rig)

        #expect(controller.requestedHandles.isEmpty)
        #expect(coordinator.reconcileNotes[host.id] == nil)
        await finish(coordinator, controller)
    }

    @Test func aCoreHostWithoutThisDevicesRegistrationGetsNoActivity() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }
        try keys.save(NotificationKeyRecord(
            hostID: host.id, hostName: host.displayName, key: NotificationKeyStore.generateKey()))
        await rig.preferences.refresh()
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await settleWrites(rig)

        #expect(controller.requestedHandles.isEmpty)
        await finish(coordinator, controller)
    }

    @Test func aHelperThatCannotDriveAnActivityGetsNone() async throws {
        let rig = try await rig(try await installedHelper(version: "0.4.0"))
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)
        await rig.preferences.refresh()

        #expect(isRegistered(rig))
        #expect(rig.preferences.confirmedTriggers(for: host.id) != nil)
        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .closed)
        #expect(!rig.preferences.offersLiveActivity(for: host))
        #expect(requirement(rig) == "Host Helper: 0.4.0. Live Activity needs a newer Host Helper. See this Host's page in Hosts.")
    }

    @Test func turningNotificationsOffEndsTheActivity() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, controller: controller)
        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }

        await rig.preferences.setNotificationsEnabled(false, for: host)
        coordinator.registrationsDidChange()

        try await waitUntil("the end") { !controller.ended.isEmpty }
        await finish(coordinator, controller)
    }

    /// The Helper answers with no core running, so turning off succeeds, and it no
    /// longer holds the token that could end the activity later.
    @Test func turningNotificationsOffEndsTheActivityWhileTheCoreIsStopped() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        let controller = FakeLiveActivityController()
        let connection = ConnectionBox()
        let coordinator = try coordinator(rig, controller: controller, connectionStatus: { _ in connection.status })
        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }

        connection.status = .reconnecting(
            attempt: 1, delay: .seconds(1),
            failure: .herdrCoreNotRunning(socketPath: "/run/core.sock", socketFilePresent: false))
        coordinator.connectionsDidChange()
        coordinator.registrationsDidChange()
        try await settleWrites(rig)
        // The Agent list is unknown and the registration stands, so it holds.
        #expect(controller.ended.isEmpty)

        await rig.preferences.setNotificationsEnabled(false, for: host)
        coordinator.registrationsDidChange()

        try await waitUntil("the end") { !controller.ended.isEmpty }
        await finish(coordinator, controller)
    }

    @Test func aRegistrationReadThatFailsKeepsTheActivityWhileTheCoreIsStopped() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        let controller = FakeLiveActivityController()
        let connection = ConnectionBox()
        let coordinator = try coordinator(rig, controller: controller, connectionStatus: { _ in connection.status })
        coordinator.agentsDidChange(rig.console.agents)
        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }

        connection.status = .reconnecting(
            attempt: 1, delay: .seconds(1),
            failure: .herdrCoreNotRunning(socketPath: "/run/core.sock", socketFilePresent: false))
        coordinator.connectionsDidChange()
        rig.console.setHosts([])
        await rig.preferences.refresh()
        coordinator.registrationsDidChange()
        try await settleWrites(rig)

        #expect(rig.preferences.liveActivityGate(forCoreHost: host.id) == .unknown)
        #expect(controller.ended.isEmpty)
        await finish(coordinator, controller)
    }

    /// A launch adopts what ActivityKit kept before the registration has been read.
    @Test func anActivityStaysWhileItsRegistrationIsBeingRead() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let reopened = NotificationPreferencesStore(
            transports: rig.console, deviceToken: { [token] in token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        reopened.setHosts([host])
        #expect(reopened.liveActivityGate(forCoreHost: host.id) == .unknown)
        let controller = FakeLiveActivityController()
        controller.seed(id: "kept", hostID: host.id)
        let coordinator = try coordinator(rig, preferences: reopened, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await settleWrites(rig)
        #expect(controller.ended.isEmpty)
        #expect(controller.updates.isEmpty)

        await reopened.refresh()
        coordinator.registrationsDidChange()

        try await waitUntil("the update") { !controller.updates.isEmpty }
        #expect(controller.ended.isEmpty)
        await finish(coordinator, controller)
    }

    @Test func noActivityStartsUntilTheRegistrationHasBeenRead() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let reopened = NotificationPreferencesStore(
            transports: rig.console, deviceToken: { [token] in token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        reopened.setHosts([host])
        let controller = FakeLiveActivityController()
        let coordinator = try coordinator(rig, preferences: reopened, controller: controller)

        coordinator.agentsDidChange(rig.console.agents)
        try await settleWrites(rig)
        #expect(controller.requestedHandles.isEmpty)

        await reopened.refresh()
        coordinator.registrationsDidChange()

        try await waitUntil("the activity") { !controller.requestedHandles.isEmpty }
        await finish(coordinator, controller)
    }

    /// Waiting on a push token says nothing about the registration.
    @Test func aReadThatCouldNotHappenLeavesTheGateUnknown() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let waiting = NotificationPreferencesStore(
            transports: rig.console, deviceToken: { nil },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        waiting.setHosts([host])

        await waiting.refresh()

        #expect(waiting.liveActivityGate(forCoreHost: host.id) == .unknown)
    }

    // MARK: Seen marks

    @Test func openingAnAgentWritesOneSeenMarkNamedFromTheNotificationKey() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }

        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)

        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper) == [path])
        #expect(!path.contains("t1"))
        let contents = await rig.helper.files[path]?.contents
        #expect(
            contents.map { String(decoding: $0, as: UTF8.self) }
                == #"{"core":"c1","device":"\#(try keyID())","marks":[{"terminal":"t1","turn":3,"word":"done"}],"v":1}"#)
    }

    @Test func aTurnThatEndsWhileAnAgentIsOpenWritesOneSeenMark() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        let path = try markPath()
        try await waitUntil("the mark for opening") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)
        await rig.helper.configure { $0.clearLog() }

        await rig.core.deliver(Self.frame(
            seq: 2, type: "status", "t1",
            .object([
                "status": .object(["state": .string("working"), "app": .string("claude-code")]),
                "records": .object([:]), "reported": .bool(true),
            ])))
        await rig.core.deliver(Self.frame(
            seq: 3, type: "status", "t1",
            .object([
                "status": .object(["state": .string("done"), "app": .string("claude-code")]),
                "records": .object([:]), "reported": .bool(true),
            ])))
        await rig.core.deliver(Self.frame(
            seq: 4, type: "turn", "t1", .object(["turn": .number(4), "state": .string("done")])))

        try await waitUntil("the mark for the turn") {
            let contents = await rig.helper.files[path]?.contents ?? Data()
            return String(decoding: contents, as: UTF8.self).contains(#""turn":4"#)
        }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).allSatisfy { $0 == path })
        #expect(await markWrites(rig.helper).count == 1)
    }

    @Test func aMarkSeenBeforeTheRegistrationIsKnownWaitsForIt() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        await rig.preferences.setNotificationsEnabled(true, for: host)
        let reopened = NotificationPreferencesStore(
            transports: rig.console, deviceToken: { [token] in token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        reopened.followSeenMarks(of: rig.console)
        reopened.setHosts([host])
        await rig.helper.configure { $0.clearLog() }

        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)

        await reopened.refresh()

        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
    }

    @Test func turningOnWritesWhatThisDeviceAlreadySawOnTheHost() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        try await waitUntil("t1 read as seen") { rig.console.agents.first?.agent.status == .idle }
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)

        await rig.preferences.setNotificationsEnabled(true, for: host)

        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
        let contents = try #require(await rig.helper.files[path]?.contents)
        #expect(String(decoding: contents, as: UTF8.self).contains(#""terminal":"t1","turn":3"#))
        try await settleWrites(rig)
        #expect(await markWrites(rig.helper) == [path])
    }

    @Test func turningOffAndOnWritesTheMarksUnderTheNewKey() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        let first = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[first] != nil }
        try await settleWrites(rig)

        await rig.preferences.setNotificationsEnabled(false, for: host)
        #expect(await rig.helper.files[first] == nil)
        await rig.preferences.setNotificationsEnabled(true, for: host)

        let second = try markPath()
        #expect(second != first)
        try await waitUntil("the mark under the new key") { await rig.helper.files[second] != nil }
        #expect(await rig.helper.files[first] == nil)
    }

    @Test func changingTheDoneFlagWritesNoMark() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)
        await rig.helper.configure { $0.clearLog() }

        await rig.preferences.setDoneEnabled(false, for: host)

        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)
    }

    @Test func turningOnWithNothingSeenWritesNoMark() async throws {
        let rig = try await rig(try await installedHelper())
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()

        await rig.preferences.setNotificationsEnabled(true, for: host)

        try await settleWrites(rig)
        #expect(await markWrites(rig.helper).isEmpty)
    }

    @Test func noMarkOnAHostWithoutTheHelper() async throws {
        let helper = ScriptedHelperHost()
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }
        await rig.preferences.refresh()

        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)

        try await settleWrites(rig)
        #expect(await helper.writes.isEmpty)
    }

    @Test func noMarkOnAHostWhoseHelperHoldsNoRegistrationOfThisDevice() async throws {
        let helper = try await installedHelper()
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }
        // A key from an earlier registration is not one.
        try keys.save(NotificationKeyRecord(
            hostID: host.id, hostName: host.displayName, key: NotificationKeyStore.generateKey()))
        await rig.preferences.refresh()
        #expect(unavailableMessage(rig) == nil)
        #expect(!isRegistered(rig))

        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)

        try await settleWrites(rig)
        #expect(await helper.writes.isEmpty)
    }

    // MARK: Leaving

    @Test func turningOffRemovesThisDevicesEntryAndItsMarkFile() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)
        await rig.helper.configure { $0.clearLog() }

        await rig.preferences.setNotificationsEnabled(false, for: host)

        #expect(try await entries(rig.helper).isEmpty)
        #expect(await rig.helper.files[path] == nil)
        // The entry first, so a retry after a failure in between still finds the marks.
        let journal = await rig.helper.journal
        let entryWrite = try #require(journal.firstIndex(of: "write \(Self.registrationPath)"))
        let markRemoval = try #require(journal.firstIndex(of: "removeFiles \(path)"))
        #expect(entryWrite < markRemoval)
    }

    @Test func aMarkAfterTurningOffLeavesNoFileBehind() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        let path = try markPath()

        await rig.preferences.setNotificationsEnabled(false, for: host)
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)

        try await settleWrites(rig)
        #expect(await rig.helper.files[path] == nil)
    }

    @Test func removingAConnectedHostRemovesThisDevicesEntryAndItsMarkFile() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        rig.console.setAgentShown(id("t1"), viewer: viewer, scene: window)
        let path = try markPath()
        try await waitUntil("the mark") { await rig.helper.files[path] != nil }
        try await settleWrites(rig)

        let removal = HostRemovalStore(store: HostStore(volatileHosts: [host]))
        let console = rig.console
        let preferences = rig.preferences
        let dependencies = HostRemovalDependencies(
            isConnected: { console.hostStatuses[$0] == .connected },
            hasNotificationKey: { preferences.hasNotificationKey(for: $0) },
            revokeNotifications: { host in
                await preferences.revokeRegistration(
                    for: host, isConnected: console.hostStatuses[host.id] == .connected)
            },
            forgetNotificationKey: { try preferences.forgetNotificationKey(for: $0) })
        removal.requestRemoval([host.id], dependencies: dependencies)
        let request = try #require(removal.pendingRequest)
        #expect(!request.leavesNotificationsBehind)
        await removal.confirmRemoval(request, dependencies: dependencies)

        #expect(try await entries(rig.helper).isEmpty)
        #expect(await rig.helper.files[path] == nil)
    }

    private nonisolated static let stoppedCore = TransportError.herdrCoreNotRunning(
        socketPath: "/run/core.sock", socketFilePresent: false)

    /// A Console whose session keeps retrying `failure`, while `connectCore` still
    /// reaches the Host for one operation.
    private func unconnectedConsole(_ helper: ScriptedHelperHost, failure: TransportError) async throws -> ConsoleStore {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectCore: { _ in core.transport() },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { throw failure }, keepalive: nil) })
        console.setHosts([host])
        await console.resume()
        let host = host
        try await waitUntil("the session to retry") {
            if case .reconnecting = console.hostStatuses[host.id] { return true }
            return false
        }
        return console
    }

    @Test func removingAHostWhoseCoreIsStoppedRemovesThisDevicesEntryAndItsMarkFile() async throws {
        let helper = try await installedHelper()
        let console = try await unconnectedConsole(helper, failure: Self.stoppedCore)
        defer { console.setHosts([]) }
        let token = token
        let preferences = NotificationPreferencesStore(
            transports: console, deviceToken: { token }, relayBaseURL: { Self.relay },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts([host])
        await preferences.refresh()
        await preferences.setNotificationsEnabled(true, for: host)
        #expect(preferences.confirmedTriggers(for: host.id) != nil)
        let path = try markPath()
        await helper.seedFile(path, Data("{}".utf8))

        let suite = "core-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostStore = HostStore(volatileHosts: [host])
        let host = host
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

        #expect(try await entries(helper).isEmpty)
        #expect(await helper.files[path] == nil)
    }

    /// Anything else short of connected says nothing about the Host being reachable.
    @Test func onlyAStoppedCoreCountsAsAReachableHostShortOfConnected() async throws {
        let unreachable = try await unconnectedConsole(
            ScriptedHelperHost(), failure: .sshUnreachable(detail: "no route"))
        defer { unreachable.setHosts([]) }
        #expect(!unreachable.canReachNotificationFiles(host.id))

        let stopped = try await unconnectedConsole(ScriptedHelperHost(), failure: Self.stoppedCore)
        defer { stopped.setHosts([]) }
        #expect(stopped.canReachNotificationFiles(host.id))
    }

    @Test func aHerdrTUIHostMustBeConnectedForItsFilesToBeReachable() async throws {
        let host = Host.fixture()
        let console = ConsoleStore(makeSession: { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw Self.stoppedCore },
                keepalive: nil)
        })
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the session to settle") {
            console.hostStatuses[host.id] != .connecting
        }
        #expect(!console.canReachNotificationFiles(host.id))
    }

    // MARK: What makes a registration read again

    @Test func aStoppedCoresRetriesAreOneStatusToARegistrationRead() {
        let first = EventsSessionStatus.reconnecting(attempt: 1, delay: .seconds(1), failure: Self.stoppedCore)
        let later = EventsSessionStatus.reconnecting(attempt: 7, delay: .seconds(30), failure: Self.stoppedCore)
        #expect(first.forRegistrationRead == later.forRegistrationRead)
    }

    /// Herdr TUI's offline retries read again as they always have.
    @Test func anotherFailuresRetriesStayDistinctToARegistrationRead() {
        let failure = TransportError.sshUnreachable(detail: "no route")
        let first = EventsSessionStatus.reconnecting(attempt: 1, delay: .seconds(1), failure: failure)
        let later = EventsSessionStatus.reconnecting(attempt: 2, delay: .seconds(2), failure: failure)
        #expect(first.forRegistrationRead != later.forRegistrationRead)
        #expect(first.forRegistrationRead == first)
    }

    @Test func aRealChangeStillReadsAgain() {
        let stopped = EventsSessionStatus.reconnecting(attempt: 1, delay: .seconds(1), failure: Self.stoppedCore)
        let offline = EventsSessionStatus.reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "no route"))
        #expect(stopped.forRegistrationRead != offline.forRegistrationRead)
        #expect(stopped.forRegistrationRead != EventsSessionStatus.connected)
        #expect(EventsSessionStatus.connected.forRegistrationRead == .connected)
    }

    /// Through the app's own observers: retries of one stopped core must not probe
    /// the Helper over and over, for this Host or any other.
    @Test func theAppDoesNotReadEveryRegistrationAgainForEachRetryOfAStoppedCore() async throws {
        let helper = try await installedHelper()
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectCore: { _ in core.transport() },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        attempts.withLock { $0 += 1 }
                        throw Self.stoppedCore
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
        try await waitUntil("the session to retry") {
            if case .reconnecting = console.hostStatuses[host.id] { return true }
            return false
        }
        let probesBefore = await helper.steps.filter { $0 == .probe }.count
        let attemptsBefore = attempts.withLock { $0 }

        try await waitUntil("twenty more retries") { attempts.withLock { $0 } >= attemptsBefore + 20 }

        // The move into reconnecting may be heard after the count above, once.
        #expect(await helper.steps.filter { $0 == .probe }.count <= probesBefore + 1)
    }

    @Test func aDeviceRegisteredOnAHelperThatStoppedWorkingCanStillLeave() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        await rig.helper.configure { $0.node = .missing; $0.activeState = "failed" }

        await rig.preferences.refresh()

        #expect(isRegistered(rig))
        #expect(requirement(rig)?.contains("Node.js Missing") == true)

        await rig.preferences.setNotificationsEnabled(false, for: host)

        #expect(try await entries(rig.helper).isEmpty)
    }

    // MARK: What the settings show

    @Test func aHostWithoutTheHelperAsksForIt() async throws {
        let rig = try await rig(ScriptedHelperHost())
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        let message = try #require(unavailableMessage(rig))
        #expect(message.hasPrefix("Host Helper: Not Installed."))
        #expect(message.contains("See this Host's page in Hosts."))
    }

    @Test func aHostWithoutNodeSaysNodeIsMissing() async throws {
        let helper = ScriptedHelperHost()
        await helper.configure { $0.node = .missing }
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        let message = try #require(unavailableMessage(rig))
        #expect(message.hasPrefix("Host Helper: Node.js Missing."))
    }

    @Test func aServiceThatFailedSaysSo() async throws {
        let helper = try await installedHelper()
        await helper.configure { $0.activeState = "failed"; $0.result = "exit-code" }
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        #expect(try #require(unavailableMessage(rig)).hasPrefix("Host Helper: Service Failed."))
    }

    @Test func anOlderHelperAsksForANewerOne() async throws {
        let rig = try await rig(try await installedHelper(version: "0.3.0"))
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        #expect(try #require(unavailableMessage(rig)) == "Host Helper: 0.3.0. Notifications need a newer Host Helper. See this Host's page in Hosts.")
    }

    @Test func lingerOffLeavesTheTogglesWithANote() async throws {
        let helper = try await installedHelper()
        await helper.configure { $0.lingerOn = false }
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        #expect(unavailableMessage(rig) == nil)
        #expect(requirement(rig)?.hasPrefix("Host Helper: Linger Off.") == true)

        await rig.preferences.setNotificationsEnabled(true, for: host)

        #expect(isRegistered(rig))
        #expect(try await entries(helper).count == 1)
    }

    @Test func aNativeWindowsHostSaysWhatComesWithTheHelper() async throws {
        let helper = ScriptedHelperHost()
        await helper.configure { $0.platform = .nativeWindows }
        let rig = try await rig(helper)
        defer { rig.console.setHosts([]) }

        await rig.preferences.refresh()

        let message = try #require(unavailableMessage(rig))
        #expect(message.contains("Agent Notifications (in-app banners included), Live Activity"))
        #expect(message.contains("not available on native Windows yet because they come with the Host Helper"))
        #expect(await helper.reads.isEmpty)
        #expect(await helper.writes.isEmpty)
    }
}

/// The Host's connection status, for a test to change as it goes.
@MainActor
private final class ConnectionBox {
    var status: EventsSessionStatus? = .connected
}

/// Keeps a store's file access waiting at the door until opened.
private actor FileAccessHold {
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

private struct HeldNotificationFiles: NotificationTransportProvider {
    let provider: any NotificationTransportProvider
    let hold: FileAccessHold

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
