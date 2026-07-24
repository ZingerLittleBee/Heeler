import Foundation
import Testing

@testable import HerdrMobile

/// `NotificationTransportProvider` double: hands each Host's scripted (or
/// real, in the e2e suite) Transport to the operation. Hosts without one are
/// unreachable, exactly like a Console projection that never connected — and
/// a Host can be cut off mid-test, like a connection dropping between the
/// settings screen loading and a toggle.
actor ScriptedTransportProvider: NotificationTransportProvider {
    private var transports: [Host.ID: any Transport]

    init(transports: [Host.ID: any Transport]) {
        self.transports = transports
    }

    func setTransport(_ transport: (any Transport)?, for hostID: Host.ID) {
        transports[hostID] = transport
    }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let transport = transports[hostID] else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return try await operation(transport)
    }
}

@MainActor
@Suite("Notification preferences store")
struct NotificationPreferencesStoreTests {
    private let host = Host(name: "mac-studio", address: "10.0.0.2", username: "z")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let secrets = InMemorySecretStore()
    private var keys: NotificationKeyStore { NotificationKeyStore(secrets: secrets) }

    private func makeStore(
        provider: ScriptedTransportProvider,
        deviceToken: APNSDeviceToken?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: provider,
            deviceToken: { deviceToken },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    private func makeStore(
        transport: any Transport,
        deviceToken: APNSDeviceToken? = nil
    ) -> NotificationPreferencesStore {
        makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: deviceToken ?? token)
    }

    private func makeStore(
        transport: any Transport,
        relayBaseURL: @escaping @MainActor () -> URL?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            relayBaseURL: relayBaseURL,
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    // MARK: Reflecting the Host's truth

    @Test func refreshReflectsAnUnregisteredHost() async throws {
        let store = makeStore(transport: ScriptedTransport())

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func refreshReflectsThisDevicesEntryFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":true,"done":false}}]}"#).utf8))
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
    }

    @Test func refreshWithoutAPushTokenIsUnavailable() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: ScriptedTransport()]),
            deviceToken: nil)

        await store.refresh()

        guard case .unavailable = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
    }

    @Test func refreshSurfacesAnUnreachableHost() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [:]), deviceToken: token)

        await store.refresh()

        #expect(store.states[host.id] == .unavailable(message: "The Host is not connected."))
    }

    @Test func refreshSurfacesAMissingPlugin() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)
        let store = makeStore(transport: transport)

        await store.refresh()

        guard case .unavailable(let message) = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("plugin"))
    }

    @Test func removingAHostFromTheCatalogDropsItsState() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        store.setHosts([])

        #expect(store.hosts.isEmpty)
        #expect(store.states.isEmpty)
    }

    // MARK: Per-Host on/off

    @Test func enablingRegistersTheDevice() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: true, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func disablingRemovesTheDeviceEntryAndTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        await store.setNotificationsEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) == nil)
    }

    @Test func aFailedEnableDoesNotFlipTheToggle() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        guard case .failed(_, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(!settings.isRegistered)
    }

    @Test func togglingAnUnreachableHostFailsLoudlyWithoutFlipping() async throws {
        let provider = ScriptedTransportProvider(transports: [host.id: ScriptedTransport()])
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        // The Host drops off the network after the settings screen loaded.
        await provider.setTransport(nil, for: host.id)

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .failed(
                    message: "The Host is not connected.",
                    settings: .init(
                        isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func disablingAgainstAMissingPluginSurfacesAndKeepsTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        // The plugin was uninstalled on the Host after registration; `remove`
        // throws pluginNotInstalled and keeps the local key by design (#72).
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)

        await store.setNotificationsEnabled(false, for: host)

        guard case .failed(let message, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("plugin"))
        #expect(settings.isRegistered)
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func togglingToTheCurrentValueWritesNothing() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func enablingWritesTheCustomRelayURLIntoNotifyConfig() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(
            transport: transport,
            relayBaseURL: { URL(string: "https://relay.example.com") })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://relay.example.com")
    }

    @Test func enablingWithNoCustomRelayLeavesNotifyConfigAlone() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, relayBaseURL: { nil })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        #expect(await transport.replacedNotificationConfigs.isEmpty)
    }

    // MARK: Done flag

    @Test func doneToggleRewritesTheFlagOverSSH() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        let keyBefore = try #require(try keys.record(forHost: host.id)).key

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(false))
        #expect(entry["notify"]?["blocked"] == .bool(true))
        // Rewriting a flag must not rotate the Notification Key.
        #expect(try keys.record(forHost: host.id)?.key == keyBefore)
    }

    @Test func aFailedDoneToggleStaysOnTheConfirmedValue() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "read-only"))

        await store.setDoneEnabled(false, for: host)

        guard case .failed(_, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        // Not flipped: the Host still holds done=true, so the UI must too.
        #expect(settings.notify.done)
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(true))
    }

    @Test func doneToggleOnAnUnregisteredHostIsIgnored() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setDoneEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }
}
