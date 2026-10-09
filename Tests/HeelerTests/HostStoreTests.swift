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

    private static let endpointSocket =
        "/Users/ada/Library/Application Support/Example/herdr/herdr.sock"
    private static let endpointLauncher = "/Users/ada/Library/Application Support/Example/bin/herdr"

    /// Hosts saved before Pairing Code v2 have no endpoint and keep their
    /// session socket.
    @Test func hostWithoutEndpointKeyDecodesWithoutAnEndpoint() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Old","address":"old.example","port":22,
             "username":"dev","authMethod":"deviceKey","sessionName":"work"}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))

        #expect(host.herdrEndpoint == nil)
        #expect(host.socketLocation == .namedSession("work"))
    }

    @Test func endpointDecodesAndWinsOverTheSessionName() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"","address":"studio.local","port":22,
             "username":"ada","authMethod":"deviceKey","sessionName":"work",
             "herdrEndpoint":{"socketPath":"\(Self.endpointSocket)",
             "executablePath":"\(Self.endpointLauncher)"}}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))

        #expect(host.herdrEndpoint?.socketPath == Self.endpointSocket)
        #expect(host.herdrEndpoint?.executablePath == Self.endpointLauncher)
        #expect(host.socketLocation == .absolutePath(Self.endpointSocket))
    }

    /// A stored endpoint is re-validated: a value that breaks the v2 rules
    /// never reaches a connection.
    @Test func invalidEndpointFailsTheHostDecode() {
        let json = """
            {"id":"\(UUID().uuidString)","name":"","address":"studio.local","port":22,
             "username":"ada","authMethod":"deviceKey",
             "herdrEndpoint":{"socketPath":"/tmp/custom.sock","executablePath":"/opt/bin/herdr"}}
            """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        }
    }

    @Test func endpointRoundTripsAndAHostWithoutOneWritesNoKey() throws {
        let plainFields = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(Host.fixture()))
                as? [String: Any])
        #expect(plainFields["herdrEndpoint"] == nil)

        let endpoint = try #require(
            HerdrEndpoint(socketPath: Self.endpointSocket, executablePath: Self.endpointLauncher))
        let paired = Host(address: "studio.local", username: "ada", herdrEndpoint: endpoint)
        let decoded = try JSONDecoder().decode(Host.self, from: try JSONEncoder().encode(paired))

        #expect(decoded == paired)
    }

    /// Spaces are fine; the default and a named session socket in herdr's
    /// layout name the session the endpoint's hooks report.
    @Test(arguments: [
        ("/Users/ada/Library/Application Support/Example/herdr/herdr.sock", ""),
        ("/Users/ada/Library/Application Support/Example/herdr/sessions/work/herdr.sock", "work"),
        ("/srv/herdr/sessions/herdr/herdr.sock", "herdr"),
    ])
    func endpointAcceptsHerdrLayoutSockets(socketPath: String, session: String) throws {
        let endpoint = try #require(
            HerdrEndpoint(socketPath: socketPath, executablePath: Self.endpointLauncher))

        #expect(endpoint.socketPath == socketPath)
        #expect(endpoint.executablePath == Self.endpointLauncher)
        #expect(endpoint.session == session)
    }

    /// Each socket breaks one v2 rule; the launcher is valid.
    @Test(arguments: [
        "",
        "herdr/herdr.sock",
        "/Users/ada/it's/herdr/herdr.sock",
        "/Users/ada/back\\slash/herdr/herdr.sock",
        "/Users/ada/new\nline/herdr/herdr.sock",
        "/Users/ada/delete\u{7F}/herdr/herdr.sock",
        "/tmp/custom.sock",
        "/Users/ada/.config/herdr-dev/herdr.sock",
        "/Users/ada/.config/herdr/sessions/bad name/herdr.sock",
        "/Users/ada/.config/herdr/sessions/../herdr.sock",
    ])
    func endpointRejectsSocketsThatBreakTheV2Rules(socketPath: String) {
        #expect(HerdrEndpoint(socketPath: socketPath, executablePath: Self.endpointLauncher) == nil)
    }

    /// Each launcher breaks one v2 rule; the socket is valid.
    @Test(arguments: [
        "",
        "bin/herdr",
        "/opt/it's/herdr",
        "/opt/back\\slash/herdr",
        "/opt/bin/herdr\n",
        "/opt/bin/her\tdr",
    ])
    func endpointRejectsLaunchersThatBreakTheV2Rules(executablePath: String) {
        #expect(
            HerdrEndpoint(socketPath: Self.endpointSocket, executablePath: executablePath) == nil)
    }

    /// macOS `sun_path` holds 103 bytes plus the NUL, counted in UTF-8.
    @Test func endpointSocketStopsAtTheSunPathLimit() {
        let limit = HerdrEndpoint.maximumSocketPathUTF8Length
        let longest = Self.layoutSocket(padding: String(repeating: "a", count: limit - 18))
        let tooLong = Self.layoutSocket(padding: String(repeating: "a", count: limit - 17))
        // 61 characters, 104 bytes.
        let multiByte = Self.layoutSocket(padding: String(repeating: "\u{E9}", count: 43))

        #expect(longest.utf8.count == limit)
        #expect(HerdrEndpoint(socketPath: longest, executablePath: Self.endpointLauncher) != nil)
        #expect(tooLong.utf8.count == limit + 1)
        #expect(HerdrEndpoint(socketPath: tooLong, executablePath: Self.endpointLauncher) == nil)
        #expect(multiByte.count < limit && multiByte.utf8.count > limit)
        #expect(HerdrEndpoint(socketPath: multiByte, executablePath: Self.endpointLauncher) == nil)
    }

    /// `/<padding>/herdr/herdr.sock`: the default session's layout.
    private static func layoutSocket(padding: String) -> String {
        "/\(padding)/herdr/herdr.sock"
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

    private func persistedCatalogVersion(in defaults: UserDefaults) throws -> Int? {
        let data = try #require(defaults.data(forKey: "hosts"))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return catalog["version"] as? Int
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

    @Test func endpointHostRoundTripsThroughTheStore() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let endpoint = try #require(
            HerdrEndpoint(
                socketPath:
                    "/Users/dev/Library/Application Support/Example/herdr/sessions/work/herdr.sock",
                executablePath: "/Users/dev/Library/Application Support/Example/bin/herdr"))
        let host = Host(
            name: "Studio app", address: "studio.local", username: "dev", herdrEndpoint: endpoint)

        try HostStore(defaults: defaults, secrets: secrets).add(host)

        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.hosts == [host])
        let stored = try #require(
            persistedHost(id: host.id, in: defaults)["herdrEndpoint"] as? [String: Any])
        #expect(stored["socketPath"] as? String == endpoint.socketPath)
        #expect(stored["executablePath"] as? String == endpoint.executablePath)
        #expect(try persistedCatalogVersion(in: defaults) == 1)
    }

    /// Hosts that predate Pairing Code v2 keep their stored shape: loading
    /// leaves the bytes alone and a later save adds no endpoint key.
    @Test func hostWithoutEndpointKeepsItsStoredShape() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let id = UUID()
        let catalog = Data("""
            {"version":1,"hosts":[
              {"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
               "username":"dev","authMethod":"deviceKey","sessionName":"work",
               "jumpAddress":"","jumpPort":22,"jumpUsername":""}
            ]}
            """.utf8)
        defaults.set(catalog, forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = try #require(store.hosts.first)
        #expect(host.herdrEndpoint == nil)
        #expect(defaults.data(forKey: "hosts") == catalog)

        host.name = "Edited"
        try store.update(host)

        let keys = try Set(persistedHost(id: id, in: defaults).keys)
        #expect(keys == [
            "id", "name", "address", "port", "username", "authMethod", "sessionName",
            "jumpAddress", "jumpPort", "jumpUsername",
        ])
        #expect(try persistedCatalogVersion(in: defaults) == 1)
    }

    /// An endpoint this build cannot read hides only its Host, as an unknown
    /// authentication method does, instead of connecting that Host to the
    /// user's own herdr; the raw entry survives later writes.
    @Test func unreadableEndpointSkipsOnlyThatHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let firstID = UUID()
        let unreadableID = UUID()
        let wrongTypeID = UUID()
        let nullEndpointID = UUID()
        let catalog = Data("""
            {"version":1,"hosts":[
              {"id":"\(firstID.uuidString)","name":"First","address":"first.example",
               "port":22,"username":"dev","authMethod":"deviceKey"},
              {"id":"\(unreadableID.uuidString)","name":"Custom","address":"custom.example",
               "port":22,"username":"dev","authMethod":"deviceKey",
               "herdrEndpoint":{"socketPath":"/tmp/custom.sock","executablePath":"/opt/bin/herdr"}},
              {"id":"\(wrongTypeID.uuidString)","name":"Future","address":"future.example",
               "port":22,"username":"dev","authMethod":"deviceKey",
               "herdrEndpoint":"future-endpoint"},
              {"id":"\(nullEndpointID.uuidString)","name":"Null","address":"null.example",
               "port":22,"username":"dev","authMethod":"password","herdrEndpoint":null}
            ]}
            """.utf8)
        defaults.set(catalog, forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.map(\.id) == [firstID, nullEndpointID])
        #expect(store.hosts.compactMap(\.herdrEndpoint).isEmpty)
        #expect(store.catalogLoadError == nil)
        #expect(defaults.data(forKey: "hosts") == catalog)

        let added = Host.fixture(name: "Added")
        try store.add(added)

        let preserved = try #require(
            persistedHost(id: unreadableID, in: defaults)["herdrEndpoint"] as? [String: Any])
        #expect(preserved["socketPath"] as? String == "/tmp/custom.sock")
        #expect(preserved["executablePath"] as? String == "/opt/bin/herdr")
        #expect(try persistedHost(id: wrongTypeID, in: defaults)["herdrEndpoint"] as? String
            == "future-endpoint")
        #expect(try persistedHostIDs(in: defaults)
            == [firstID, unreadableID, wrongTypeID, nullEndpointID, added.id])
        #expect(try persistedCatalogVersion(in: defaults) == 1)
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

    @Test func duplicatingAPasswordHostStoresItsOwnCopyOfThePassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let original = Host.fixture(authMethod: .password)
        try store.add(original, password: "hunter2")

        let draft = HostDraft(
            duplicating: original, password: try store.password(for: original),
            existingNames: store.hosts.map(\.displayName))
        let copy = try #require(draft.makeHost())
        try store.add(copy, password: draft.passwordUpdate)
        try store.remove(original.id)

        #expect(store.hosts.map(\.id) == [copy.id])
        #expect(try store.password(for: copy) == "hunter2")
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
