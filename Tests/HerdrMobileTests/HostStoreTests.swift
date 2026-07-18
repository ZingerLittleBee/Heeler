import Foundation
import Testing

@testable import HerdrMobile

@Suite("Host model")
struct HostTests {
    @Test func socketLocationDefaultsWhenSessionNameIsBlank() {
        var host = Host.fixture()
        host.sessionName = ""
        #expect(host.socketLocation == .defaultSession)
        host.sessionName = "   "
        #expect(host.socketLocation == .defaultSession)
    }

    @Test func socketLocationUsesTrimmedNamedSession() {
        var host = Host.fixture()
        host.sessionName = " work "
        #expect(host.socketLocation == .namedSession("work"))
    }

    @Test func displayNameFallsBackToUserAtAddress() {
        var host = Host.fixture(name: "", address: "box.example", username: "dev")
        #expect(host.displayName == "dev@box.example")
        host.name = "Workbox"
        #expect(host.displayName == "Workbox")
    }
}

@MainActor
@Suite("Host store")
struct HostStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func addPersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let host = Host.fixture(name: "Workbox")

        try HostStore(defaults: defaults, secrets: secrets).add(host)

        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.hosts == [host])
    }

    @Test func updateReplacesTheStoredHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture()
        try store.add(host)

        host.address = "renamed.example"
        try store.update(host)

        #expect(store.hosts == [host])
    }

    @Test func updateUnknownHostThrows() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(throws: HostStoreError.unknownHost) {
            try store.update(Host.fixture())
        }
    }

    @Test func removeDeletesHostAndItsPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        try store.remove(host.id)

        #expect(store.hosts.isEmpty)
        #expect(try store.password(for: host) == nil)
    }

    @Test func passwordRoundTripsThroughTheSecretStore() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = Host.fixture(authMethod: .password)

        try store.add(host, password: "hunter2")

        #expect(try store.password(for: host) == "hunter2")
        // The catalog record itself never carries the secret.
        #expect(defaults.data(forKey: "hosts").map { String(decoding: $0, as: UTF8.self) }?
            .contains("hunter2") == false)
    }

    @Test func editKeepingPasswordFieldEmptyPreservesTheStoredPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        host.port = 2222
        try store.update(host, password: nil)

        #expect(try store.password(for: host) == "hunter2")
    }

    @Test func switchingToDeviceKeyDeletesTheStoredPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        host.authMethod = .deviceKey
        try store.update(host)

        #expect(try store.password(for: host) == nil)
    }
}

extension Host {
    static func fixture(
        id: UUID = UUID(),
        name: String = "",
        address: String = "host.example",
        username: String = "dev",
        authMethod: AuthMethod = .deviceKey
    ) -> Host {
        Host(id: id, name: name, address: address, username: username, authMethod: authMethod)
    }
}
