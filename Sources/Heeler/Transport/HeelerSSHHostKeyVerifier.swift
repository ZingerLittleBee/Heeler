import Foundation
import HeelerSSH

/// Applies the app-owned TOFU policy to Host Keys surfaced by either SSH
/// backend during the migration. Authentication must not begin until this
/// verifier returns successfully.
struct HeelerSSHHostKeyVerifier: Sendable {
    private let host: String
    private let port: Int
    private let policy: HostKeyPolicy

    init(host: String, port: Int, policy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.policy = policy
    }

    func verify(_ hostKey: HeelerSSH.SSHHostKey) async throws(TransportError) {
        if let failure = await failure(publicKeyBlob: hostKey.key) {
            throw failure
        }
    }

    func verify(publicKeyBlob: Data) async throws(TransportError) {
        if let failure = await failure(publicKeyBlob: publicKeyBlob) {
            throw failure
        }
    }

    func failure(publicKeyBlob: Data) async -> TransportError? {
        let fingerprint = HostKeyFingerprint(publicKeyBlob: publicKeyBlob)
        if let known = await policy.knownHosts.fingerprint(
            host: host,
            port: port,
            algorithm: fingerprint.algorithm)
        {
            guard known.digest == fingerprint.digest else {
                return .hostKeyMismatch(known: known, presented: fingerprint)
            }
            if known.algorithm == HostKeyFingerprint.unknownAlgorithm {
                // Matching a pre-v2 digest proves its negotiated algorithm.
                await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
            }
            return nil
        }

        let previouslyTrusted = await policy.knownHosts.fingerprints(host: host, port: port)
        if let known = previouslyTrusted.first {
            // A trusted endpoint presenting another algorithm means its
            // previous algorithm disappeared from negotiation. Do not turn
            // that security change into a fresh first-connect prompt.
            return .hostKeyMismatch(known: known, presented: fingerprint)
        }

        let candidate = HostKeyCandidate(host: host, port: port, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            return .hostKeyRejected(presented: fingerprint)
        }
        // Persist before authentication, matching OpenSSH known_hosts: bad
        // credentials on the same Host must not cause a second trust prompt.
        await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
        return nil
    }
}
