import Foundation
import HeelerSSH
import Synchronization
import Testing

@testable import Heeler

@Suite("HeelerSSH Host Key policy")
struct HeelerSSHHostKeyPolicyTests {
    private func hostKey(algorithm: String, marker: String) -> HeelerSSH.SSHHostKey {
        var blob = Data()
        var length = UInt32(algorithm.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: algorithm.utf8)
        blob.append(contentsOf: marker.utf8)
        return HeelerSSH.SSHHostKey(algorithm: algorithm, key: blob)
    }

    @Test func firstConnectAcceptPersistsAlgorithmAwareFingerprint() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let presented = hostKey(algorithm: "ssh-ed25519", marker: "host-a")
        let asked = Mutex<[HostKeyCandidate]>([])
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { candidate in
                asked.withLock { $0.append(candidate) }
                return true
            })

        try await verifier.verify(presented)

        let expected = HostKeyFingerprint(publicKeyBlob: presented.key)
        #expect(asked.withLock { $0 }.map(\.fingerprint) == [expected])
        #expect(
            await knownHosts.fingerprint(
                host: "host.example", port: 22, algorithm: "ssh-ed25519") == expected)
    }

    @Test func firstConnectRejectPersistsNothing() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let presented = hostKey(algorithm: "ssh-ed25519", marker: "host-a")
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { _ in false })
        let fingerprint = HostKeyFingerprint(publicKeyBlob: presented.key)

        await #expect(throws: TransportError.hostKeyRejected(presented: fingerprint)) {
            try await verifier.verify(presented)
        }
        #expect(await knownHosts.fingerprints(host: "host.example", port: 22).isEmpty)
    }

    @Test func knownAlgorithmAndKeyConnectWithoutConfirmation() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let presented = hostKey(algorithm: "ssh-ed25519", marker: "host-a")
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: presented.key),
            host: "host.example",
            port: 22)
        let asked = Mutex(false)
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { _ in
                asked.withLock { $0 = true }
                return false
            })

        try await verifier.verify(presented)

        #expect(!asked.withLock { $0 })
    }

    @Test func changedKeyFailsWithoutConfirmationOrOverwrite() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(
            publicKeyBlob: hostKey(algorithm: "ssh-ed25519", marker: "trusted").key)
        let presented = hostKey(algorithm: "ssh-ed25519", marker: "changed")
        let changed = HostKeyFingerprint(publicKeyBlob: presented.key)
        await knownHosts.setFingerprint(trusted, host: "host.example", port: 22)
        let asked = Mutex(false)
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { _ in
                asked.withLock { $0 = true }
                return true
            })

        await #expect(throws: TransportError.hostKeyMismatch(known: trusted, presented: changed)) {
            try await verifier.verify(presented)
        }
        #expect(!asked.withLock { $0 })
        #expect(
            await knownHosts.fingerprint(
                host: "host.example", port: 22, algorithm: "ssh-ed25519") == trusted)
    }

    @Test func matchingLegacyRecordMigratesAlgorithmMetadata() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let presented = hostKey(algorithm: "ssh-ed25519", marker: "host-a")
        let algorithmAware = HostKeyFingerprint(publicKeyBlob: presented.key)
        let legacy = HostKeyFingerprint(digest: algorithmAware.digest)
        await knownHosts.setFingerprint(legacy, host: "host.example", port: 22)
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { _ in false })

        try await verifier.verify(presented)

        #expect(
            await knownHosts.fingerprint(
                host: "host.example", port: 22, algorithm: "ssh-ed25519")
                == algorithmAware)
        #expect(
            await knownHosts.fingerprint(
                host: "host.example", port: 22,
                algorithm: HostKeyFingerprint.unknownAlgorithm) == nil)
    }

    @Test func removedTrustedAlgorithmFailsWithoutAcceptingReplacement() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(
            publicKeyBlob: hostKey(algorithm: "ssh-ed25519", marker: "trusted").key)
        let presented = hostKey(algorithm: "ecdsa-sha2-nistp256", marker: "replacement")
        let replacement = HostKeyFingerprint(publicKeyBlob: presented.key)
        await knownHosts.setFingerprint(trusted, host: "host.example", port: 22)
        let asked = Mutex(false)
        let verifier = HeelerSSHHostKeyVerifier(
            host: "host.example",
            port: 22,
            policy: HostKeyPolicy(knownHosts: knownHosts) { _ in
                asked.withLock { $0 = true }
                return true
            })

        await #expect(
            throws: TransportError.hostKeyMismatch(known: trusted, presented: replacement)
        ) {
            try await verifier.verify(presented)
        }
        #expect(!asked.withLock { $0 })
        #expect(await knownHosts.fingerprints(host: "host.example", port: 22) == [trusted])
    }
}
