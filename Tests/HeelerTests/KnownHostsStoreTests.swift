import Foundation
import Testing

@testable import Heeler

@Suite("Known hosts store")
struct KnownHostsStoreTests {
    private let fingerprint = HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))
    private let otherFingerprint = HostKeyFingerprint(publicKeyBlob: Data("blob-b".utf8))

    private func fingerprint(algorithm: String, marker: String) -> HostKeyFingerprint {
        var blob = Data()
        var length = UInt32(algorithm.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: algorithm.utf8)
        blob.append(contentsOf: marker.utf8)
        return HostKeyFingerprint(publicKeyBlob: blob)
    }

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

        let original = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))
        await original.setFingerprint(fingerprint, host: "a.example", port: 22)

        let reloaded = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))
        #expect(await reloaded.fingerprint(host: "a.example", port: 22) == fingerprint)
        #expect(await reloaded.fingerprint(host: "a.example", port: 2222) == nil)
    }

    @Test func userDefaultsStoreOverwritesAChangedFingerprint() async throws {
        let suiteName = "hm-known-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))

        await store.setFingerprint(fingerprint, host: "a.example", port: 22)
        await store.setFingerprint(otherFingerprint, host: "a.example", port: 22)

        #expect(await store.fingerprint(host: "a.example", port: 22) == otherFingerprint)
    }

    @Test func oneEndpointRetainsFingerprintsForMultipleAlgorithms() async throws {
        let store = InMemoryKnownHostsStore()
        let ed25519 = fingerprint(algorithm: "ssh-ed25519", marker: "ed")
        let ecdsa = fingerprint(algorithm: "ecdsa-sha2-nistp256", marker: "ec")

        await store.setFingerprint(ed25519, host: "a.example", port: 22)
        await store.setFingerprint(ecdsa, host: "a.example", port: 22)

        #expect(
            await store.fingerprint(
                host: "a.example", port: 22, algorithm: "ssh-ed25519") == ed25519)
        #expect(
            await store.fingerprint(
                host: "a.example", port: 22, algorithm: "ecdsa-sha2-nistp256") == ecdsa)
    }

    @Test func persistentStoreRetainsMultipleAlgorithmsAcrossInstances() async throws {
        let suiteName = "hm-known-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))
        let ed25519 = fingerprint(algorithm: "ssh-ed25519", marker: "ed")
        let ecdsa = fingerprint(algorithm: "ecdsa-sha2-nistp256", marker: "ec")

        await original.setFingerprint(ed25519, host: "a.example", port: 22)
        await original.setFingerprint(ecdsa, host: "a.example", port: 22)

        let reloaded = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))
        #expect(
            await reloaded.fingerprint(
                host: "a.example", port: 22, algorithm: "ssh-ed25519") == ed25519)
        #expect(
            await reloaded.fingerprint(
                host: "a.example", port: 22, algorithm: "ecdsa-sha2-nistp256") == ecdsa)
    }

    @Test func concurrentPersistentWritesDoNotLoseOtherHosts() async throws {
        let suiteName = "hm-known-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try #require(UserDefaultsKnownHostsStore(suiteName: suiteName))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let fingerprint = fingerprint(
                        algorithm: "ssh-ed25519", marker: "host-\(index)")
                    await store.setFingerprint(
                        fingerprint, host: "host-\(index).example", port: 22)
                }
            }
        }

        for index in 0..<50 {
            #expect(
                await store.fingerprint(
                    host: "host-\(index).example", port: 22,
                    algorithm: "ssh-ed25519") != nil)
        }
    }
}
