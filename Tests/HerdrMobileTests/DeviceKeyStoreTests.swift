import CryptoKit
import Foundation
import Testing

@testable import HerdrMobile

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
}

// The real Keychain works in simulator test bundles for generic passwords;
// exercise it for real rather than trusting the in-memory stand-in.
@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    private let store = KeychainSecretStore(service: "dev.herdr.mobile.tests")

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

    @Test func deviceKeyStoreOnRealKeychainReturnsAStableKey() throws {
        let account = "device-key-test-\(UUID().uuidString)"
        defer { try? store.removeSecret(account: account) }
        let keyStore = DeviceKeyStore(secrets: store, account: account)

        let first = try keyStore.loadOrCreate()
        let second = try keyStore.loadOrCreate()

        #expect(first.openSSHPublicKey == second.openSSHPublicKey)
    }
}
