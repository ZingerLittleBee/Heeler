import CryptoKit
import Foundation
import HeelerSSH

/// The production pairing ceremony client (ADR 0007): a dedicated one-shot
/// SSH client beside Transport. Two short-lived connections perform Bootstrap
/// Enrollment and the verified Device Key reconnect, with the Pairing Code's
/// Host Key pin enforced before either authentication attempt.
struct SSHPairingConnector: PairingConnector {
    /// TCP establishment and SSH handshake budget per candidate address.
    var perAddressTimeout: Duration = .seconds(4)
    /// Deadline for the whole Enrollment forced-command exchange.
    var enrollTimeout: Duration = .seconds(20)
    /// Comment on the submitted Device Key line.
    var deviceKeyComment: String = "heeler"

    private static let authenticationTimeout: Duration = .seconds(10)
    private static let cleanupTimeout: Duration = .seconds(2)
    private static let maximumEnrollmentLineBytes = 4_096

    func pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: @escaping @Sendable (PairingStep) -> Void
    ) async throws -> PairingResult {
        guard let bootstrap = code.bootstrap else {
            onStep(.reach)
            let reached = try await reach(
                code: code,
                identity: deviceKey,
                whenAuthenticationFails: .verificationFailed(
                    detail: "The Host did not accept the Device Key; it is not enrolled there yet."
                ))
            onStep(.verify)
            await Self.close(reached.connection)
            return PairingResult(
                address: reached.address,
                port: code.port,
                username: code.username,
                hostKeyFingerprint: reached.presented)
        }

        guard
            let bootstrapPrivateKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: bootstrap.seed)
        else {
            throw PairingCeremonyError.bootstrapRejected
        }
        let bootstrapKey = DeviceKey(privateKey: bootstrapPrivateKey)

        onStep(.reach)
        let reached = try await reach(
            code: code,
            identity: bootstrapKey,
            whenAuthenticationFails: .bootstrapRejected)

        onStep(.enroll)
        do {
            try await enroll(deviceKey: deviceKey, over: reached.connection)
        } catch {
            await Self.close(reached.connection)
            throw error
        }
        await Self.close(reached.connection)

        try Task.checkCancellation()
        onStep(.verify)
        return try await verify(code: code, address: reached.address, deviceKey: deviceKey)
    }

    // MARK: Reach

    private struct ReachedHost {
        let connection: SSHConnection
        let address: String
        let presented: HostKeyFingerprint
    }

    /// Tries candidates in order. A different Host Key identifies another
    /// machine and is skipped. Once the pin matches, an authentication
    /// rejection is authoritative for the ceremony stage and stops failover.
    private func reach(
        code: PairingCode,
        identity: DeviceKey,
        whenAuthenticationFails: PairingCeremonyError
    ) async throws -> ReachedHost {
        var attempts: [String] = []

        for address in code.addresses {
            try Task.checkCancellation()
            let endpoint: SSHEndpoint
            do {
                endpoint = try Self.endpoint(address: address, port: code.port)
            } catch {
                attempts.append("\(address): invalid SSH endpoint")
                continue
            }

            let connection: SSHConnection
            do {
                connection = try await SSHConnection.connect(
                    to: endpoint,
                    timeout: perAddressTimeout)
            } catch SSHError.cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempts.append("\(address): \(error)")
                continue
            }

            let presented = HostKeyFingerprint(publicKeyBlob: connection.hostKey.key)
            guard presented == code.hostKeyFingerprint else {
                await Self.close(connection)
                attempts.append(
                    "\(address): presented \(presented.displayString), not the pinned host key")
                continue
            }

            do {
                try await Self.authenticate(
                    connection,
                    username: code.username,
                    identity: identity)
                return ReachedHost(
                    connection: connection,
                    address: address,
                    presented: presented)
            } catch SSHError.authenticationFailed {
                await Self.close(connection)
                throw whenAuthenticationFails
            } catch SSHError.cancelled {
                await Self.close(connection)
                throw CancellationError()
            } catch is CancellationError {
                await Self.close(connection)
                throw CancellationError()
            } catch {
                await Self.close(connection)
                attempts.append("\(address): \(error)")
            }
        }

        throw PairingCeremonyError.hostUnreachable(detail: attempts.joined(separator: "; "))
    }

    // MARK: Enroll

    /// The Bootstrap authorized_keys entry forces the Enrollment command, so
    /// this requested command is deliberately inert. Exactly one Device Key
    /// line is sent and only one bounded protocol line is accepted.
    private func enroll(deviceKey: DeviceKey, over connection: SSHConnection) async throws {
        let line = deviceKey.authorizedKeysLine(comment: deviceKeyComment)
        guard
            !line.utf8.contains(0),
            !line.contains("\n"),
            !line.contains("\r"),
            line.utf8.count < Self.maximumEnrollmentLineBytes
        else {
            throw PairingCeremonyError.enrollmentFailed(
                detail: "the Device Key submission was not one bounded line")
        }

        let response: Data
        do {
            response = try await connection.executeResponseLine(
                "heeler-enroll",
                input: Data((line + "\n").utf8),
                maximumResponseBytes: Self.maximumEnrollmentLineBytes,
                timeout: enrollTimeout)
        } catch SSHError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch SSHError.timedOut {
            throw PairingCeremonyError.enrollmentFailed(
                detail: "the Enrollment exchange timed out")
        } catch SSHError.unexpectedEOF {
            throw PairingCeremonyError.enrollmentFailed(
                detail: "the accept entrypoint closed without answering")
        } catch {
            throw PairingCeremonyError.enrollmentFailed(detail: "\(error)")
        }

        guard response.last == 0x0A else {
            throw PairingCeremonyError.enrollmentFailed(
                detail: "the accept entrypoint closed without answering")
        }
        let responseLine = String(decoding: response.dropLast(), as: UTF8.self)
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

    /// Reconnects to the successful candidate with the same Host Key pin and
    /// the Device Key. A PairingResult exists only after this authentication.
    private func verify(
        code: PairingCode,
        address: String,
        deviceKey: DeviceKey
    ) async throws -> PairingResult {
        let endpoint: SSHEndpoint
        do {
            endpoint = try Self.endpoint(address: address, port: code.port)
        } catch {
            throw PairingCeremonyError.verificationFailed(detail: "invalid SSH endpoint")
        }

        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(
                to: endpoint,
                timeout: perAddressTimeout)
        } catch SSHError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PairingCeremonyError.verificationFailed(detail: "\(error)")
        }

        let presented = HostKeyFingerprint(publicKeyBlob: connection.hostKey.key)
        guard presented == code.hostKeyFingerprint else {
            await Self.close(connection)
            throw PairingCeremonyError.verificationFailed(
                detail: "the host key changed mid-ceremony to \(presented.displayString)")
        }

        do {
            try await Self.authenticate(
                connection,
                username: code.username,
                identity: deviceKey)
            await Self.close(connection)
            return PairingResult(
                address: address,
                port: code.port,
                username: code.username,
                hostKeyFingerprint: presented)
        } catch SSHError.authenticationFailed {
            await Self.close(connection)
            throw PairingCeremonyError.verificationFailed(
                detail: "the Host did not accept the enrolled Device Key")
        } catch SSHError.cancelled {
            await Self.close(connection)
            throw CancellationError()
        } catch is CancellationError {
            await Self.close(connection)
            throw CancellationError()
        } catch {
            await Self.close(connection)
            throw PairingCeremonyError.verificationFailed(detail: "\(error)")
        }
    }

    // MARK: Plumbing

    private static func authenticate(
        _ connection: SSHConnection,
        username: String,
        identity: DeviceKey
    ) async throws {
        try await connection.authenticate(
            username: username,
            publicKey: identity.publicKeyBlob,
            signer: { challenge in
                try identity.privateKey.signature(for: challenge)
            },
            timeout: authenticationTimeout)
    }

    private static func endpoint(address: String, port: Int) throws -> SSHEndpoint {
        guard !address.isEmpty, let port = UInt16(exactly: port) else {
            throw SSHError.invalidEndpoint
        }
        return SSHEndpoint(host: address, port: port)
    }

    private static func close(_ connection: SSHConnection) async {
        try? await connection.close(timeout: cleanupTimeout)
    }

    private static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }
}
