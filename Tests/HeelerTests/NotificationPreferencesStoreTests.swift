import Foundation
import Synchronization
import Testing

@testable import Heeler

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

    /// A registration file holding this Host's entry (this device token with
    /// the Host's stored key) as an older app wrote it: no `session` field
    /// unless one is given.
    private func ownEntryFile(
        for host: Host? = nil, notify: String, session: String? = nil
    ) throws -> Data {
        Data(#"{"v":1,"devices":[\#(try ownEntry(for: host, notify: notify, session: session))]}"#.utf8)
    }

    /// One device entry of that file, saving the Host's key when needed.
    private func ownEntry(
        for host: Host? = nil, notify: String, session: String? = nil
    ) throws -> String {
        let host = host ?? self.host
        let key = try keys.record(forHost: host.id)?.key ?? NotificationKeyStore.generateKey()
        try keys.save(NotificationKeyRecord(hostID: host.id, hostName: host.displayName, key: key))
        let sessionField = session.map { #","session":"\#($0)""# } ?? ""
        return #"{"token":"\#(token.hex)","key":"\#(key.base64URLEncodedString())","#
            + #""env":"sandbox","notify":\#(notify)"# + sessionField + "}"
    }

    private func owner(_ host: Host? = nil) throws -> NotificationRegistrationOwner {
        try #require(
            try NotificationRegistrationCeremony(keys: keys)
                .registrationOwner(for: host ?? self.host, deviceToken: token))
    }

    // MARK: Reflecting the Host's truth

    @Test func coreNotificationsStayUnavailableWithoutReadingOrWritingLegacyRegistration() async {
        let core = Host(address: "box.example", username: "dev", backend: .herdrCore)
        let transport = ScriptedTransport()
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [core.id: transport]),
            deviceToken: { self.token })
        store.setHosts([core])

        await store.refresh()
        await store.setNotificationsEnabled(true, for: core)

        #expect(store.states[core.id] == .unavailable(
            message: NotificationPreferencesStore.coreUnavailableMessage))
        #expect(await transport.notificationRegistrationReads == 0)
        #expect(await transport.notificationRegistration == nil)
        #expect(store.confirmedTriggers(for: core.id) == nil)
    }

    @Test(arguments: [false, true])
    func aReadFinishingAfterBackendChangeCannotRestoreLegacySettings(_ fails: Bool) async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(notify: #"{"blocked":true,"done":true}"#, session: "default"))
        if fails { await transport.setNotificationRegistrationReadFailure(.readFailed(detail: "old connection")) }
        let provider = CompletionHoldingNotificationProvider(transport: transport)
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        let hold = CancellablePhaseGate()
        await provider.holdNextCompletion(on: hold)
        let refresh = Task { await store.refresh() }
        try await hold.waitUntilEntered()
        var core = host
        core.backend = .herdrCore
        store.setHosts([core])
        await hold.release()
        await refresh.value

        #expect(store.states[host.id] == .unavailable(
            message: NotificationPreferencesStore.coreUnavailableMessage))
        #expect(store.confirmedTriggers(for: host.id) == nil)
        // A stale view cannot issue another legacy write with its old Host.
        await store.setNotificationsEnabled(false, for: host)
        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test(arguments: [false, true])
    func aWriteFinishingAfterBackendChangeCannotRestoreSettingsOrNotifyRegistration(_ fails: Bool) async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(notify: #"{"blocked":true,"done":true}"#, session: "default"))
        let provider = CompletionHoldingNotificationProvider(transport: transport)
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        await store.refresh()
        var registrations: [Host.ID] = []
        store.onRegistered = { registrations.append($0) }
        if fails { await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "old connection")) }
        let hold = CancellablePhaseGate()
        await provider.holdNextCompletion(on: hold)
        let write = Task { await store.setDoneEnabled(false, for: host) }
        try await hold.waitUntilEntered()
        #expect(store.hasPendingWrite(for: host.id))
        var core = host
        core.backend = .herdrCore
        store.setHosts([core])
        await hold.release()
        await write.value

        #expect(store.states[host.id] == .unavailable(
            message: NotificationPreferencesStore.coreUnavailableMessage))
        #expect(store.confirmedTriggers(for: host.id) == nil)
        #expect(registrations.isEmpty)
        #expect(!store.hasPendingWrite(for: host.id))
    }

    @Test(arguments: ["removed", "edited", "returned"])
    func catalogChangesInvalidateAnOldReadEvenIfTheSameHostReturns(_ change: String) async throws {
        let transport = ScriptedTransport()
        let provider = CompletionHoldingNotificationProvider(transport: transport)
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        let hold = CancellablePhaseGate()
        await provider.holdNextCompletion(on: hold)
        let refresh = Task { await store.refresh() }
        try await hold.waitUntilEntered()
        if change == "edited" {
            var edited = host
            edited.sessionName = "other"
            store.setHosts([edited])
        } else {
            store.setHosts([])
            if change == "returned" { store.setHosts([host]) }
        }
        await hold.release()
        await refresh.value
        #expect(store.states[host.id] == nil)
        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    @Test func aQueuedWriteBlocksBackendEditingBeforeItCreatesANotificationKey() async throws {
        let transport = ScriptedTransport()
        let provider = CompletionHoldingNotificationProvider(transport: transport)
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        await store.refresh()
        let hold = CancellablePhaseGate()
        await provider.holdNextBorrow(on: hold)
        let write = Task { await store.setNotificationsEnabled(true, for: host) }
        try await hold.waitUntilEntered()
        #expect(!store.hasNotificationKey(for: host.id))
        #expect(store.hasPendingWrite(for: host.id))
        await hold.release()
        await write.value
        #expect(store.hasNotificationKey(for: host.id))
        #expect(!store.hasPendingWrite(for: host.id))
    }

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
            try ownEntryFile(notify: #"{"blocked":true,"done":false}"#))
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
        #expect(
            message
                == "The Heeler plugin is missing or turned off on this Host. "
                + "See this Host's page in Hosts, then check again.")
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
        #expect(file.preferences(for: try owner()) == NotificationTriggerPreferences())
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
        #expect(!file.devices.contains { $0["token"]?.stringValue == token.hex })
        #expect(try keys.record(forHost: host.id) == nil)
    }

    @Test func aFailedEnableDoesNotFlipTheToggle() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        guard case .failed(let message, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(
            message
                == "Could not update notification settings on this Host. "
                + "Check the connection and try again.")
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

    @Test func enablingWithNoCustomRelayWritesTheProductionRelay() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, relayBaseURL: { nil })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://heeler-apns.bybee.dev")
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

    // MARK: Confirmed triggers for the in-app banner (#77)

    @Test func confirmedTriggersOfARegisteredHostAreItsFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(notify: #"{"blocked":true,"done":false}"#))
        let store = makeStore(transport: transport)
        await store.refresh()

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: false))
    }

    @Test func confirmedTriggersOfAnUnregisteredHostAreNil() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// Fail closed: before any refresh, and while the Host is unreachable,
    /// there is no confirmed truth to banner from.
    @Test func confirmedTriggersAreNilWhileTheHostsTruthIsUnknown() async throws {
        let provider = ScriptedTransportProvider(transports: [:])
        let store = makeStore(provider: provider, deviceToken: token)

        #expect(store.confirmedTriggers(for: host.id) == nil)

        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// A failed write leaves the last confirmed truth in place, and that
    /// truth keeps gating banners.
    @Test func confirmedTriggersSurviveAFailedWrite() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: true))
    }

    // MARK: Hosts on several herdr sessions of one remote user (#412)

    private let workHost = Host(
        name: "mac-studio work", address: "10.0.0.2", username: "z", sessionName: "work")

    @Test func anotherHostsEntryForThisDeviceDoesNotReadAsRegistered() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(for: workHost, notify: #"{"blocked":true,"done":true}"#, session: "work"))
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func hostsOnDifferentSessionsToggleIndependently() async throws {
        let transport = ScriptedTransport()
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(
                transports: [host.id: transport, workHost.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host, workHost])
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)
        await store.setNotificationsEnabled(true, for: workHost)
        await store.setDoneEnabled(false, for: workHost)
        await store.setNotificationsEnabled(false, for: host)
        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
        #expect(
            store.states[workHost.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 1)
        #expect(file.devices.first?["session"]?.stringValue == "work")
    }

    @Test func registeringOnAnOccupiedSessionTurnsTheDisplacedHostOff() async throws {
        let transport = ScriptedTransport()
        let tailscale = Host(name: "mac-studio ts", address: "100.64.0.2", username: "z")
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(
                transports: [host.id: transport, tailscale.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host, tailscale])
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        await store.setNotificationsEnabled(true, for: tailscale)

        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
        #expect(
            store.states[tailscale.id]
                == .idle(.init(isRegistered: true, notify: NotificationTriggerPreferences())))
    }

    // MARK: Migration on load and the registration cue

    private func makeWorkStore(transport: ScriptedTransport) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [workHost.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([workHost])
        return store
    }

    @Test(arguments: [nil, "old"] as [String?])
    func loadMovesTheEntryToTheHostsCurrentSession(_ stored: String?) async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(
                for: workHost, notify: #"{"blocked":true,"done":false}"#, session: stored))
        let store = makeWorkStore(transport: transport)

        await store.refresh()
        await store.refresh()

        let registered = NotificationPreferencesStore.HostSettings(
            isRegistered: true, notify: NotificationTriggerPreferences(blocked: true, done: false))
        #expect(store.states[workHost.id] == .idle(registered))
        #expect(await transport.replacedNotificationRegistrations.count == 1)
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.first?["session"]?.stringValue == "work")
    }

    @Test func aFailedMigrationKeepsTheReadStateAndRetriesOnTheNextRefresh() async throws {
        let transport = ScriptedTransport()
        let legacy = try ownEntryFile(for: workHost, notify: #"{"blocked":true,"done":true}"#)
        await transport.setNotificationRegistration(legacy)
        await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "read-only"))
        let store = makeWorkStore(transport: transport)

        await store.refresh()

        let registered = NotificationPreferencesStore.HostSettings(isRegistered: true, notify: NotificationTriggerPreferences())
        #expect(store.states[workHost.id] == .idle(registered))
        #expect(await transport.notificationRegistration == legacy)

        await transport.setNotificationRegistrationWriteFailure(nil)
        await store.refresh()

        #expect(store.states[workHost.id] == .idle(registered))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.first?["session"]?.stringValue == "work")
    }

    @Test func aLegacyEntryInAnotherHostsSlotReadsAsUnregisteredAfterMigration() async throws {
        let transport = ScriptedTransport()
        let theirs = try ownEntry(
            for: host, notify: #"{"blocked":true,"done":true}"#, session: "work")
        let mine = try ownEntry(for: workHost, notify: #"{"blocked":true,"done":true}"#)
        await transport.setNotificationRegistration(
            Data(#"{"v":1,"devices":[\#(theirs),\#(mine)]}"#.utf8))
        let store = makeWorkStore(transport: transport)

        await store.refresh()

        #expect(
            store.states[workHost.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 1)
        #expect(file.preferences(for: try owner(host)) != nil)
    }

    // MARK: Revoking before a Host's removal (#414)

    @Test func revokingOneHostLeavesItsSiblingOnAnotherSession() async throws {
        let transport = ScriptedTransport()
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(
                transports: [host.id: transport, workHost.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host, workHost])
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await store.setNotificationsEnabled(true, for: workHost)
        let workKey = try #require(try keys.record(forHost: workHost.id))

        await store.revokeRegistration(for: host, isConnected: true)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.count == 1)
        #expect(file.preferences(for: try owner(workHost)) != nil)
        #expect(try keys.record(forHost: workHost.id) == workKey)
        #expect(try keys.record(forHost: host.id) != nil, "the removal deletes it next")
    }

    /// A Duplicate Host (#413) on the same session that registered later
    /// already took over the entry; revoking the original writes nothing.
    @Test func revokingAHostWhoseEntryASiblingTookOverWritesNothing() async throws {
        let transport = ScriptedTransport()
        let duplicate = Host(name: "mac-studio 2", address: "10.0.0.2", username: "z")
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(
                transports: [host.id: transport, duplicate.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host, duplicate])
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await store.setNotificationsEnabled(true, for: duplicate)
        let writes = await transport.replacedNotificationRegistrations.count
        let before = await transport.notificationRegistration
        let duplicateKey = try #require(try keys.record(forHost: duplicate.id))

        await store.revokeRegistration(for: host, isConnected: true)

        #expect(await transport.replacedNotificationRegistrations.count == writes)
        #expect(await transport.notificationRegistration == before)
        let file = try NotificationRegistrationFile.decode(before)
        #expect(file.preferences(for: try owner(duplicate)) != nil)
        #expect(try keys.record(forHost: duplicate.id) == duplicateKey)
    }

    @Test(arguments: ["not connected", "no key"])
    func revokingWithoutAReachableOwnEntryTouchesNoTransport(_ missing: String) async throws {
        let transport = ScriptedTransport()
        if missing != "no key" {
            await transport.setNotificationRegistration(
                try ownEntryFile(notify: #"{"blocked":true,"done":true}"#))
        }
        let store = makeStore(transport: transport)

        await store.revokeRegistration(for: host, isConnected: missing != "not connected")

        #expect(await transport.notificationRegistrationReads == 0)
        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    /// Before APNs answers, or with notification permission withdrawn,
    /// there is no device token; the key alone still finds the entry.
    @Test func revokingWithoutADeviceTokenStillDropsTheOwnEntry() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            try ownEntryFile(notify: #"{"blocked":true,"done":true}"#))
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: nil)

        await store.revokeRegistration(for: host, isConnected: true)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.isEmpty)
        #expect(try keys.record(forHost: host.id) != nil, "the removal deletes it next")
    }

    /// The Host no longer holds this device's entry, so its toggle and the
    /// in-app banner gate read off before the key is deleted: a removal that
    /// fails at the Keychain keeps the Host with notifications off.
    @Test func aConfirmedRevokeReadsUnregisteredWhileTheKeyRemains() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        #expect(store.confirmedTriggers(for: host.id) != nil)

        await store.revokeRegistration(for: host, isConnected: true)

        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
        #expect(store.confirmedTriggers(for: host.id) == nil)
        #expect(store.hasNotificationKey(for: host.id))
    }

    /// The time limit turns a missing deadline into a failure rather than
    /// an hour-long stall.
    @Test(.timeLimit(.minutes(1)))
    func aRevokeThatNeverFinishesIsAbandonedAtTheDeadline() async throws {
        _ = try ownEntryFile(notify: #"{"blocked":true,"done":true}"#)
        let provider = StallingTransportProvider()
        let store = NotificationPreferencesStore(
            transports: provider,
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await store.revokeRegistration(
                for: host, isConnected: true, timeout: .milliseconds(50))
        }

        #expect(elapsed < .seconds(5))
        // The deadline does not wait for the borrow to begin; give it a
        // bounded moment, so a guard that skipped the revoke still fails.
        let waitStart = clock.now
        while provider.borrows == 0, clock.now - waitStart < .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.borrows == 1, "the revoke reached the stalled connection")
    }

    @Test func forgettingTheKeyReadsAsUnregistered() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        #expect(store.hasNotificationKey(for: host.id))

        try store.forgetNotificationKey(for: host.id)

        #expect(!store.hasNotificationKey(for: host.id))
        #expect(try keys.record(forHost: host.id) == nil)
        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
        await store.refresh()
        #expect(
            store.states[host.id]
                == .idle(.init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func onRegisteredFiresOnceForAConfirmedRegistration() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        var registered: [Host.ID] = []
        store.onRegistered = { registered.append($0) }
        await store.refresh()

        await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "disk full"))
        await store.setNotificationsEnabled(true, for: host)
        #expect(registered.isEmpty)

        await transport.setNotificationRegistrationWriteFailure(nil)
        await store.setNotificationsEnabled(true, for: host)
        #expect(registered == [host.id])

        await store.setNotificationsEnabled(false, for: host)
        #expect(registered == [host.id])
    }
}

/// A Host whose connection reads as up but never answers: every borrow is
/// counted, then waits until it is cancelled.
private final class StallingTransportProvider: NotificationTransportProvider {
    private let borrowCount = Mutex(0)

    var borrows: Int { borrowCount.withLock { $0 } }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        borrowCount.withLock { $0 += 1 }
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

/// Pauses after an operation has produced its old result, so tests can edit
/// the catalog before that result is delivered to the preferences store.
private actor CompletionHoldingNotificationProvider: NotificationTransportProvider {
    let transport: any Transport
    private var completionHold: CancellablePhaseGate?
    private var borrowHold: CancellablePhaseGate?

    init(transport: any Transport) { self.transport = transport }

    func holdNextCompletion(on gate: CancellablePhaseGate) { completionHold = gate }
    func holdNextBorrow(on gate: CancellablePhaseGate) { borrowHold = gate }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        let before = borrowHold
        borrowHold = nil
        let after = completionHold
        completionHold = nil
        if let before { await before.enterAndHold() }
        let result: Result<Value, any Error>
        do {
            result = .success(try await operation(transport))
        } catch {
            result = .failure(error)
        }
        if let after { await after.enterAndHold() }
        return try result.get()
    }
}
