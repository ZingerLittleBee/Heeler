import CryptoKit
import Foundation
import Testing

@testable import Heeler

@Suite("Device key store")
struct DeviceKeyStoreTests {
    @Test func generatesOnFirstUseAndReturnsTheSameKeyAfterwards() throws {
        let store = DeviceKeyStore(secrets: InMemorySecretStore())

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func persistedSeedSurvivesANewStoreInstance() throws {
        let secrets = InMemorySecretStore()

        let first = try DeviceKeyStore(secrets: secrets).loadOrCreate()
        let second = try DeviceKeyStore(secrets: secrets).loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func distinctStoresHoldDistinctKeys() throws {
        let first = try DeviceKeyStore(secrets: InMemorySecretStore()).loadOrCreate()
        let second = try DeviceKeyStore(secrets: InMemorySecretStore()).loadOrCreate()

        #expect(first.openSSHPublicKey != second.openSSHPublicKey)
    }

    @Test func explicitReplacementRecoversACorruptStoredKey() throws {
        let secrets = InMemorySecretStore()
        let account = "corrupt-device-key"
        try secrets.write(Data("not-an-ed25519-key".utf8), account: account)
        let store = DeviceKeyStore(secrets: secrets, account: account)

        #expect(throws: DeviceKeyStoreError.storedKeyCorrupt) {
            try store.loadOrCreate()
        }

        let replacement = try store.replaceStoredKey()

        #expect(try store.loadOrCreate().openSSHPublicKey == replacement.openSSHPublicKey)
    }

    @Test func concurrentLoadOrCreateGeneratesAndPersistsSingleKey() async throws {
        let secrets = WriteCountingSecretStore()
        let store = DeviceKeyStore(secrets: secrets)

        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try store.loadOrCreate().openSSHPublicKey
                }
            }
            var collected: [String] = []
            for try await key in group {
                collected.append(key)
            }
            return collected
        }

        #expect(Set(keys).count == 1)
        #expect(secrets.writeCalls == 1)
    }
}

private final class WriteCountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var writeCalls = 0

    func read(account: String) throws -> Data? {
        lock.withLock { storage[account] }
    }

    func readAll() throws -> [String: Data] {
        lock.withLock { storage }
    }

    func write(_ secret: Data, account: String) throws {
        lock.withLock {
            writeCalls += 1
            storage[account] = secret
        }
    }

    func removeSecret(account: String) throws {
        lock.withLock { storage[account] = nil }
    }
}

@Suite("RSA key store")
struct RSAKeyStoreTests {
    @Test func generatesOnFirstUseAndReturnsTheSameKeyAfterwards() throws {
        let secrets = InMemorySecretStore()
        let store = RSAKeyStore(secrets: secrets)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func persistedKeySurvivesANewStoreInstance() throws {
        let secrets = InMemorySecretStore()

        let first = try RSAKeyStore(secrets: secrets).loadOrCreate()
        let second = try RSAKeyStore(secrets: secrets).loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func explicitReplacementRecoversACorruptStoredKey() throws {
        let secrets = InMemorySecretStore()
        let account = "corrupt-rsa-key"
        try secrets.write(Data("not-an-rsa-private-key".utf8), account: account)
        let store = RSAKeyStore(secrets: secrets, account: account)

        #expect(throws: RSAKeyStoreError.storedKeyCorrupt) {
            try store.loadOrCreate()
        }

        let replacement = try store.replaceStoredKey()

        #expect(try store.loadOrCreate().openSSHPublicKey == replacement.openSSHPublicKey)
    }

    @Test func concurrentLoadOrCreateGeneratesAndPersistsSingleRSAKey() async throws {
        let secrets = WriteCountingSecretStore()
        let store = RSAKeyStore(secrets: secrets)

        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try store.loadOrCreate().openSSHPublicKey
                }
            }
            var collected: [String] = []
            for try await key in group {
                collected.append(key)
            }
            return collected
        }

        #expect(Set(keys).count == 1)
        #expect(secrets.writeCalls == 1)
    }
}

// The real Keychain works in simulator test bundles for generic passwords;
// exercise it for real rather than trusting the in-memory stand-in.
@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    private let store = KeychainSecretStore(service: "dev.bybee.heeler.tests")

    @Test func roundTripsAndRemoves() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? store.removeSecret(account: account) }

        #expect(try store.read(account: account) == nil)

        let secret = Data("s3cret".utf8)
        try store.write(secret, account: account)
        #expect(try store.read(account: account) == secret)

        try store.removeSecret(account: account)
        #expect(try store.read(account: account) == nil)
    }

    @Test func overwritesAnExistingSecret() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? store.removeSecret(account: account) }

        try store.write(Data("old".utf8), account: account)
        try store.write(Data("new".utf8), account: account)

        #expect(try store.read(account: account) == Data("new".utf8))
    }

    @Test func readAllListsEveryAccountInTheService() throws {
        let first = "test-\(UUID().uuidString)"
        let second = "test-\(UUID().uuidString)"
        defer {
            try? store.removeSecret(account: first)
            try? store.removeSecret(account: second)
        }

        try store.write(Data("a".utf8), account: first)
        try store.write(Data("b".utf8), account: second)

        let all = try store.readAll()
        #expect(all[first] == Data("a".utf8))
        #expect(all[second] == Data("b".utf8))
    }

    @Test func deviceKeyStoreOnRealKeychainReturnsAStableKey() throws {
        let account = "device-key-test-\(UUID().uuidString)"
        defer { try? store.removeSecret(account: account) }
        let keyStore = DeviceKeyStore(secrets: store, account: account)

        let first = try keyStore.loadOrCreate()
        let second = try keyStore.loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func rsaKeyStoreOnRealKeychainReturnsAStableKey() throws {
        let account = "rsa-key-test-\(UUID().uuidString)"
        defer { try? store.removeSecret(account: account) }
        let keyStore = RSAKeyStore(secrets: store, account: account)

        let first = try keyStore.loadOrCreate()
        let second = try keyStore.loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }
}
