import Foundation
import Testing

@testable import Heeler

/// Notification Registration against a real sshd (#72): the ceremony runs
/// through `SSHTransport` — plugin probe over exec, file transfer over SFTP,
/// atomic replace over exec — with the herdr CLI stubbed at the environment
/// boundary (the same seam the session-discovery e2e uses). The simulator
/// shares the host filesystem, so the "Host-side" plugin config dir is
/// asserted on directly.
@Suite(
    "Notification registration e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, SFTP, and an authorized Ed25519 test key"),
    .serialized,
    .timeLimit(.minutes(1)))
struct NotificationRegistrationE2ETests {
    private static let installedPluginListCommand =
        "printf '%s' '" + #"{"id":"cli:plugin","result":{"plugins":"#
        + #"[{"plugin_id":"herdr-mobile.pairing","enabled":true}]}}"# + "'"

    private func makeConfigDirectory() throws -> URL {
        let directory = URL(
            fileURLWithPath: "/tmp/hm-notify-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTransport(
        environment: LocalSSHTestEnvironment,
        configDirectory: URL,
        pluginListCommand: String = Self.installedPluginListCommand
    ) async throws -> SSHTransport {
        var settings = environment.makeSettings(
            socket: .absolutePath("/tmp/herdr-notify-unused.sock"))
        settings.pluginListCommand = pluginListCommand
        settings.notificationConfigDirCommand =
            "printf '__HERDR_MOBILE_PLUGIN_CONFIG_DIR__=%s\\n' '\(configDirectory.path)'"
        return try await SSHTransport.connect(settings: settings)
    }

    @Test func registerReRegisterAndRemoveRoundTrip() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let registrationURL = configDirectory.appendingPathComponent("notifications.json")
        // Another device is already registered on this Host; the ceremony
        // must fold ours in without touching that entry.
        try Data(
            (#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"production","#
                + #""notify":{"blocked":true,"done":true},"extra":"kept"}]}"#).utf8
        ).write(to: registrationURL)

        let secrets = InMemorySecretStore()
        let ceremony = NotificationRegistrationCeremony(
            keys: NotificationKeyStore(secrets: secrets))
        let hostID = UUID()
        let token = APNSDeviceToken(hex: "0a1b2c3d4e5f", environment: .sandbox)
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory)
        defer { Task { try? await transport.close() } }

        // Register: our v1 entry lands next to the existing one.
        let record = try await ceremony.register(
            hostID: hostID, hostName: "e2e-host", deviceToken: token,
            notify: NotificationTriggerPreferences(blocked: true, done: false),
            over: transport)
        var file = try NotificationRegistrationFile.decode(
            try Data(contentsOf: registrationURL))
        #expect(file.devices.count == 2)
        #expect(file.containsDevice(token: "ffff"))
        let ours = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(ours["key"]?.stringValue == record.key.base64URLEncodedString())
        #expect(ours["env"]?.stringValue == "sandbox")
        #expect(ours["notify"]?["blocked"] == .bool(true))
        #expect(ours["notify"]?["done"] == .bool(false))
        let notifyConfig = try NotificationConfigFile.decode(
            try Data(contentsOf: configDirectory.appendingPathComponent("notify.json")))
        #expect(notifyConfig.relayURL == "https://heeler-apns.bybee.dev")
        // Atomic replaces leave no temp files behind.
        #expect(
            try Set(FileManager.default.contentsOfDirectory(atPath: configDirectory.path))
                == ["notifications.json", "notify.json"])

        // Re-register: idempotent, same key, still one entry per token.
        let again = try await ceremony.register(
            hostID: hostID, hostName: "e2e-host", deviceToken: token, over: transport)
        #expect(again.key == record.key)
        file = try NotificationRegistrationFile.decode(try Data(contentsOf: registrationURL))
        #expect(file.devices.count == 2)
        let updated = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(updated["notify"]?["done"] == .bool(true))

        // Remove: our entry is gone, the other device's survives untouched.
        try await ceremony.remove(hostID: hostID, deviceToken: token, over: transport)
        file = try NotificationRegistrationFile.decode(try Data(contentsOf: registrationURL))
        #expect(!file.containsDevice(token: token.hex))
        let foreign = try #require(
            file.devices.first { $0["token"]?.stringValue == "ffff" })
        #expect(foreign["extra"]?.stringValue == "kept")
        #expect(try NotificationKeyStore(secrets: secrets).record(forHost: hostID) == nil)

        try await transport.close()
    }

    @Test func firstRegistrationCreatesTheFile() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let ceremony = NotificationRegistrationCeremony(
            keys: NotificationKeyStore(secrets: InMemorySecretStore()))
        let token = APNSDeviceToken(hex: "c0ffee", environment: .production)
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory)
        defer { Task { try? await transport.close() } }

        try await ceremony.register(
            hostID: UUID(), hostName: "e2e-host", deviceToken: token, over: transport)

        let file = try NotificationRegistrationFile.decode(
            try Data(contentsOf: configDirectory.appendingPathComponent("notifications.json")))
        #expect(file.devices.count == 1)
        #expect(file.containsDevice(token: token.hex))
        try await transport.close()
    }

    /// The #75 preference path end to end: the store's Done toggle rewrites
    /// this device's entry flag through a real SSHTransport, and the file on
    /// disk — what the notify hook actually reads — carries the new flag.
    @MainActor
    @Test func preferenceStoreRewritesTheDoneFlagOnTheHost() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let registrationURL = configDirectory.appendingPathComponent("notifications.json")
        let host = Host(name: "e2e-host", address: "127.0.0.1", username: "spike")
        let token = APNSDeviceToken(hex: "0a1b2c3d4e5f", environment: .sandbox)
        let keys = NotificationKeyStore(secrets: InMemorySecretStore())
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory)
        defer { Task { try? await transport.close() } }
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { token },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
        let file = try NotificationRegistrationFile.decode(
            try Data(contentsOf: registrationURL))
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(false))
        #expect(entry["notify"]?["blocked"] == .bool(true))
        try await transport.close()
    }

    /// The #76 custom-relay path end to end: registering with a relay URL
    /// writes `notify.json` next to the registration file through a real
    /// SSHTransport, and the config on disk — what the notify hook reads —
    /// carries the URL while keeping the plugin's own knobs.
    @Test func registerWritesTheCustomRelayURLIntoNotifyConfigOnTheHost() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let notifyURL = configDirectory.appendingPathComponent("notify.json")
        // The plugin already has its own settings; the merge must keep them.
        try Data(#"{"debounce_ms":2000,"future_knob":"kept"}"#.utf8).write(to: notifyURL)

        let ceremony = NotificationRegistrationCeremony(
            keys: NotificationKeyStore(secrets: InMemorySecretStore()))
        let token = APNSDeviceToken(hex: "c0ffee", environment: .sandbox)
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory)
        defer { Task { try? await transport.close() } }

        try await ceremony.register(
            hostID: UUID(), hostName: "e2e-host", deviceToken: token,
            relayBaseURL: URL(string: "https://relay.example.com")!, over: transport)

        let config = try NotificationConfigFile.decode(try Data(contentsOf: notifyURL))
        #expect(config.relayURL == "https://relay.example.com")
        let object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: notifyURL))
                as? [String: Any])
        #expect(object["debounce_ms"] as? Int == 2000)
        #expect(object["future_knob"] as? String == "kept")
        // The atomic replace leaves no temp files behind next to the two files.
        #expect(
            try Set(FileManager.default.contentsOfDirectory(atPath: configDirectory.path))
                == ["notifications.json", "notify.json"])
        try await transport.close()
    }

    @Test func missingPluginIsDistinguishableAndTouchesNothing() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let ceremony = NotificationRegistrationCeremony(
            keys: NotificationKeyStore(secrets: InMemorySecretStore()))
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory,
            pluginListCommand: "printf '%s' '"
                + #"{"id":"cli:plugin","result":{"plugins":[]}}"# + "'")
        defer { Task { try? await transport.close() } }

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await ceremony.register(
                hostID: UUID(), hostName: "e2e-host",
                deviceToken: APNSDeviceToken(hex: "c0ffee", environment: .sandbox),
                over: transport)
        }

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: configDirectory.path).isEmpty)
        try await transport.close()
    }

    @Test func aDisabledPluginCountsAsNotInstalled() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory,
            pluginListCommand: "printf '%s' '" + #"{"id":"cli:plugin","result":{"plugins":"#
                + #"[{"plugin_id":"herdr-mobile.pairing","enabled":false}]}}"# + "'")
        defer { Task { try? await transport.close() } }

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            _ = try await transport.readNotificationRegistration()
        }
        try await transport.close()
    }

    @Test func aBrokenPluginProbeIsDistinguishableFromAbsence() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        // `herdr` missing from the Host's PATH: the login shell fails the
        // command outright.
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory,
            pluginListCommand: "/nonexistent/herdr plugin list --json")
        defer { Task { try? await transport.close() } }

        do {
            _ = try await transport.readNotificationRegistration()
            Issue.record("a broken probe must not read as success")
        } catch let error as NotificationRegistrationError {
            guard case .pluginProbeFailed = error else {
                Issue.record("expected pluginProbeFailed, got \(error)")
                return
            }
        }
        try await transport.close()
    }

    @Test func writeFailureIsDistinguishableFromAMissingPlugin() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let configDirectory = try makeConfigDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
            try? FileManager.default.removeItem(at: configDirectory)
        }
        // Read-only config dir: the plugin resolves, the temp-file write
        // cannot land.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: configDirectory.path)
        let ceremony = NotificationRegistrationCeremony(
            keys: NotificationKeyStore(secrets: InMemorySecretStore()))
        let transport = try await makeTransport(
            environment: environment, configDirectory: configDirectory)
        defer { Task { try? await transport.close() } }

        do {
            try await ceremony.register(
                hostID: UUID(), hostName: "e2e-host",
                deviceToken: APNSDeviceToken(hex: "c0ffee", environment: .sandbox),
                over: transport)
            Issue.record("a failed write must not read as success")
        } catch let error as NotificationRegistrationError {
            guard case .writeFailed = error else {
                Issue.record("expected writeFailed, got \(error)")
                return
            }
        }
        try await transport.close()
    }
}
