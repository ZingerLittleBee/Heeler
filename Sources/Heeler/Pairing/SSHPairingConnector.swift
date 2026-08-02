// @preconcurrency: Citadel predates strict concurrency; see SSHTransport.
@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization

/// The production pairing ceremony client (ADR 0007): a dedicated one-shot
/// SSH client beside `SSHTransport`, not inside it. Two short-lived
/// connections per ceremony — bootstrap (authenticate + enroll) and the
/// verified Device Key reconnect — with the host key pinned from the Pairing
/// Code on both; no TOFU prompt, no known-hosts store.
struct SSHPairingConnector: PairingConnector {
    /// TCP-establishment budget per candidate address, so one unreachable
    /// interface fails over quickly. Citadel caps the subsequent handshake
    /// and authentication at 10 seconds on its own.
    var perAddressTimeout: Duration = .seconds(4)
    /// Deadline for the whole Enrollment exec exchange. Generous: the accept
    /// entrypoint edits authorized_keys under a lock with its own 5s bound.
    var enrollTimeout: Duration = .seconds(20)
    /// Comment on the submitted Device Key line; the plugin popup shows it
    /// as the enrolled device's label. Must be printable ASCII — the accept
    /// entrypoint rejects anything else as `invalid_key`.
    var deviceKeyComment: String = "heeler"

    func pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: @escaping @Sendable (PairingStep) -> Void
    ) async throws -> PairingResult {
        guard let bootstrap = code.bootstrap else {
            // A config-only Pairing Code is this ceremony minus the
            // bootstrap connection: the Device Key must already be
            // authorized on the Host (pasted manually), so the first
            // connect doubles as the verification.
            onStep(.reach)
            let reached = try await reach(
                code: code, key: deviceKey.privateKey,
                whenAuthenticationFails: .verificationFailed(
                    detail: "The Host did not accept the Device Key; it is not enrolled there yet."
                ))
            onStep(.verify)
            try? await reached.client.close()
            return PairingResult(
                address: reached.address, port: code.port, username: code.username,
                hostKeyFingerprint: reached.presented)
        }

        // Decode-time validation guarantees a 32-byte seed, and CryptoKit
        // accepts any 32 bytes as an Ed25519 seed; an unusable Bootstrap Key
        // is still an authenticate-step failure, not a crash.
        guard
            let bootstrapKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: bootstrap.seed)
        else {
            throw PairingCeremonyError.bootstrapRejected
        }

        onStep(.reach)
        let reached = try await reach(
            code: code, key: bootstrapKey, whenAuthenticationFails: .bootstrapRejected)

        onStep(.enroll)
        do {
            try await enroll(deviceKey: deviceKey, over: reached.client)
            try? await reached.client.close()
        } catch {
            try? await reached.client.close()
            throw error
        }

        try Task.checkCancellation()
        onStep(.verify)
        return try await verify(code: code, address: reached.address, deviceKey: deviceKey)
    }

    // MARK: Reach

    private struct ReachedHost {
        let client: SSHClient
        let address: String
        /// Algorithm-aware fingerprint of the key the Host presented;
        /// digest-equal to the pinned one.
        let presented: HostKeyFingerprint
    }

    /// Tries each candidate address in order until one yields an SSH server
    /// presenting the pinned host key and accepting `key`. An address whose
    /// host key does not match the pin is some other machine — skip it and
    /// keep looking. A matching host that rejects the key IS our Host saying
    /// no; that ends the loop with `whenAuthenticationFails`.
    private func reach(
        code: PairingCode,
        key: Curve25519.Signing.PrivateKey,
        whenAuthenticationFails: PairingCeremonyError
    ) async throws -> ReachedHost {
        var attempts: [String] = []
        for address in code.addresses {
            try Task.checkCancellation()
            let validator = PinnedHostKeyValidator(pinned: code.hostKeyFingerprint)
            do {
                let client = try await SSHClient.connect(
                    host: address,
                    port: code.port,
                    authenticationMethod: .ed25519(username: code.username, privateKey: key),
                    hostKeyValidator: .custom(validator),
                    reconnect: .never,
                    connectTimeout: Self.timeAmount(perAddressTimeout))
                guard let presented = validator.presented else {
                    // Unreachable: a completed handshake ran the validator.
                    try? await client.close()
                    attempts.append("\(address): host key was never validated")
                    continue
                }
                return ReachedHost(client: client, address: address, presented: presented)
            } catch {
                // The validator's verdict is the source of truth: NIOSSH may
                // wrap its error on the way out of the handshake.
                if let mismatch = validator.mismatch {
                    attempts.append(
                        "\(address): presented \(mismatch.displayString), not the pinned host key")
                    continue
                }
                switch error {
                case SSHClientError.allAuthenticationOptionsFailed,
                    SSHClientError.unsupportedPasswordAuthentication,
                    SSHClientError.unsupportedPrivateKeyAuthentication,
                    SSHClientError.unsupportedHostBasedAuthentication:
                    throw whenAuthenticationFails
                default:
                    attempts.append("\(address): \(error)")
                }
            }
        }
        throw PairingCeremonyError.hostUnreachable(detail: attempts.joined(separator: "; "))
    }

    // MARK: Enroll

    /// One exec exchange with the Enrollment accept entrypoint: sshd ignores
    /// the requested command (`restrict,command=` forces the accept script)
    /// and the Device Key public line goes in on stdin. The first stdout
    /// line is the whole answer.
    private func enroll(deviceKey: DeviceKey, over client: SSHClient) async throws {
        let submission = deviceKey.authorizedKeysLine(comment: deviceKeyComment) + "\n"
        let responseLine = try await Self.withDeadline(
            enrollTimeout,
            onTimeout: .enrollmentFailed(detail: "the Enrollment exchange timed out")
        ) {
            var stdout = Data()
            var stderr = Data()
            do {
                try await client.withExec("herdr-mobile-enroll") { inbound, outbound in
                    // A fast-failing forced command can close the channel
                    // before this write lands; the read loop still drains
                    // the response or surfaces the failure.
                    try? await outbound.write(ByteBuffer(string: submission))
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            stdout.append(contentsOf: buffer.readableBytesView)
                            if stdout.contains(0x0A) { return }
                        case .stderr(let buffer):
                            stderr.append(contentsOf: buffer.readableBytesView)
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PairingCeremonyError.enrollmentFailed(
                    detail: "\(error); stderr: \(Self.preview(stderr))")
            }
            guard let newline = stdout.firstIndex(of: 0x0A) else {
                throw PairingCeremonyError.enrollmentFailed(
                    detail:
                        "the accept entrypoint closed without answering; stderr: \(Self.preview(stderr))"
                )
            }
            return String(decoding: stdout[stdout.startIndex..<newline], as: UTF8.self)
        }

        switch EnrollmentResponse.parse(line: responseLine) {
        case .enrolled(let fingerprint):
            let expected = HostKeyFingerprint(publicKeyBlob: deviceKey.publicKeyBlob)
            guard fingerprint == expected.displayString else {
                throw PairingCeremonyError.enrollmentFailed(
                    detail: "the Host enrolled a different key: \(fingerprint)")
            }
        case .refused(let refusal):
            throw PairingCeremonyError.enrollmentRefused(refusal)
        case nil:
            throw PairingCeremonyError.enrollmentFailed(
                detail: "unexpected accept response: \(Self.preview(Data(responseLine.utf8)))")
        }
    }

    // MARK: Verify

    /// The reconnect that proves Enrollment took effect: same address, same
    /// pinned host key, Device Key credentials. Only after this succeeds may
    /// the caller persist the Host.
    private func verify(
        code: PairingCode, address: String, deviceKey: DeviceKey
    ) async throws -> PairingResult {
        let validator = PinnedHostKeyValidator(pinned: code.hostKeyFingerprint)
        do {
            let client = try await SSHClient.connect(
                host: address,
                port: code.port,
                authenticationMethod: .ed25519(
                    username: code.username, privateKey: deviceKey.privateKey),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: Self.timeAmount(perAddressTimeout))
            guard let presented = validator.presented else {
                try? await client.close()
                throw PairingCeremonyError.verificationFailed(
                    detail: "host key was never validated")
            }
            try? await client.close()
            return PairingResult(
                address: address, port: code.port, username: code.username,
                hostKeyFingerprint: presented)
        } catch let error as PairingCeremonyError {
            throw error
        } catch {
            if let mismatch = validator.mismatch {
                throw PairingCeremonyError.verificationFailed(
                    detail: "the host key changed mid-ceremony to \(mismatch.displayString)")
            }
            switch error {
            case SSHClientError.allAuthenticationOptionsFailed:
                throw PairingCeremonyError.verificationFailed(
                    detail: "the Host did not accept the enrolled Device Key")
            default:
                throw PairingCeremonyError.verificationFailed(detail: "\(error)")
            }
        }
    }

    // MARK: Plumbing

    /// Races `operation` against a deadline. A live exec channel ignores
    /// Swift task cancellation, but cancelling ends the *local* inbound
    /// stream; the exec body then returns and Citadel closes the channel on
    /// the way out (same shape as SSHTransport's request deadline).
    private static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        onTimeout timeoutError: PairingCeremonyError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let finished = try await group.next(), let value = finished else {
                throw timeoutError
            }
            return value
        }
    }

    private static func timeAmount(_ duration: Duration) -> TimeAmount {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }

    private static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }
}

/// Validates the Host's key against the fingerprint pinned from the Pairing
/// Code: match proceeds, anything else fails — no TOFU prompt, no store
/// (ADR 0007). The verdict is recorded here because NIOSSH may wrap the
/// promise's failure on its way out of the handshake; callers consult
/// `presented`/`mismatch`, not the thrown error.
final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private struct PinMismatch: Error {}

    private let pinned: HostKeyFingerprint
    private let presentedState = Mutex<HostKeyFingerprint?>(nil)
    private let mismatchState = Mutex<HostKeyFingerprint?>(nil)

    init(pinned: HostKeyFingerprint) {
        self.pinned = pinned
    }

    /// The algorithm-aware fingerprint of the accepted host key.
    var presented: HostKeyFingerprint? { presentedState.withLock { $0 } }
    /// The fingerprint of a rejected host key, if validation failed one.
    var mismatch: HostKeyFingerprint? { mismatchState.withLock { $0 } }

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let fingerprint = HostKeyFingerprint(publicKeyBlob: Data(buffer.readableBytesView))
        if fingerprint == pinned {
            presentedState.withLock { $0 = fingerprint }
            validationCompletePromise.succeed(())
        } else {
            mismatchState.withLock { $0 = fingerprint }
            validationCompletePromise.fail(PinMismatch())
        }
    }
}
