import Foundation
import HeelerSSH

/// Applies the app-owned TOFU policy to Host Keys surfaced by the SSH
/// transport. Authentication must not begin until this verifier returns
/// successfully.
///
/// With `.host` trust, the fingerprints live under the Host's id rather
/// than the endpoint dialled. A Host whose id holds none yet adopts what its
/// endpoint was trusted with before Routes (ADR 0022), so upgrading never
/// asks again for a key the user already confirmed.
struct HeelerSSHHostKeyVerifier: Sendable {
    /// The endpoint dialled, as the first-connect prompt shows it.
    private let endpointHost: String
    private let endpointPort: Int
    /// Where the fingerprints are read and written.
    private let host: String
    private let port: Int
    private let adoptsEndpointTrust: Bool
    private let policy: HostKeyPolicy

    init(host: String, port: Int, trust: HostKeyTrust = .endpoint, policy: HostKeyPolicy) {
        endpointHost = host
        endpointPort = port
        let key = trust.storageKey(host: host, port: port)
        self.host = key.host
        self.port = key.port
        adoptsEndpointTrust = trust != .endpoint
        self.policy = policy
    }

    func verify(_ hostKey: HeelerSSH.SSHHostKey) async throws(TransportError) {
        if let failure = await failure(publicKeyBlob: hostKey.key) {
            throw failure
        }
    }

    private func failure(publicKeyBlob: Data) async -> TransportError? {
        if adoptsEndpointTrust {
            await adoptEndpointTrust()
        }
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

        let candidate = HostKeyCandidate(
            host: endpointHost, port: endpointPort, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            return .hostKeyRejected(presented: fingerprint)
        }
        // Persist before authentication, matching OpenSSH known_hosts: bad
        // credentials on the same Host must not cause a second trust prompt.
        await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
        return nil
    }

    /// Copies the endpoint's fingerprints to the Host's key when the Host
    /// has none of its own yet. Only a Host saved before Routes has trust
    /// under an endpoint, and only for its one route.
    private func adoptEndpointTrust() async {
        let knownHosts = policy.knownHosts
        guard await knownHosts.fingerprints(host: host, port: port).isEmpty else { return }
        for fingerprint in await knownHosts.fingerprints(host: endpointHost, port: endpointPort) {
            await knownHosts.setFingerprint(fingerprint, host: host, port: port)
        }
    }
}
