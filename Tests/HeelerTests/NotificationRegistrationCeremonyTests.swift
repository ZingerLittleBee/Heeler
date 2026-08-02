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
    private let hostID = UUID()
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)

    @Test func registerWritesAConformantEntryAndPersistsTheKey() async throws {
        let transport = ScriptedTransport()

        let record = try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token,
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
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        let second = try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)

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
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(file.devices.count == 2)
        #expect(file.containsDevice(token: "ffff"))
        #expect(file.containsDevice(token: token.hex))
        let foreign = try #require(
            file.devices.first { $0["token"]?.stringValue == "ffff" })
        #expect(foreign["extra"]?.stringValue == "kept")
    }

    @Test func removeDeletesOnlyOurEntryAndTheLocalKey() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production"}]}"#.utf8))
        try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)

        try await ceremony.remove(hostID: hostID, deviceToken: token, over: transport)

        let written = try #require(await transport.notificationRegistration)
        let file = try NotificationRegistrationFile.decode(written)
        #expect(!file.containsDevice(token: token.hex))
        #expect(file.containsDevice(token: "ffff"))
        #expect(try keys.record(forHost: hostID) == nil)
    }

    @Test func removeWithNoHostFileStillClearsTheLocalKeyWithoutWriting() async throws {
        let transport = ScriptedTransport()
        try keys.save(
            NotificationKeyRecord(
                hostID: hostID, hostName: "mac-studio",
                key: NotificationKeyStore.generateKey()))

        try await ceremony.remove(hostID: hostID, deviceToken: token, over: transport)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(try keys.record(forHost: hostID) == nil)
    }

    @Test func removeOfAnUnregisteredTokenWritesNothing() async throws {
        let transport = ScriptedTransport()
        let existing = Data(
            #"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production"}]}"#.utf8)
        await transport.setNotificationRegistration(existing)

        try await ceremony.remove(hostID: hostID, deviceToken: token, over: transport)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(await transport.notificationRegistration == existing)
    }

    @Test func pluginNotInstalledSurfacesBeforeAnythingIsWritten() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await ceremony.register(
                hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        }

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func writeFailureSurfacesAndKeepsTheLocalKeyForRetry() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))

        await #expect(throws: NotificationRegistrationError.writeFailed(detail: "disk full")) {
            try await ceremony.register(
                hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        }

        // The key survives so the retry re-offers the same key to the Host.
        let record = try #require(try keys.record(forHost: hostID))
        await transport.setNotificationRegistrationWriteFailure(nil)
        let retried = try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        #expect(retried.key == record.key)
    }

    @Test func aNewerFileVersionRefusesToRegister() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(Data(#"{"v":2,"devices":[]}"#.utf8))

        await #expect(throws: NotificationRegistrationError.unsupportedFileVersion(2)) {
            try await ceremony.register(
                hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        }

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    // MARK: Custom relay URL (#76)

    @Test func registerWithoutAnOverrideWritesTheProductionRelay() async throws {
        let transport = ScriptedTransport()

        try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)

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
            hostID: hostID, hostName: "mac-studio", deviceToken: token,
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
            hostID: hostID, hostName: "mac-studio", deviceToken: token,
            relayBaseURL: relay, over: transport)
        try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token,
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
            hostID: hostID, hostName: "mac-studio", deviceToken: token,
            relayBaseURL: URL(string: legacy),
            over: transport)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == NotificationRelayEndpoint.productionBaseURLString)
    }

    @Test func removeSurfacesAFailedRemoteRemovalAndKeepsTheKey() async throws {
        let transport = ScriptedTransport()
        try await ceremony.register(
            hostID: hostID, hostName: "mac-studio", deviceToken: token, over: transport)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "read-only"))

        await #expect(throws: NotificationRegistrationError.writeFailed(detail: "read-only")) {
            try await ceremony.remove(hostID: hostID, deviceToken: token, over: transport)
        }

        // Still registered on the Host, so the key must survive for pushes.
        #expect(try keys.record(forHost: hostID) != nil)
    }
}
