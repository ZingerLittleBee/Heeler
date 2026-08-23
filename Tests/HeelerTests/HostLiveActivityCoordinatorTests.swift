import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Host live activity coordinator")
struct HostLiveActivityCoordinatorTests {
    private let host = Host.fixture(name: "mbp", address: "mbp.local", username: "z")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let secrets = InMemorySecretStore()
    private let controller = FakeLiveActivityController()
    private let transport = ScriptedTransport()
    private let world = World()
    /// Observed-family herdr pane id (alphanumeric `w…:p…`, uppercase
    /// included). This suite treats it as an opaque string; the live shape
    /// keeps the fixtures from re-teaching the retired tmux-style `%N` habit.
    /// Pin cases below keep deliberately fake ids (`w:p-work`) because they
    /// only need a stable opaque token, not a live-shaped address.
    private let observedPaneID = "wV:p1"

    @MainActor
    private final class World {
        var knownHostIDs: Set<UUID> = []
        var hostNames: [UUID: String] = [:]
        var awaitingSnapshot: Set<UUID> = []
        var statuses: [UUID: EventsSessionStatus] = [:]
        var deviceToken: APNSDeviceToken?
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "la-pref-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        enable: Bool = true,
        pins: PinnedAgentsStore? = nil
    ) -> HostLiveActivityCoordinator {
        let keys = NotificationKeyStore(secrets: secrets)
        let world = world
        let pinStore = pins
        let coordinator = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            keys: keys,
            ceremony: NotificationRegistrationCeremony(keys: keys),
            deviceToken: { world.deviceToken },
            knownHostIDs: { world.knownHostIDs },
            hostDisplayName: { world.hostNames[$0] ?? "" },
            isAwaitingSnapshot: { world.awaitingSnapshot.contains($0) },
            connectionStatus: { world.statuses[$0] },
            pinnedPaneIDs: { pinStore?.pinnedPaneIDs(for: $0) ?? [] },
            settleDuration: .milliseconds(20))
        if enable {
            coordinator.setEnabled(true, for: host.id)
        }
        return coordinator
    }

    private func armWorld(token: APNSDeviceToken? = nil) {
        world.knownHostIDs = [host.id]
        world.hostNames[host.id] = "mbp"
        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        world.deviceToken = token ?? self.token
    }

    private func saveKey() throws {
        try NotificationKeyStore(secrets: secrets).save(
            NotificationKeyRecord(
                hostID: host.id, hostName: "mbp", key: NotificationKeyStore.generateKey()))
    }

    private func registerDevice() async throws {
        let keys = NotificationKeyStore(secrets: secrets)
        try await NotificationRegistrationCeremony(keys: keys).register(
            hostID: host.id, hostName: "mbp", deviceToken: token, over: transport)
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus, title: String = "Task"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: "mbp",
            agent: Agent(.fixture(paneID: paneID, status: status, title: title)),
            workspaceLabel: nil, repoName: nil)
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(2),
        condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await condition(), comment)
    }

    private func waitPastSettle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func liveActivityToken() async throws -> String? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(forDeviceToken: token.hex)?.token
    }

    private func filePinnedPaneIDs() async throws -> [String]? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(forDeviceToken: token.hex)?.pinnedPaneIDs
    }

    private func notificationKey() throws -> Data {
        try #require(try NotificationKeyStore(secrets: secrets).record(forHost: host.id)?.key)
    }

    private func openedPaneIDs(_ state: AgentActivityAttributes.ContentState) throws -> [String] {
        let envelope = try #require(state.envelope)
        let details = try AgentActivityEnvelope.open(
            try JSONEncoder().encode(envelope), using: notificationKey())
        return details.agents.map(\.paneID)
    }

    // MARK: Start / settle / flap

    @Test func startsAfterTheSettleNotOnFirstSight() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        #expect(controller.requested.isEmpty, "the desired state must settle first")

        try await waitUntil("a working Agent should start an activity once settled") {
            !controller.requested.isEmpty
        }
        #expect(controller.requested.count == 1)
        #expect(controller.requested[0].counts == .init(working: 1, blocked: 0, done: 0))
    }

    @Test func aFlapBackToTheAppliedDesireDoesNotEnd() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([])
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitPastSettle()

        #expect(controller.ended.isEmpty)
        #expect(controller.requested.count == 1)
        #expect(controller.updates.isEmpty)
    }

    @Test func updateCoalescesToTheLatestDesire() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        try await waitUntil("only the latest desire should land as an update") {
            controller.updates.count == 1
        }
        try await waitPastSettle()
        #expect(controller.updates.count == 1)
        #expect(controller.updates[0].content.counts == .init(working: 0, blocked: 0, done: 1))
    }

    // MARK: Fail closed

    @Test func staysIdleWhenThePreferenceIsOff() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults, enable: false)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenTheNotificationKeyIsMissing() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenTheDeviceTokenIsMissing() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try saveKey()
        armWorld(token: nil)
        world.deviceToken = nil
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenActivitiesAreDisabledOrRequestThrows() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.areEnabled = false
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)

        controller.areEnabled = true
        controller.requestError = LiveActivityRequestError.requestFailed()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    // MARK: End + token pipe

    @Test func endingOnEmptyClearsTheLiveActivityToken() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        controller.emitToken(id: activityID, Data([0xde, 0xad]))
        try await waitUntil("the push token should land on the Host") {
            try await liveActivityToken() == "dead"
        }

        coordinator.agentsDidChange([])
        try await waitUntil("an empty eligible set should end the activity") {
            !controller.ended.isEmpty
        }
        #expect(controller.ended[0].immediate)
        try await waitUntil("ending should drop the registration field") {
            try await liveActivityToken() == nil
        }
    }

    @Test func tokenRotationRewritesTheRegistrationField() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        controller.emitToken(id: activityID, Data([0xaa]))
        try await waitUntil("the first token should be written") {
            try await liveActivityToken() == "aa"
        }
        controller.emitToken(id: activityID, Data([0xbb]))
        try await waitUntil("a rotated token should replace the field") {
            try await liveActivityToken() == "bb"
        }
    }

    @Test func aDirtyTokenWriteRetriesAfterReconnect() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "offline"))
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        controller.emitToken(id: activityID, Data([0xcc]))
        try await waitPastSettle()
        #expect(try await liveActivityToken() == nil)

        await transport.setNotificationRegistrationWriteFailure(nil)
        world.statuses[host.id] = .connected
        coordinator.connectionsDidChange()
        try await waitUntil("a recovered connection should flush the dirty token") {
            try await liveActivityToken() == "cc"
        }
    }

    @Test func switchingThePreferenceOffEndsAndClears() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0x11]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "11"
        }

        coordinator.setEnabled(false, for: host.id)
        #expect(controller.ended.count == 1)
        #expect(controller.ended[0].immediate)
        try await waitUntil("disabling should clear the registration field") {
            try await liveActivityToken() == nil
        }
    }

    // MARK: Cold launch

    @Test func startAdoptsAKnownActivityAndRewritesANewToken() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.seed(id: "act-cold", hostID: host.id)
        controller.emitToken(id: "act-cold", Data([0xee]))
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        #expect(controller.ended.isEmpty)
        #expect(controller.requested.isEmpty)

        try await waitUntil("adopting should write the current push token") {
            try await liveActivityToken() == "ee"
        }
    }

    @Test func startEndsAnOrphanActivityImmediately() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        armWorld()
        controller.seed(id: "act-orphan", hostID: UUID())
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        #expect(controller.ended.map(\.id) == ["act-orphan"])
        #expect(controller.ended[0].immediate)
    }

    @Test func reconnectEmptySliceDoesNotEndAnActiveActivity() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }
        #expect(controller.ended.isEmpty)

        // ConsoleStore.rebuild assigns `agents` before `hostsAwaitingSnapshot`,
        // so the coordinator can see an empty slice while the hold is stale.
        coordinator.agentsDidChange([])
        world.awaitingSnapshot = [host.id]
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty, "an empty slice while reconnecting is not all-idle")

        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)
        #expect(controller.requested.count == 1)
    }

    @Test func emptySnapshotAfterReconnectEndsTheActivity() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([])
        world.awaitingSnapshot = [host.id]
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)

        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        coordinator.connectionsDidChange()
        try await waitUntil("an empty post-reconnect snapshot should end") {
            !controller.ended.isEmpty
        }
    }

    @Test func doesNotEndAnAdoptedActivityBeforeTheFirstSnapshot() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        world.awaitingSnapshot = [host.id]
        controller.seed(id: "act-hold", hostID: host.id)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([])
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)

        world.awaitingSnapshot = []
        coordinator.connectionsDidChange()
        try await waitUntil("an empty snapshot should end once it arrives") {
            !controller.ended.isEmpty
        }
        #expect(controller.ended[0].id == "act-hold")
    }

    @Test func dismissalWhileForegroundedClearsTheRegistrationField() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xdd]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "dd"
        }

        controller.emitState(id: activityID, .dismissed)
        try await waitUntil("a foreground dismissal should drop the field") {
            try await liveActivityToken() == nil
        }
        try await waitPastSettle()
        #expect(controller.requested.count == 1, "the same desire must not restart")
    }

    // MARK: Pins

    @Test func pinToggleRebuildsOrderAndWritesPinnedPaneIDs() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
        ])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }
        #expect(try openedPaneIDs(controller.requested[0]) == ["w:p-block", "w:p-work"])
        #expect(controller.requested[0].counts == .init(working: 1, blocked: 1, done: 0))

        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xab]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "ab"
        }
        #expect(try await filePinnedPaneIDs() == [])

        pins.togglePin(hostID: host.id, paneID: "w:p-work")
        coordinator.pinsDidChange()
        try await waitUntil("a pin toggle should reorder the lock-screen rows") {
            controller.updates.count == 1
        }
        #expect(try openedPaneIDs(controller.updates[0].content) == ["w:p-work", "w:p-block"])
        #expect(controller.updates[0].content.counts == .init(working: 1, blocked: 1, done: 0))
        try await waitUntil("the Host should receive the new pin list") {
            try await filePinnedPaneIDs() == ["w:p-work"]
        }
        #expect(controller.requested.count == 1)
        #expect(controller.ended.isEmpty)
    }

    @Test func pinningAnIneligibleAgentLeavesRowsAndUpdatesTheFile() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-idle", .idle),
        ])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0x11]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "11"
        }

        pins.togglePin(hostID: host.id, paneID: "w:p-idle")
        coordinator.pinsDidChange()
        try await waitPastSettle()
        #expect(controller.updates.isEmpty, "ineligible pins must not change LA rows")
        try await waitUntil("the Host should still receive the pin list") {
            try await filePinnedPaneIDs() == ["w:p-idle"]
        }
    }

    @Test func pinToggleWhileOfflineDoesNotWriteUntilTheNextTokenWrite() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
        ])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xaa]))
        try await waitUntil("the first token should be written") {
            try await liveActivityToken() == "aa"
        }

        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        pins.togglePin(hostID: host.id, paneID: "w:p-work")
        coordinator.pinsDidChange()
        try await waitPastSettle()
        #expect(try await filePinnedPaneIDs() == [])

        world.statuses[host.id] = .connected
        controller.emitToken(id: activityID, Data([0xbb]))
        try await waitUntil("the next live_activity write should carry current pins") {
            let token = try await liveActivityToken()
            let pins = try await filePinnedPaneIDs()
            return token == "bb" && pins == ["w:p-work"]
        }
    }
}
