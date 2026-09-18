import Foundation
import Synchronization
import Testing

@testable import Heeler

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

    /// Hosts serialized before ADR 0011 carry a `socatPath` the product
    /// no longer has (ADR 0011). It must never fail a decode — not even when it
    /// holds a value the old validation would have rejected — and the next save
    /// must drop it rather than carry a dead field forward forever.
    @Test func obsoleteSocatFieldDecodesAndIsNotWrittenBack() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Old","address":"old.example","port":22,
             "username":"dev","authMethod":"deviceKey","socatPath":"socat"}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))
        #expect(host.address == "old.example")

        let fields = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(host)) as? [String: Any])
        #expect(fields["socatPath"] == nil)
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

    private func persistedHost(
        id: UUID, in defaults: UserDefaults
    ) throws -> [String: Any] {
        try #require(persistedHosts(in: defaults).first {
            $0["id"] as? String == id.uuidString
        })
    }

    private func persistedHosts(in defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: "hosts"))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["hosts"] as? [[String: Any]])
    }

    private func persistedHostIDs(in defaults: UserDefaults) throws -> [UUID] {
        try persistedHosts(in: defaults).map { host in
            let id = try #require(host["id"] as? String)
            return try #require(UUID(uuidString: id))
        }
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

    @Test func legacyCatalogMissingNewFieldsMigratesWithDefaults() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let id = UUID()
        let legacy = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey"}]
            """
        defaults.set(Data(legacy.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        let host = try #require(store.hosts.first)
        #expect(host.sessionName == "")
        // Hosts saved before jump-host support must keep connecting directly.
        #expect(!host.usesJumpHost)
        #expect(host.jumpPort == 22)
    }

    @Test func legacyCatalogMigrationPreservesAnUnknownAuthHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let knownID = UUID()
        let unknownID = UUID()
        let legacy = Data("""
            [
              {"id":"\(knownID.uuidString)","name":"Known","address":"known.example",
               "port":22,"username":"dev","authMethod":"deviceKey"},
              {"id":"\(unknownID.uuidString)","name":"Future","address":"future.example",
               "port":22,"username":"dev","authMethod":"futureKey","futureField":42}
            ]
            """.utf8)
        defaults.set(legacy, forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.map(\.id) == [knownID])
        #expect(store.catalogLoadError == nil)
        let futureField = try #require(
            persistedHost(id: unknownID, in: defaults)["futureField"] as? NSNumber)
        #expect(futureField.intValue == 42)
        #expect(try persistedHostIDs(in: defaults) == [knownID, unknownID])
    }

    @Test func unknownAuthMethodSkipsOnlyThatHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let firstID = UUID()
        let unknownID = UUID()
        let secondID = UUID()
        let catalog = Data("""
            {"version":1,"hosts":[
              {"id":"\(firstID.uuidString)","name":"First","address":"first.example",
               "port":22,"username":"dev","authMethod":"deviceKey"},
              {"id":"\(unknownID.uuidString)","name":"Future","address":"future.example",
               "port":22,"username":"dev","authMethod":"hardwareBackedKey",
               "futureField":"preserve-me"},
              {"id":"\(secondID.uuidString)","name":"Second","address":"second.example",
               "port":22,"username":"dev","authMethod":"password"}
            ]}
            """.utf8)
        defaults.set(catalog, forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.map(\.id) == [firstID, secondID])
        #expect(store.catalogLoadError == nil)
        // Loading an older build must not rewrite the future Host out of the
        // persisted catalog merely because it cannot display that entry.
        #expect(defaults.data(forKey: "hosts") == catalog)

        let added = Host.fixture(name: "Added")
        try store.add(added)
        #expect(try persistedHost(id: unknownID, in: defaults)["futureField"] as? String
            == "preserve-me")
        #expect(try persistedHostIDs(in: defaults) == [firstID, unknownID, secondID, added.id])

        var first = try #require(store.hosts.first { $0.id == firstID })
        first.name = "Edited"
        try store.update(first)
        #expect(try persistedHost(id: unknownID, in: defaults)["authMethod"] as? String
            == "hardwareBackedKey")
        #expect(try persistedHostIDs(in: defaults) == [firstID, unknownID, secondID, added.id])

        try store.remove(secondID)
        #expect(try persistedHost(id: unknownID, in: defaults)["futureField"] as? String
            == "preserve-me")
        #expect(try persistedHostIDs(in: defaults) == [firstID, unknownID, added.id])
    }

    @Test func malformedKnownAuthHostStillMakesTheCatalogUnreadable() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let catalog = Data("""
            {"version":1,"hosts":[
              {"id":"\(UUID().uuidString)","name":"Broken","address":"broken.example",
               "port":"twenty-two","username":"dev","authMethod":"deviceKey"}
            ]}
            """.utf8)
        defaults.set(catalog, forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.isEmpty)
        #expect(store.catalogLoadError == .catalogUnreadable)
        #expect(defaults.data(forKey: "hosts") == catalog)
    }

    @Test func corruptCatalogCannotBeSilentlyOverwritten() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "hosts")
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(throws: HostStoreError.catalogUnreadable) {
            try store.add(Host.fixture())
        }
        #expect(defaults.data(forKey: "hosts") == corrupt)
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

    @Test func removalRequestRequiresExplicitConfirmation() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(name: "Workbox", authMethod: .password)
        try store.add(host, password: "hunter2")
        let removal = HostRemovalStore(store: store)

        removal.requestRemoval([host.id])

        #expect(store.hosts == [host])
        #expect(try store.password(for: host) == "hunter2")
        let request = try #require(removal.pendingRequest)
        #expect(request.title == "Remove Workbox?")
        #expect(request.message.contains("Keychain"))
        #expect(request.message.contains("cannot be undone"))

        removal.cancelRemoval()
        #expect(removal.pendingRequest == nil)
        #expect(store.hosts == [host])

        removal.requestRemoval([host.id])
        removal.confirmRemoval(try #require(removal.pendingRequest))

        #expect(removal.pendingRequest == nil)
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

    @Test func switchingToRSAKeyDeletesTheStoredPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        host.authMethod = .rsaKey
        try store.update(host)

        #expect(try store.password(for: host) == nil)
    }

    @Test func removalFailureStaysVisibleAndKeepsTheHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = RemovalFailingSecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")
        secrets.failRemovals()
        let removal = HostRemovalStore(store: store)

        removal.requestRemoval([host.id])
        removal.confirmRemoval(try #require(removal.pendingRequest))

        #expect(store.hosts == [host])
        #expect(removal.errorMessage != nil)
        removal.dismissError()
        #expect(removal.errorMessage == nil)
    }
}

private final class RemovalFailingSecretStore: SecretStore {
    private let shouldFailRemoval = Mutex(false)

    func failRemovals() {
        shouldFailRemoval.withLock { $0 = true }
    }

    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}

    func removeSecret(account: String) throws {
        if shouldFailRemoval.withLock({ $0 }) {
            throw KeychainError.unexpectedStatus(-1)
        }
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
