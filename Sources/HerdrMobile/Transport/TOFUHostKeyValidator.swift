// @preconcurrency: Citadel predates strict concurrency; see SSHTransport.
@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH
import Synchronization

/// Bridges Citadel's promise-based host key callback onto the async TOFU
/// policy (#2):
///
///   known fingerprint, matches    -> proceed
///   known fingerprint, differs    -> hard-fail, never ask, never overwrite
///   unknown, user confirms        -> persist fingerprint, proceed
///   unknown, user declines        -> fail, persist nothing
///
/// The verdict is also recorded here because NIOSSH may wrap the promise's
/// failure on its way out of the handshake: `SSHTransport.connect` consults
/// `failure` — not the thrown error — to surface the typed taxonomy case.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let policy: HostKeyPolicy
    private let verdict = Mutex<TransportError?>(nil)

    init(host: String, port: Int, policy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.policy = policy
    }

    /// The typed failure behind an aborted handshake, if host key validation
    /// caused one.
    var failure: TransportError? {
        verdict.withLock { $0 }
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        // Fingerprint the key before hopping executors: NIOSSHPublicKey is
        // not Sendable, the digest is.
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let fingerprint = HostKeyFingerprint(publicKeyBlob: Data(buffer.readableBytesView))
        Task {
            if let failure = await self.evaluate(fingerprint: fingerprint) {
                self.verdict.withLock { $0 = failure }
                validationCompletePromise.fail(failure)
            } else {
                validationCompletePromise.succeed(())
            }
        }
    }

    private func evaluate(fingerprint: HostKeyFingerprint) async -> TransportError? {
        if let known = await policy.knownHosts.fingerprint(
            host: host, port: port, algorithm: fingerprint.algorithm)
        {
            guard known.digest == fingerprint.digest else {
                return .hostKeyMismatch(known: known, presented: fingerprint)
            }
            if known.algorithm == HostKeyFingerprint.unknownAlgorithm {
                // A pre-v2 digest had no algorithm metadata. A matching key
                // proves which algorithm it belongs to, so migrate it before
                // allowing the handshake to continue.
                await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
            }
            return nil
        }
        let candidate = HostKeyCandidate(host: host, port: port, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            return .hostKeyRejected(presented: fingerprint)
        }
        // Persist before the handshake proceeds, like OpenSSH writes
        // known_hosts on accept: a later auth failure must not re-prompt.
        await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
        return nil
    }
}
