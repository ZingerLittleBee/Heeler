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
        var backends: [UUID: HostBackend] = [:]
        var hostNames: [UUID: String] = [:]
        var awaitingSnapshot: Set<UUID> = []
        var statuses: [UUID: EventsSessionStatus] = [:]
        var deviceToken: APNSDeviceToken?
        var layout: AgentRowLayout?
        var coordinators: [HostLiveActivityCoordinator] = []
        let startedAt = ContinuousClock.now
        var trace: [String] = []

        func record(_ event: String) {
            trace.append("\(startedAt.duration(to: .now)): \(event)")
        }
    }

    private func withFixture(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        do {
            try await body(defaults)
        } catch {
            printTrace()
            await tearDown()
            throw error
        }
        await tearDown()
    }

    private func tearDown() async {
        let coordinators = world.coordinators
        world.coordinators.removeAll()
        let controller = controller
        for coordinator in coordinators {
            do {
                try await stopWithDeadline(coordinator) { await controller.finishStreams() }
            } catch {
                Issue.record("stop() did not end the coordinator's tasks: \(error)")
            }
        }
        // The streams are still open, so only stop()'s own cancellation can
        // have ended the subscriptions.
        #expect(controller.tokenSubscriberCount == 0)
        controller.finishStreams()
    }

    /// A `stop()` that stopped cancelling a task it joins would wait forever.
    /// `onTimeout` unblocks that task, so the failure surfaces here rather
    /// than at the run watchdog.
    private func stopWithDeadline(
        _ coordinator: HostLiveActivityCoordinator,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws {
        try await AsyncDeadline.run(for: .seconds(5), onTimeout: onTimeout) {
            await coordinator.stop()
        }
    }

    private func printTrace() {
        for entry in world.trace { print("[live-activity-test] \(entry)") }
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "la-pref-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        enable: Bool = true,
        pins: PinnedAgentsStore? = nil,
        otherHosts: [Host] = [],
        gate: GitExecGate? = nil
    ) -> HostLiveActivityCoordinator {
        let keys = NotificationKeyStore(secrets: secrets)
        let world = world
        let pinStore = pins
        let hosts = [host] + otherHosts
        let sessions = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0.notificationSession) })
        let transports = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.id, transport as any Transport) })
        let coordinator = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: ScriptedTransportProvider(transports: transports),
            keys: keys,
            ceremony: NotificationRegistrationCeremony(
                keys: keys, gate: gate, hostSession: { sessions[$0] }),
            deviceToken: { world.deviceToken },
            knownHostIDs: { world.knownHostIDs },
            hostDisplayName: { world.hostNames[$0] ?? "" },
            isAwaitingSnapshot: { world.awaitingSnapshot.contains($0) },
            connectionStatus: { world.statuses[$0] },
            supportsHost: { world.backends[$0] != .herdrCore },
            pinnedPaneIDs: { pinStore?.pinnedPaneIDs(for: $0) ?? [] },
            rowLayout: { _ in world.layout },
            settleDuration: .milliseconds(20))
        coordinator.onDiagnostic = { _, event in world.record(event) }
        controller.onDiagnostic = { event in world.record(event) }
        world.coordinators.append(coordinator)
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
            host: host, deviceToken: token, over: transport)
    }

    /// This Host's own entry in the registration file, found by its key.
    private func owner() throws -> NotificationRegistrationOwner {
        NotificationRegistrationOwner(deviceToken: token.hex, key: try notificationKey(), session: "")
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus, title: String = "Task", hostID: Host.ID? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID ?? host.id, hostName: "mbp",
            agent: Agent(.fixture(paneID: paneID, status: status, title: title)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(2),
        condition: () async throws -> Bool
    ) async throws {
        var budget = PollBudget(timeout)
        while budget.hasTimeLeft {
            if try await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        let satisfied = try await condition()
        if !satisfied { printTrace() }
        #expect(satisfied, comment)
    }

    private func waitPastSettle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func liveActivityToken() async throws -> String? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(for: try owner())?.token
    }

    private func filePinnedPaneIDs() async throws -> [String]? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(for: try owner())?.pinnedPaneIDs
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

    @Test func changingToCoreEndsAnActivityWithoutWritingToTheNewBackend() async throws {
        try await withFixture { defaults in
            let coordinator = makeCoordinator(defaults: defaults)
            try await registerDevice()
            armWorld()
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the legacy activity starts") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.activityID(for: host.id))
            let reads = await transport.notificationRegistrationReads

            world.backends[host.id] = .herdrCore
            world.awaitingSnapshot.insert(host.id)
            // The app invokes both on every Host edit, before its new
            // connection has a snapshot. An old activity must end immediately.
            coordinator.reconcile()
            coordinator.layoutsDidChange()
            coordinator.agentsDidChange([agent("t3", .working)])
            coordinator.connectionsDidChange()
            try await Task.sleep(for: .milliseconds(60))

            #expect(controller.ended.contains { $0.id == activityID && $0.immediate })
            #expect(controller.requestedHandles.count == 1)
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(coordinator.isEnabled(for: host.id), "a backend edit preserves the user's opt-in")
        }
    }

    @Test func aCoreHostNeverAdoptsAnActivityFromAnEarlierBackend() async throws {
        try await withFixture { defaults in
            let coordinator = makeCoordinator(defaults: defaults)
            try await registerDevice()
            armWorld()
            world.backends[host.id] = .herdrCore
            controller.seed(id: "legacy", hostID: host.id)
            let reads = await transport.notificationRegistrationReads

            coordinator.start()
            coordinator.agentsDidChange([agent("t3", .working)])
            try await Task.sleep(for: .milliseconds(60))

            #expect(controller.ended.contains { $0.id == "legacy" && $0.immediate })
            #expect(controller.requestedHandles.isEmpty)
            #expect(await transport.notificationRegistrationReads == reads)
        }
    }

    @Test func fixtureTeardownReleasesTheCoordinatorAndSubscriptions() async throws {
        weak var owner: HostLiveActivityCoordinator?
        try await withFixture { defaults in
            let coordinator = makeCoordinator(defaults: defaults)
            owner = coordinator
            try await registerDevice()
            armWorld()
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            #expect(controller.tokenSubscriberCount == 1)
        }
        #expect(owner == nil)
        #expect(controller.tokenSubscriberCount == 0)
    }

    @Test func droppingTheLastOwnerEndsItsSubscriptionsWithoutStop() async throws {
        weak var owner: HostLiveActivityCoordinator?
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            do {
                let coordinator = makeCoordinator(defaults: defaults)
                owner = coordinator
                coordinator.start()
                coordinator.agentsDidChange([agent(observedPaneID, .working)])
            }
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            #expect(controller.tokenSubscriberCount == 1)
            // The streams stay open and stop() never runs, so a subscription
            // task that held the coordinator would keep it alive from here.
            world.coordinators.removeAll()
            try await waitUntil("no subscription task should retain the coordinator") { owner == nil }
            try await waitUntil("deinit should cancel the token subscription") {
                controller.tokenSubscriberCount == 0
            }
        }
    }

    @Test func stoppingCancelsAnInFlightTokenWrite() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.requestedHandles.first?.id)
            let writes = await transport.replacedNotificationRegistrations.count
            let gate = CancellablePhaseGate()
            await transport.holdNotificationRegistrationWrites(on: gate)
            controller.emitToken(id: activityID, Data([0xde, 0xad]))
            try await waitUntil("the token write should reach the barrier") {
                await transport.notificationRegistrationWriteIsBlocked
            }
            try await stopWithDeadline(coordinator) { await gate.release() }
            // The barrier is still closed: cancellation alone ended the write,
            // before it recorded anything.
            #expect(await !transport.notificationRegistrationWriteIsBlocked)
            #expect(await transport.replacedNotificationRegistrations.count == writes)
            #expect(try await liveActivityToken() == nil)
            await gate.release()
        }
    }

    @Test func startsAfterTheSettleNotOnFirstSight() async throws {
        try await withFixture { defaults in
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
    }

    @Test func aFlapBackToTheAppliedDesireDoesNotEnd() async throws {
        try await withFixture { defaults in
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
    }

    @Test func updateCoalescesToTheLatestDesire() async throws {
        try await withFixture { defaults in
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
    }

    // MARK: Fail closed

    @Test func staysIdleWhenThePreferenceIsOff() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults, enable: false)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
            try await waitPastSettle()
            #expect(controller.requested.isEmpty)
        }
    }

    @Test func staysIdleWhenTheNotificationKeyIsMissing() async throws {
        try await withFixture { defaults in
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
            try await waitPastSettle()
            #expect(controller.requested.isEmpty)
        }
    }

    @Test func staysIdleWhenTheDeviceTokenIsMissing() async throws {
        try await withFixture { defaults in
            try saveKey()
            armWorld(token: nil)
            world.deviceToken = nil
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .done)])
            try await waitPastSettle()
            #expect(controller.requested.isEmpty)
        }
    }

    @Test func staysIdleWhenActivitiesAreDisabledOrRequestThrows() async throws {
        try await withFixture { defaults in
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
    }

    // MARK: End + token pipe

    @Test func endingOnEmptyClearsTheLiveActivityToken() async throws {
        try await withFixture { defaults in
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
    }

    @Test func tokenRotationRewritesTheRegistrationField() async throws {
        try await withFixture { defaults in
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
    }

    @Test func aDirtyTokenWriteRetriesAfterReconnect() async throws {
        try await withFixture { defaults in
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
    }

    @Test func endingAfterAFailedRotationThatLandedClearsTheLandedToken() async throws {
        try await withFixture { defaults in
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

            // The rotated token reaches the Host but the write still reports
            // failure, so the coordinator cannot know which token is there.
            await transport.setNotificationRegistrationWriteFailsAfterLanding(
                .writeFailed(detail: "exit status lost"))
            controller.emitToken(id: activityID, Data([0xbb]))
            try await waitUntil("the rotated write should land and then fail") {
                world.trace.contains {
                    $0.hasSuffix("writer completed success=false pending=true dirty=true")
                }
            }
            #expect(try await liveActivityToken() == "bb")

            await transport.setNotificationRegistrationWriteFailure(nil)
            controller.emitState(id: activityID, .ended)
            try await waitUntil("ending should drop the token that landed") {
                try await liveActivityToken() == nil
            }
        }
    }

    @Test func switchingThePreferenceOffEndsAndClears() async throws {
        try await withFixture { defaults in
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
    }

    // MARK: Cold launch

    @Test func startAdoptsAKnownActivityAndRewritesANewToken() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            controller.seed(id: "act-cold", hostID: host.id)
            controller.emitToken(id: "act-cold", Data([0xee]))
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            #expect(controller.ended.isEmpty)
            #expect(controller.requested.isEmpty)
            #expect(controller.tokenSubscriberCount == 1)

            try await waitUntil("adopting should write the current push token") {
                try await liveActivityToken() == "ee"
            }
        }
    }

    @Test func startEndsAnOrphanActivityImmediately() async throws {
        try await withFixture { defaults in
            armWorld()
            controller.seed(id: "act-orphan", hostID: UUID())
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            #expect(controller.ended.map(\.id) == ["act-orphan"])
            #expect(controller.ended[0].immediate)
        }
    }

    @Test func reconnectEmptySliceDoesNotEndAnActiveActivity() async throws {
        try await withFixture { defaults in
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
    }

    @Test func emptySnapshotAfterReconnectEndsTheActivity() async throws {
        try await withFixture { defaults in
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
    }

    @Test func doesNotEndAnAdoptedActivityBeforeTheFirstSnapshot() async throws {
        try await withFixture { defaults in
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
    }

    @Test func dismissalWhileForegroundedClearsTheRegistrationField() async throws {
        try await withFixture { defaults in
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
    }

    @Test func layoutChangesUpdateActivityAndRetryBackgroundRegistration() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            world.layout = AgentRowLayout(rows: [[.init(.host)]])
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.requestedHandles.first?.id)
            controller.emitToken(id: activityID, Data([0xab]))
            try await waitUntil("the initial layout should be registered") {
                let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
                return file.devices.first?["live_activity"]?["row_layout"] != nil
            }
            let initialFile = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            #expect(initialFile.devices.first?["live_activity"]?["host_name"] == .string("mbp"))

            await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
            world.layout = AgentRowLayout(rows: [[.init(.status, dim: true)]])
            coordinator.layoutsDidChange()
            try await waitUntil("layout-only edits should refresh the activity") { !controller.updates.isEmpty }
            let envelope = try #require(controller.updates.last?.content.envelope)
            let details = try AgentActivityEnvelope.open(
                try JSONEncoder().encode(envelope), using: notificationKey())
            #expect(details.agents.first?.rows == [[.init(text: "Working", dim: true)]])
            await transport.setNotificationRegistrationWriteFailure(nil)
            coordinator.connectionsDidChange()
            try await waitUntil("reconnection should retry the latest layout") {
                let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
                guard case .array(let rows)? = file.devices.first?["live_activity"]?["row_layout"]?["rows"],
                      case .array(let fields)? = rows.first else { return false }
                return fields.first?["token"] == .string("status")
            }
            #expect(try await liveActivityToken() == "ab")
        }
    }

    // MARK: Pins

    @Test func pinToggleRebuildsOrderAndWritesPinnedPaneIDs() async throws {
        try await withFixture { defaults in
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
    }

    @Test func pinningAnIneligibleAgentLeavesRowsAndUpdatesTheFile() async throws {
        try await withFixture { defaults in
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
    }

    @Test func pinToggleWhileOfflineDoesNotWriteUntilTheNextTokenWrite() async throws {
        try await withFixture { defaults in
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

    // MARK: Removed Hosts (#414)

    @Test func forgettingAHostEndsItsActivityAndWritesNothingAfterward() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            // A duplicate of the Host (#413): its own id, opt-in, and key.
            let sibling = Host.fixture(name: "mbp copy", address: "mbp.local", username: "z")
            try NotificationKeyStore(secrets: secrets).save(
                NotificationKeyRecord(
                    hostID: sibling.id, hostName: "mbp copy",
                    key: NotificationKeyStore.generateKey()))
            world.knownHostIDs.insert(sibling.id)
            world.statuses[sibling.id] = .connected
            // No transport for the sibling, so the counts below are the
            // removed Host's alone.
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.setEnabled(true, for: sibling.id)
            coordinator.start()
            let agents = [
                agent(observedPaneID, .working),
                agent("w:p-copy", .working, hostID: sibling.id),
            ]
            coordinator.agentsDidChange(agents)
            try await waitUntil("both Hosts should start an activity") {
                controller.requestedHandles.count == 2
            }
            let activityID = try #require(
                controller.requestedHandles.first { $0.hostID == host.id }?.id)
            controller.emitToken(id: activityID, Data([0xde, 0xad]))
            try await waitUntil("the push token should land on the Host") {
                try await liveActivityToken() == "dead"
            }
            let reads = await transport.notificationRegistrationReads
            let writes = await transport.replacedNotificationRegistrations.count

            // HostStore.remove has already dropped it from the catalog.
            world.knownHostIDs.remove(host.id)
            coordinator.forgetHost(host.id)

            #expect(controller.ended.map(\.id) == [activityID])
            #expect(controller.ended.first?.immediate == true)
            #expect(!coordinator.isEnabled(for: host.id))
            #expect(!LiveActivityPreferences(defaults: defaults).isEnabled(for: host.id))
            #expect(coordinator.reconcileNotes[host.id] == nil)
            #expect(coordinator.isEnabled(for: sibling.id))

            // The Console still lists the removed Host's Agents until it
            // drops the projection; with its opt-in and session gone, nothing
            // may bring the activity back. A Host that leaves the catalog
            // without forgetHost is pinned separately below.
            coordinator.agentsDidChange(agents)
            coordinator.connectionsDidChange()
            coordinator.reconcile()
            coordinator.pinsDidChange()
            coordinator.layoutsDidChange()
            try await waitPastSettle()

            #expect(controller.requestedHandles.count == 2)
            #expect(controller.ended.map(\.id) == [activityID])
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(await transport.replacedNotificationRegistrations.count == writes)
            #expect(controller.currentActivities().map(\.hostID) == [sibling.id])
        }
    }

    @Test func aDirtyClearRetriesOnlyWhileItsHostIsInTheCatalog() async throws {
        try await withFixture { defaults in
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

            await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
            coordinator.agentsDidChange([])
            @MainActor func failedWrites() -> Int {
                world.trace.filter { $0.hasSuffix("writer completed success=false pending=true dirty=true") }
                    .count
            }
            try await waitUntil("the clear should fail and stay dirty") { failedWrites() == 1 }

            // Still in the catalog: a foreground return retries it.
            coordinator.reconcile()
            try await waitUntil("a known Host's dirty clear should retry") { failedWrites() == 2 }

            // Out of the catalog: the clear has nothing to write through,
            // neither on reconnect alone nor on a foreground return.
            world.knownHostIDs = []
            let reads = await transport.notificationRegistrationReads
            coordinator.connectionsDidChange()
            try await waitPastSettle()
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(failedWrites() == 2)

            coordinator.reconcile()
            coordinator.connectionsDidChange()
            coordinator.reconcile()
            try await waitPastSettle()
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(failedWrites() == 2)
        }
    }

    @Test func aHostOutsideTheCatalogWritesNothingWhileItsActivityIsLive() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            let agents = [agent(observedPaneID, .working)]
            coordinator.agentsDidChange(agents)
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.requestedHandles.first?.id)
            controller.emitToken(id: activityID, Data([0xde, 0xad]))
            try await waitUntil("the push token should land on the Host") {
                try await liveActivityToken() == "dead"
            }
            let reads = await transport.notificationRegistrationReads
            let writes = await transport.replacedNotificationRegistrations.count
            let updates = controller.updates.count

            // No forgetHost: an unreadable catalog also reads as no Hosts.
            // The Host stays opted in with a live session, so only the
            // catalog checks keep its Agents, pins, and layout from writing.
            world.knownHostIDs = []
            coordinator.agentsDidChange(agents + [agent("w:p-new", .blocked)])
            coordinator.pinsDidChange()
            coordinator.layoutsDidChange()
            coordinator.connectionsDidChange()
            try await waitPastSettle()

            #expect(controller.requestedHandles.count == 1)
            #expect(controller.updates.count == updates)
            #expect(controller.ended.isEmpty)
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(await transport.replacedNotificationRegistrations.count == writes)

            // A foreground return ends the activity without a clear it has
            // no Console projection to write through.
            coordinator.reconcile()
            try await waitPastSettle()
            #expect(controller.ended.map(\.id) == [activityID])
            #expect(controller.requestedHandles.count == 1)
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(await transport.replacedNotificationRegistrations.count == writes)
            #expect(coordinator.isEnabled(for: host.id))
        }
    }

    @Test func aWriteInFlightWhenItsHostLeavesTheCatalogLeavesNoPipe() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.requestedHandles.first?.id)
            // The held write fails once released, which would leave a dirty
            // pipe behind.
            await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
            let gate = CancellablePhaseGate()
            await transport.holdNotificationRegistrationWrites(on: gate)
            controller.emitToken(id: activityID, Data([0xde, 0xad]))
            try await waitUntil("the token write should reach the barrier") {
                await transport.notificationRegistrationWriteIsBlocked
            }

            // No forgetHost and no reconcile, so the writer is not cancelled
            // and finishes on its own.
            world.knownHostIDs = []
            await gate.release()
            try await waitUntil("the released write should fail") {
                world.trace.contains { $0.contains("writer error category=writeFailed") }
            }
            try await waitPastSettle()
            #expect(!world.trace.contains { $0.contains("writer completed") })

            // The catalog comes back: no dirty pipe is left for a reconnect
            // to retry.
            let reads = await transport.notificationRegistrationReads
            world.knownHostIDs = [host.id]
            coordinator.connectionsDidChange()
            try await waitPastSettle()
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(!world.trace.contains { $0.contains("writer completed") })
        }
    }

    @Test func aWriteInFlightWhenItsHostIsForgottenLeavesNoPipe() async throws {
        try await withFixture { defaults in
            try await registerDevice()
            armWorld()
            let coordinator = makeCoordinator(defaults: defaults)
            coordinator.start()
            coordinator.agentsDidChange([agent(observedPaneID, .working)])
            try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
            let activityID = try #require(controller.requestedHandles.first?.id)
            let writes = await transport.replacedNotificationRegistrations.count
            // forgetHost cancels the held write; were it to finish anyway, it
            // would fail and leave a dirty pipe. The catalog check a writer
            // that is not cancelled reaches is pinned by the case above.
            await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
            let gate = CancellablePhaseGate()
            await transport.holdNotificationRegistrationWrites(on: gate)
            controller.emitToken(id: activityID, Data([0xde, 0xad]))
            try await waitUntil("the token write should reach the barrier") {
                await transport.notificationRegistrationWriteIsBlocked
            }

            world.knownHostIDs.remove(host.id)
            coordinator.forgetHost(host.id)
            await gate.release()
            try await waitUntil("the held write should finish") {
                await !transport.notificationRegistrationWriteIsBlocked
            }
            try await waitPastSettle()
            let reads = await transport.notificationRegistrationReads

            coordinator.connectionsDidChange()
            coordinator.reconcile()
            try await waitPastSettle()
            #expect(await transport.notificationRegistrationReads == reads)
            #expect(await transport.replacedNotificationRegistrations.count == writes)
            #expect(!world.trace.contains { $0.contains("writer completed") })
        }
    }

    // MARK: Hosts on several herdr sessions of one remote user (#412)

    @Test func hostsOnDifferentSessionsWriteOnlyTheirOwnLiveActivityFields() async throws {
        try await withFixture { defaults in
            let (pinDefaults, pinCleanup) = try makeDefaults()
            defer { pinCleanup() }
            let workHost = Host(
                name: "mbp work", address: "mbp.local", username: "z", sessionName: "work")
            let keys = NotificationKeyStore(secrets: secrets)
            let gate = GitExecGate()
            let ceremony = NotificationRegistrationCeremony(keys: keys, gate: gate)
            try await ceremony.register(host: host, deviceToken: token, over: transport)
            try await ceremony.register(host: workHost, deviceToken: token, over: transport)
            armWorld()
            world.knownHostIDs.insert(workHost.id)
            world.hostNames[workHost.id] = "mbp work"
            world.statuses[workHost.id] = .connected
            let pins = PinnedAgentsStore(defaults: pinDefaults)
            let coordinator = makeCoordinator(
                defaults: defaults, pins: pins, otherHosts: [workHost], gate: gate)
            coordinator.setEnabled(true, for: workHost.id)
            func live(_ host: Host) async throws -> LiveActivityRegistration? {
                let owner = try #require(
                    try ceremony.registrationOwner(for: host, deviceToken: token))
                return try NotificationRegistrationFile.decode(
                    await transport.notificationRegistration
                ).liveActivity(for: owner)
            }

            coordinator.start()
            coordinator.agentsDidChange([
                agent("w:p-main", .working),
                agent("w:p-work", .working, hostID: workHost.id),
            ])
            try await waitUntil("both Hosts should start an activity") {
                controller.requestedHandles.count == 2
            }
            let mainID = try #require(
                controller.requestedHandles.first { $0.hostID == host.id }?.id)
            let workID = try #require(
                controller.requestedHandles.first { $0.hostID == workHost.id }?.id)
            // Both writers run at once; the shared gate keeps either from
            // replacing the file with a copy that lacks the other's token.
            controller.emitToken(id: mainID, Data([0xaa]))
            controller.emitToken(id: workID, Data([0xbb]))
            try await waitUntil("each Host's entry should carry its own token") {
                let main = try await live(host)?.token
                let work = try await live(workHost)?.token
                return main == "aa" && work == "bb"
            }

            pins.togglePin(hostID: workHost.id, paneID: "w:p-work")
            coordinator.pinsDidChange()
            try await waitUntil("the pin should land on the work Host's entry") {
                try await live(workHost)?.pinnedPaneIDs == ["w:p-work"]
            }
            #expect(try await live(host)?.pinnedPaneIDs == [])

            controller.emitState(id: mainID, .dismissed)
            try await waitUntil("dismissal should clear only the default Host's field") {
                try await live(host) == nil
            }
            #expect(try await live(workHost)?.token == "bb")
            let file = try NotificationRegistrationFile.decode(
                await transport.notificationRegistration)
            #expect(file.devices.count == 2)
        }
    }
}
