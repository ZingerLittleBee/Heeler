import Foundation
import Testing

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

    @Test func aCoreHostsBannersStayOff() async throws {
        let rig = try await registeredRig()
        defer { rig.console.setHosts([]) }
        #expect(rig.preferences.confirmedTriggers(for: host.id) == nil)
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
