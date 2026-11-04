import Foundation
import Testing

@testable import Heeler

@Suite("Notification registration ceremony")
struct NotificationRegistrationCeremonyTests {
    private let secrets = InMemorySecretStore()
    private var keys: NotificationKeyStore { NotificationKeyStore(secrets: secrets) }
    private var ceremony: NotificationRegistrationCeremony {
        NotificationRegistrationCeremony(keys: keys)
    }
    private let host = Host(name: "mac-studio", address: "10.0.0.2", username: "z")
    private var hostID: UUID { host.id }
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)

    /// This Host's own entry in a written file, found by its stored key.
    private func owner() throws -> NotificationRegistrationOwner {
        try #require(try ceremony.registrationOwner(for: host, deviceToken: token))
    }

    private func hasDevice(_ token: String, in file: NotificationRegistrationFile) -> Bool {
        file.devices.contains { $0["token"]?.stringValue == token }
    }

    @Test func registerWritesAConformantEntryAndPersistsTheKey() async throws {
        let transport = ScriptedTransport()

        let record = try await ceremony.register(
            host: host, deviceToken: token,
            notify: NotificationTriggerPreferences(blocked: true, done: false),
            over: transport)

        #expect(try keys.record(forHost: hostID) == record)
        #expect(record.key.count == 32)
        let written = try #require(await transport.replacedNotificationRegistrations.last)
        let object = try #require(
            try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        let devices = try #require(object["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device["token"] as? String == token.hex)
        #expect(device["key"] as? String == record.key.base64URLEncodedString())
        #expect(device["env"] as? String == "sandbox")
        #expect(device["notify"] as? [String: Bool] == ["blocked": true, "done": false])
    }

    @Test func reRegistrationIsIdempotentAndReusesTheKey() async throws {
        let transport = ScriptedTransport()

        let first = try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        let second = try await ceremony.register(
            host: host, deviceToken: token, over: transport)

        #expect(second.key == first.key)
        #expect(try keys.allRecords().count == 1)
        let writes = await transport.replacedNotificationRegistrations
        #expect(writes.count == 2)
        #expect(writes.first == writes.last)
        let file = try NotificationRegistrationFile.decode(writes.last)
        #expect(file.devices.count == 1)
    }

    @Test func registerPreservesOtherDevicesEntries() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production","#
                    + #""notify":{"blocked":true,"done":true},"extra":"kept"}]}"#).utf8))

        try await ceremony.register(
            host: host, deviceToken: token, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(file.devices.count == 2)
        #expect(hasDevice("ffff", in: file))
        #expect(file.preferences(for: try owner()) != nil)
        let foreign = try #require(
            file.devices.first { $0["token"]?.stringValue == "ffff" })
        #expect(foreign["extra"]?.stringValue == "kept")
    }

    @Test func removeDeletesOnlyOurEntryAndTheLocalKey() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production"}]}"#.utf8))
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)

        try await ceremony.remove(host: host, deviceToken: token, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(!hasDevice(token.hex, in: file))
        #expect(hasDevice("ffff", in: file))
        #expect(try keys.record(forHost: hostID) == nil)
    }

    @Test func revokeDeletesOnlyOurEntryAndKeepsTheLocalKey() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production"}]}"#.utf8))
        let record = try await ceremony.register(
            host: host, deviceToken: token, over: transport)

        try await ceremony.revoke(host: host, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(!hasDevice(token.hex, in: file))
        #expect(hasDevice("ffff", in: file))
        #expect(try keys.record(forHost: hostID) == record)
    }

    /// The key alone marks this device's entries for the Host, so an entry
    /// left under an older APNs token goes too (#414).
    @Test func revokeDropsOurEntryUnderAnOlderDeviceToken() async throws {
        let record = try await ceremony.register(
            host: host, deviceToken: token, over: ScriptedTransport())
        let transport = ScriptedTransport()
        let key = record.key.base64URLEncodedString()
        let stale = #"{"token":"0123","key":"\#(key)","env":"sandbox"}"#
        let foreign = #"{"token":"ffff","key":"kk","env":"production"}"#
        await transport.setNotificationRegistration(
            Data(#"{"v":1,"devices":[\#(stale),\#(foreign)]}"#.utf8))

        try await ceremony.revoke(host: host, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(!hasDevice("0123", in: file))
        #expect(hasDevice("ffff", in: file))
    }

    @Test func removeWithNoHostFileStillClearsTheLocalKeyWithoutWriting() async throws {
        let transport = ScriptedTransport()
        try keys.save(
            NotificationKeyRecord(
                hostID: hostID, hostName: "mac-studio",
                key: NotificationKeyStore.generateKey()))

        try await ceremony.remove(host: host, deviceToken: token, over: transport)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(try keys.record(forHost: hostID) == nil)
    }

    @Test func removeOfAnUnregisteredTokenWritesNothing() async throws {
        let transport = ScriptedTransport()
        let existing = Data(
            #"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production"}]}"#.utf8)
        await transport.setNotificationRegistration(existing)

        try await ceremony.remove(host: host, deviceToken: token, over: transport)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(await transport.notificationRegistration == existing)
    }

    @Test func pluginNotInstalledSurfacesBeforeAnythingIsWritten() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await ceremony.register(
                host: host, deviceToken: token, over: transport)
        }

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func writeFailureSurfacesAndKeepsTheLocalKeyForRetry() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))

        await #expect(throws: NotificationRegistrationError.writeFailed(detail: "disk full")) {
            try await ceremony.register(
                host: host, deviceToken: token, over: transport)
        }

        // The key survives so the retry re-offers the same key to the Host.
        let record = try #require(try keys.record(forHost: hostID))
        await transport.setNotificationRegistrationWriteFailure(nil)
        let retried = try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        #expect(retried.key == record.key)
    }

    @Test func aNewerFileVersionRefusesToRegister() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(Data(#"{"v":2,"devices":[]}"#.utf8))

        await #expect(throws: NotificationRegistrationError.unsupportedFileVersion(2)) {
            try await ceremony.register(
                host: host, deviceToken: token, over: transport)
        }

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    // MARK: Custom relay URL (#76)

    @Test func registerWithoutAnOverrideWritesTheProductionRelay() async throws {
        let transport = ScriptedTransport()

        try await ceremony.register(
            host: host, deviceToken: token, over: transport)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://heeler-apns.bybee.dev")
    }

    @Test func registerWithARelayURLWritesItPreservingOtherFields() async throws {
        let transport = ScriptedTransport()
        // The Host's plugin already carries its own knobs; the merge keeps them.
        await transport.setNotificationConfig(
            Data(#"{"debounce_ms":2000,"future_knob":"kept"}"#.utf8))

        try await ceremony.register(
            host: host, deviceToken: token,
            relayBaseURL: URL(string: "https://relay.example.com")!, over: transport)

        let written = try #require(await transport.replacedNotificationConfigs.last)
        let object = try #require(
            try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["relay_url"] as? String == "https://relay.example.com")
        #expect(object["debounce_ms"] as? Int == 2000)
        #expect(object["future_knob"] as? String == "kept")
    }

    @Test func reRegisterWithTheSameRelayURLDoesNotRewriteTheConfig() async throws {
        let transport = ScriptedTransport()
        let relay = URL(string: "https://relay.example.com")!

        try await ceremony.register(
            host: host, deviceToken: token,
            relayBaseURL: relay, over: transport)
        try await ceremony.register(
            host: host, deviceToken: token,
            relayBaseURL: relay, over: transport)

        // First register writes the config once; the second changes nothing.
        #expect(await transport.replacedNotificationConfigs.count == 1)
    }

    // Driven by the endpoint list itself, so retiring another production
    // endpoint cannot ship without its migration being covered.
    @Test(arguments: NotificationRelayEndpoint.legacyProductionBaseURLStrings)
    func registerMigratesAPreviousProductionRelay(_ legacy: String) async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationConfig(
            Data(#"{"relay_url":"\#(legacy)"}"#.utf8))

        try await ceremony.register(
            host: host, deviceToken: token,
            relayBaseURL: URL(string: legacy),
            over: transport)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == NotificationRelayEndpoint.productionBaseURLString)
    }

    @Test func removeSurfacesAFailedRemoteRemovalAndKeepsTheKey() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "read-only"))

        await #expect(throws: NotificationRegistrationError.writeFailed(detail: "read-only")) {
            try await ceremony.remove(host: host, deviceToken: token, over: transport)
        }

        // Still registered on the Host, so the key must survive for pushes.
        #expect(try keys.record(forHost: hostID) != nil)
    }

    @Test func setLiveActivityTokenWritesTheFieldOnARegisteredDevice() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        try await ceremony.setLiveActivityToken(
            tokenHex: "deadbeef", startedAt: started, hostID: hostID, deviceToken: token,
            over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let live = try #require(file.liveActivity(for: try owner()))
        #expect(live.token == "deadbeef")
        #expect(live.startedAt == "2023-11-14T22:13:20Z")
        #expect(file.preferences(for: try owner()) != nil)
    }

    @Test func setLiveActivityTokenFailsClosedWhenTheDeviceIsNotRegistered() async throws {
        let transport = ScriptedTransport()

        await #expect(throws: NotificationRegistrationError.deviceNotRegistered) {
            try await ceremony.setLiveActivityToken(
                tokenHex: "deadbeef",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                hostID: hostID, deviceToken: token, over: transport)
        }

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func clearLiveActivityTokenDropsOnlyThatField() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        try await ceremony.setLiveActivityToken(
            tokenHex: "deadbeef",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hostID: hostID, deviceToken: token, over: transport)

        try await ceremony.clearLiveActivityToken(
            "deadbeef", hostID: hostID, deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.liveActivity(for: try owner()) == nil)
        #expect(file.preferences(for: try owner()) != nil)
        #expect(file.preferences(for: try owner()) != nil)
    }

    @Test func setLiveActivityTokenWritesPinnedPaneIDs() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        try await ceremony.setLiveActivityToken(
            tokenHex: "deadbeef", startedAt: started, hostID: hostID, deviceToken: token,
            pinnedPaneIDs: ["w1:p2", "w1:p1"], over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.liveActivity(for: try owner())?.pinnedPaneIDs == ["w1:p2", "w1:p1"])
    }

    @Test func setLiveActivityPinnedPaneIDsUpdatesAnExistingField() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            host: host, deviceToken: token, over: transport)
        try await ceremony.setLiveActivityToken(
            tokenHex: "deadbeef",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hostID: hostID, deviceToken: token, over: transport)

        try await ceremony.setLiveActivityPinnedPaneIDs(
            ["w1:p9"], hostID: hostID, deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let live = try #require(file.liveActivity(for: try owner()))
        #expect(live.token == "deadbeef")
        #expect(live.pinnedPaneIDs == ["w1:p9"])
    }

    @Test func setLiveActivityPinnedPaneIDsIsANoOpWhenUnregistered() async throws {
        let transport = ScriptedTransport()

        try await ceremony.setLiveActivityPinnedPaneIDs(
            ["w1:p1"], hostID: hostID, deviceToken: token, over: transport)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    // MARK: Hosts on several herdr sessions of one remote user (#412)

    private let workHost = Host(
        name: "mac-studio work", address: "10.0.0.2", username: "z", sessionName: "work")

    private func sessionCeremony(gate: GitExecGate? = nil) -> NotificationRegistrationCeremony {
        let sessions = [host.id: host.notificationSession, workHost.id: workHost.notificationSession]
        return NotificationRegistrationCeremony(
            keys: keys, gate: gate, hostSession: { sessions[$0] })
    }

    private func liveOwner(_ host: Host) throws -> NotificationRegistrationOwner {
        try #require(try ceremony.registrationOwner(for: host, deviceToken: token))
    }

    @Test func registerScopesTheEntryToTheHostsSession() async throws {
        let transport = ScriptedTransport()

        try await ceremony.register(host: workHost, deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.first?["session"]?.stringValue == "work")
    }

    @Test func hostsOnDifferentSessionsKeepSeparateEntriesThroughEveryWrite() async throws {
        let transport = ScriptedTransport()
        let ceremony = sessionCeremony()
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        try await ceremony.register(host: host, deviceToken: token, over: transport)
        try await ceremony.register(
            host: workHost, deviceToken: token,
            notify: NotificationTriggerPreferences(blocked: true, done: false), over: transport)
        try await ceremony.setLiveActivityToken(
            tokenHex: "aaaa", startedAt: started, hostID: host.id, deviceToken: token,
            over: transport)
        try await ceremony.setLiveActivityToken(
            tokenHex: "bbbb", startedAt: started, hostID: workHost.id, deviceToken: token,
            pinnedPaneIDs: ["w1:p1"], over: transport)
        try await ceremony.setLiveActivityPinnedPaneIDs(
            ["w2:p2"], hostID: host.id, deviceToken: token, over: transport)

        var file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 2)
        #expect(file.preferences(for: try liveOwner(host)) == NotificationTriggerPreferences())
        #expect(
            file.preferences(for: try liveOwner(workHost))
                == NotificationTriggerPreferences(blocked: true, done: false))
        #expect(file.liveActivity(for: try liveOwner(host))?.token == "aaaa")
        #expect(file.liveActivity(for: try liveOwner(host))?.pinnedPaneIDs == ["w2:p2"])
        #expect(file.liveActivity(for: try liveOwner(workHost))?.token == "bbbb")
        #expect(file.liveActivity(for: try liveOwner(workHost))?.pinnedPaneIDs == ["w1:p1"])

        try await ceremony.clearLiveActivityToken(
            "aaaa", hostID: host.id, deviceToken: token, over: transport)
        let workOwner = try liveOwner(workHost)
        try await ceremony.remove(host: host, deviceToken: token, over: transport)

        file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(file.devices.count == 1)
        #expect(file.devices.first?["session"]?.stringValue == "work")
        #expect(file.liveActivity(for: workOwner)?.token == "bbbb")
        #expect(try keys.record(forHost: workHost.id) != nil)
    }

    @Test func liveActivityWritesMoveALegacyEntryToTheHostsSession() async throws {
        let transport = ScriptedTransport()
        let ceremony = sessionCeremony()
        let key = NotificationKeyStore.generateKey()
        try keys.save(NotificationKeyRecord(hostID: workHost.id, hostName: "w", key: key))
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"\#(key.base64URLEncodedString())","#
                    + #""env":"sandbox","notify":{"blocked":true,"done":true}}]}"#).utf8))

        try await ceremony.setLiveActivityToken(
            tokenHex: "bbbb", startedAt: Date(timeIntervalSince1970: 0), hostID: workHost.id,
            deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 1)
        #expect(file.devices.first?["session"]?.stringValue == "work")
        #expect(file.liveActivity(for: try liveOwner(workHost))?.token == "bbbb")
    }

    @Test func anUnregisteredLiveActivityWriteStillStripsItsTokenElsewhere() async throws {
        let transport = ScriptedTransport()
        let ceremony = sessionCeremony()
        try await ceremony.register(host: workHost, deviceToken: token, over: transport)
        try await ceremony.setLiveActivityToken(
            tokenHex: "bbbb", startedAt: Date(timeIntervalSince1970: 0), hostID: workHost.id,
            deviceToken: token, over: transport)
        try keys.save(
            NotificationKeyRecord(
                hostID: host.id, hostName: "h", key: NotificationKeyStore.generateKey()))

        await #expect(throws: NotificationRegistrationError.deviceNotRegistered) {
            try await ceremony.setLiveActivityToken(
                tokenHex: "bbbb", startedAt: Date(timeIntervalSince1970: 0), hostID: host.id,
                deviceToken: token, over: transport)
        }

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.liveActivity(for: try liveOwner(workHost)) == nil)
        #expect(file.preferences(for: try liveOwner(workHost)) != nil)
    }

    // MARK: Serialized writes and migration

    @Test func aSharedGateKeepsBothEntriesOfInterleavedRegistrations() async throws {
        let transport = ScriptedTransport()
        let gate = GitExecGate()
        let first = sessionCeremony(gate: gate)
        let second = sessionCeremony(gate: gate)
        let hold = CancellablePhaseGate()
        await transport.holdNotificationRegistrationWrites(on: hold)
        let host = host
        let workHost = workHost
        let token = token

        let registerDefault = Task {
            try await first.register(host: host, deviceToken: token, over: transport)
        }
        try await hold.waitUntilEntered()
        let registerWork = Task {
            try await second.register(host: workHost, deviceToken: token, over: transport)
        }
        // The second registration must not read the file the first is
        // about to replace; it waits for the gate instead.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.notificationRegistrationReads == 1)

        await hold.release()
        try await registerDefault.value
        try await registerWork.value

        #expect(await transport.notificationRegistrationReads == 2)
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 2)
        #expect(file.preferences(for: try liveOwner(host)) != nil)
        #expect(file.preferences(for: try liveOwner(workHost)) != nil)
    }

    @Test(arguments: [nil, "old"] as [String?])
    func migrateMovesTheOwnEntryToTheHostsSession(_ stored: String?) async throws {
        let transport = ScriptedTransport()
        let key = NotificationKeyStore.generateKey()
        try keys.save(NotificationKeyRecord(hostID: workHost.id, hostName: "w", key: key))
        let sessionField = stored.map { #","session":"\#($0)""# } ?? ""
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"\#(key.base64URLEncodedString())","#
                    + #""env":"sandbox","notify":{"blocked":true,"done":false}"# + sessionField
                    + #","future_field":"kept"}]}"#).utf8))

        let migrated = try await ceremony.migrate(
            host: workHost, deviceToken: token, over: transport)
        let again = try await ceremony.migrate(
            host: workHost, deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file == migrated)
        #expect(again == migrated)
        #expect(await transport.replacedNotificationRegistrations.count == 1)
        #expect(file.devices.first?["session"]?.stringValue == "work")
        #expect(file.devices.first?["future_field"]?.stringValue == "kept")
        #expect(
            file.preferences(for: try liveOwner(workHost))
                == NotificationTriggerPreferences(blocked: true, done: false))
    }
}
