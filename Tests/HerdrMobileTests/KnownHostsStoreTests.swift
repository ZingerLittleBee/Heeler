import Foundation
import Testing

@testable import HerdrMobile

@Suite("Known hosts store")
struct KnownHostsStoreTests {
    private let fingerprint = HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))
    private let otherFingerprint = HostKeyFingerprint(publicKeyBlob: Data("blob-b".utf8))

    @Test func inMemoryStoreKeysFingerprintsByHostAndPort() async throws {
        let store = InMemoryKnownHostsStore()

        #expect(await store.fingerprint(host: "a.example", port: 22) == nil)

        await store.setFingerprint(fingerprint, host: "a.example", port: 22)
        await store.setFingerprint(otherFingerprint, host: "a.example", port: 2222)

        #expect(await store.fingerprint(host: "a.example", port: 22) == fingerprint)
        #expect(await store.fingerprint(host: "a.example", port: 2222) == otherFingerprint)
        #expect(await store.fingerprint(host: "b.example", port: 22) == nil)
    }

    @Test func userDefaultsStorePersistsAcrossInstances() async throws {
        let suiteName = "hm-known-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await UserDefaultsKnownHostsStore(defaults: defaults)
            .setFingerprint(fingerprint, host: "a.example", port: 22)

        let reloaded = UserDefaultsKnownHostsStore(defaults: defaults)
        #expect(await reloaded.fingerprint(host: "a.example", port: 22) == fingerprint)
        #expect(await reloaded.fingerprint(host: "a.example", port: 2222) == nil)
    }

    @Test func userDefaultsStoreOverwritesAChangedFingerprint() async throws {
        let suiteName = "hm-known-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsKnownHostsStore(defaults: defaults)

        await store.setFingerprint(fingerprint, host: "a.example", port: 22)
        await store.setFingerprint(otherFingerprint, host: "a.example", port: 22)

        #expect(await store.fingerprint(host: "a.example", port: 22) == otherFingerprint)
    }
}
