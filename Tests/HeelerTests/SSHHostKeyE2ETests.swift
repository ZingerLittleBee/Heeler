import Foundation
import Synchronization
import Testing

@testable import Heeler

// TOFU host key policy (#2) exercised against the real localhost sshd: the
// fingerprint the validator sees is sshd's actual host key. No herdr socket
// is involved — connect authenticates but sends nothing.
@Suite(
    "TOFU host key e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"))
struct SSHHostKeyE2ETests {
    @Test func firstConnectAsksForConfirmationAndPersistsOnAccept() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let seen = Mutex<[HostKeyCandidate]>([])
        let policy = HostKeyPolicy(knownHosts: knownHosts) { candidate in
            seen.withLock { $0.append(candidate) }
            return true
        }

        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath("/tmp/herdr-irrelevant.sock"), hostKeyPolicy: policy))
        try await transport.close()

        let candidates = seen.withLock { $0 }
        #expect(candidates.map(\.host) == [environment.host])
        #expect(candidates.map(\.port) == [environment.port])
        let stored = await knownHosts.fingerprint(host: environment.host, port: environment.port)
        #expect(stored != nil)
        #expect(stored == candidates.first?.fingerprint)
    }

    @Test func knownFingerprintConnectsWithoutConfirmation() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()

        // First connect: accept and persist.
        let first = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath("/tmp/herdr-irrelevant.sock"),
                hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in true }))
        try await first.close()

        // Second connect against the same store must not ask again.
        let askedAgain = Mutex(false)
        let second = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath("/tmp/herdr-irrelevant.sock"),
                hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in
                    askedAgain.withLock { $0 = true }
                    return false
                }))
        try await second.close()

        #expect(askedAgain.withLock { $0 } == false)
    }

    @Test func rejectedFirstConnectFailsWithoutPersisting() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let seen = Mutex<[HostKeyCandidate]>([])
        let policy = HostKeyPolicy(knownHosts: knownHosts) { candidate in
            seen.withLock { $0.append(candidate) }
            return false
        }

        do {
            let transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"), hostKeyPolicy: policy))
            try await transport.close()
            Issue.record("connect succeeded despite rejected host key")
        } catch let error as TransportError {
            let presented = try #require(seen.withLock { $0 }.first?.fingerprint)
            #expect(error == .hostKeyRejected(presented: presented))
        }

        #expect(await knownHosts.fingerprint(host: environment.host, port: environment.port) == nil)
    }

    @Test func changedHostKeyHardFailsWithoutAskingOrOverwriting() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let wrongFingerprint = HostKeyFingerprint(publicKeyBlob: Data("not-sshds-key".utf8))
        await knownHosts.setFingerprint(
            wrongFingerprint, host: environment.host, port: environment.port)
        let asked = Mutex(false)
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in
            asked.withLock { $0 = true }
            return true
        }

        do {
            let transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"), hostKeyPolicy: policy))
            try await transport.close()
            Issue.record("connect succeeded despite a changed host key")
        } catch let error as TransportError {
            guard case .hostKeyMismatch(let known, let presented) = error else {
                Issue.record("expected hostKeyMismatch, got \(error)")
                return
            }
            #expect(known == wrongFingerprint)
            #expect(presented != wrongFingerprint)
        }

        // A mismatch must never ask the user or touch the stored fingerprint.
        #expect(asked.withLock { $0 } == false)
        let stored = await knownHosts.fingerprint(host: environment.host, port: environment.port)
        #expect(stored == wrongFingerprint)
    }
}

// Connect failures that need no live sshd.
@Suite("SSH connect failure taxonomy")
struct SSHConnectFailureTests {
    @Test func unreachableHostMapsToSSHUnreachable() async throws {
        // Nothing listens on port 1 (privileged, unused): connection refused.
        let settings = SSHTransportSettings(
            host: "127.0.0.1",
            port: 1,
            username: "nobody",
            credentials: .password("irrelevant"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession,
            socatPath: "/opt/homebrew/bin/socat")

        do {
            let transport = try await SSHTransport.connect(settings: settings)
            try await transport.close()
            Issue.record("connect succeeded against a dead port")
        } catch let error as TransportError {
            guard case .sshUnreachable = error else {
                Issue.record("expected sshUnreachable, got \(error)")
                return
            }
        }
    }
}
