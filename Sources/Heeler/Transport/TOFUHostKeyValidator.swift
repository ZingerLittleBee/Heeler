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
    private let verifier: HeelerSSHHostKeyVerifier
    private let verdict = Mutex<TransportError?>(nil)

    init(host: String, port: Int, policy: HostKeyPolicy) {
        verifier = HeelerSSHHostKeyVerifier(host: host, port: port, policy: policy)
    }

    /// The typed failure behind an aborted handshake, if host key validation
    /// caused one.
    var failure: TransportError? {
        verdict.withLock { $0 }
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        // Copy the key before hopping executors: NIOSSHPublicKey is not
        // Sendable, while Data is.
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let publicKeyBlob = Data(buffer.readableBytesView)
        Task {
            if let failure = await self.verifier.failure(publicKeyBlob: publicKeyBlob) {
                self.verdict.withLock { $0 = failure }
                validationCompletePromise.fail(failure)
            } else {
                validationCompletePromise.succeed(())
            }
        }
    }
}
