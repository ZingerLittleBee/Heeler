import Foundation

/// The onboarding checklist (#14): the M0 `TransportError` taxonomy rendered
/// as actionable checks, no new probing machinery (spec #20). One connect +
/// ping exercises the whole chain, so a run fails at exactly one check —
/// everything before it demonstrably worked, everything after it is unknown.
enum PreflightCheck: CaseIterable, Sendable {
    /// SSH reachable, credentials accepted, host key trusted.
    case connection
    /// The login shell exposes a usable absolute home directory.
    case remoteEnvironment
    /// The herdr socket path exists on the Host.
    case herdrInstalled
    /// The socket accepts connections (a wake attempt already ran).
    case serverRunning
    /// The server speaks a protocol version this build supports.
    case protocolCompatible
    /// mosh-server exists AND a real UDP handshake round-trips — required
    /// before agent sessions may ride mosh.
    case moshSupport

    var title: String {
        switch self {
        case .connection: "SSH connection"
        case .remoteEnvironment: "remote environment"
        case .herdrInstalled: "herdr installed"
        case .serverRunning: "herdr server running"
        case .protocolCompatible: "protocol compatible"
        case .moshSupport: "mosh supported"
        }
    }
}

enum PreflightCheckStatus: Equatable, Sendable {
    case passed
    /// This check's failure caused the run to stop; `hint` is the fix-it.
    case failed(hint: String)
    /// Unknown: an earlier check failed before this one could run.
    case blocked
}

/// Outcome of one preflight run, queryable per check.
struct PreflightReport: Equatable, Sendable {
    /// nil means every check passed.
    private let failure: Failure?

    private struct Failure: Equatable, Sendable {
        let check: PreflightCheck
        let hint: String
    }

    static let allPassed = PreflightReport(failure: nil)

    /// A failure outside the transport taxonomy (e.g. no stored password).
    static func failure(check: PreflightCheck, hint: String) -> PreflightReport {
        PreflightReport(failure: Failure(check: check, hint: hint))
    }

    /// Maps a transport failure onto the check it disproves, with a fix-it
    /// hint. `authMethod` steers the credential hint: a rejected device key
    /// and a wrong password have different fixes.
    static func failure(_ error: TransportError, authMethod: Host.AuthMethod) -> PreflightReport {
        let check: PreflightCheck
        let hint: String
        switch error {
        case .sshUnreachable(let detail):
            check = .connection
            hint = "Could not reach the Host over SSH. Check the address and port. (\(detail))"
        case .authenticationFailed:
            check = .connection
            switch authMethod {
            case .deviceKey:
                hint =
                    "The Host rejected the device key. Copy this Host's key line "
                    + "into ~/.ssh/authorized_keys on the Host, then run the checks again."
            case .rsaKey:
                hint =
                    "The Host rejected the RSA Key. Copy its public key from Edit Host and "
                    + "register it wherever that Host accepts SSH identities."
            case .password:
                hint = "The Host rejected the login. Check the username and password."
            }
        case .deviceKeyCorrupt:
            check = .connection
            hint =
                "The Device Key is corrupted. Edit this Host and choose Replace Device Key, "
                + "then add the new public key to ~/.ssh/authorized_keys on every Device Key Host."
        case .rsaKeyCorrupt:
            check = .connection
            hint =
                "The RSA Key is corrupted. Edit this Host and choose Replace RSA Key, then "
                + "register the new public key on every Host that uses it."
        case .rsaSignatureUnsupported:
            check = .connection
            hint =
                "The Host does not offer RSA-SHA2-512 signatures, which RSA Key requires. "
                + "Registering the key again will not help; enable rsa-sha2-512 on the Host "
                + "or choose another authentication method."
        case .hostKeyRejected:
            check = .connection
            hint = "The host key was not confirmed. Run the checks again and confirm the fingerprint."
        case .hostKeyMismatch(let known, let presented):
            check = .connection
            hint =
                "Host key changed: trusted \(known.displayString), the Host presented "
                + "\(presented.displayString). This can be a reinstalled server or an attack — "
                + "verify with the Host's owner before trusting it."
        case .socketNotFound(let path):
            check = .herdrInstalled
            hint =
                "No herdr socket at \(path). Install and start herdr on the Host, "
                + "or fix the session name."
        case .homeDirectoryUnresolvable(let detail):
            check = .remoteEnvironment
            hint =
                "Could not resolve the remote home directory, so the herdr socket "
                + "path is unknown. (\(detail))"
        case .invalidDirectoryPath(let path):
            check = .remoteEnvironment
            hint = "That folder path cannot be opened: \(path)."
        case .streamLocalOpenFailed(let path):
            check = .serverRunning
            hint =
                "Could not open the herdr socket at \(path). Start herdr on the Host, "
                + "or enable SSH stream-local forwarding and run the checks again."
        case .tcpForwardingUnavailable:
            check = .connection
            hint =
                "The Jump Host refused TCP forwarding. Enable AllowTcpForwarding "
                + "in its SSH server configuration and try again."
        case .protocolVersionMismatch(let server, let supported):
            check = .protocolCompatible
            // Only reachable below the floor now: a newer Host connects and
            // carries an advisory notice instead of failing here.
            hint =
                "The Host speaks herdr protocol \(server); this app needs at least "
                + "\(supported). Update herdr on the Host."
        case .malformedResponse(let detail):
            check = .protocolCompatible
            hint = "The server's reply did not parse as herdr protocol. (\(detail))"
        case .timedOut:
            check = .connection
            hint = "The Host did not answer in time. Check the connection and try again."
        case .cancelled:
            check = .connection
            hint = "The check was cancelled before it finished."
        case .apiRejected(let code, let message):
            check = .serverRunning
            hint = "herdr answered but rejected the check: \(message) (\(code))"
        case .moshSessionFailed(let detail):
            // A connect+ping preflight never opens a mosh session; keep the
            // closed taxonomy total anyway.
            check = .connection
            hint = "The mosh session failed. (\(detail))"
        case .channelFailed(let detail):
            check = .connection
            hint = "The connection failed unexpectedly. (\(detail))"
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            // Not reachable from a connect+ping preflight; keep the closed
            // taxonomy total anyway.
            check = .connection
            hint = "The connection is busy. Try again."
        case .herdrBinaryNotFound:
            // Preflight is one connect + ping and never execs herdr, so this
            // case cannot fire here. Keep the closed taxonomy total anyway.
            check = .connection
            hint = "The herdr CLI was not found on the Host."
        case .jumpHostFailed(let underlying):
            // The first hop broke, so the Host itself was never contacted and
            // nothing about it has been disproved. Name the Jump Host as the
            // thing to fix, or the user goes and debugs the wrong machine.
            check = .connection
            hint = Self.jumpHostHint(underlying, authMethod: authMethod)
        }
        return PreflightReport(failure: Failure(check: check, hint: hint))
    }

    /// Guidance for a first-hop failure. Deliberately not a recursive call
    /// into the Host-facing hints: every one of those tells the user to go fix
    /// something on the Host, which is exactly the wrong machine here.
    private static func jumpHostHint(
        _ error: TransportError, authMethod: Host.AuthMethod
    ) -> String {
        switch error {
        case .sshUnreachable(let detail):
            "Could not reach the Jump Host. Check its address and port. (\(detail))"
        case .authenticationFailed:
            switch authMethod {
            case .deviceKey:
                "The Jump Host rejected the Device Key. Add this Host's key line to "
                    + "~/.ssh/authorized_keys there, then run the checks again."
            case .rsaKey:
                "The Jump Host rejected the RSA Key. Register its public key on the Jump Host, "
                    + "then run the checks again."
            case .password:
                "The Jump Host rejected the login. It must accept the same password configured "
                    + "for this Host; separate passwords are not supported."
            }
        case .hostKeyRejected:
            "The Jump Host's key was not confirmed. Run the checks again and confirm "
                + "the fingerprint."
        case .hostKeyMismatch(let known, let presented):
            "Jump Host key changed: trusted \(known.displayString), it presented "
                + "\(presented.displayString). This can be a reinstalled server or an "
                + "attack — verify with its owner before trusting it."
        case .deviceKeyCorrupt:
            "The Device Key is corrupted, so the Jump Host could not be reached. Edit "
                + "this Host and choose Replace Device Key."
        case .rsaKeyCorrupt:
            "The RSA Key is corrupted, so the Jump Host could not be reached. Edit this Host "
                + "and choose Replace RSA Key."
        case .rsaSignatureUnsupported:
            "The Jump Host does not offer RSA-SHA2-512 signatures, which RSA Key requires on "
                + "both hops. Enable rsa-sha2-512 there or choose another authentication method."
        case .timedOut:
            "The Jump Host did not answer in time. Check the connection and try again."
        case .cancelled:
            "The check was cancelled before it finished."
        default:
            "Could not connect through the Jump Host. (\(String(describing: error)))"
        }
    }

    subscript(check: PreflightCheck) -> PreflightCheckStatus {
        guard let failure else { return .passed }
        let checks = PreflightCheck.allCases
        guard
            let failedIndex = checks.firstIndex(of: failure.check),
            let index = checks.firstIndex(of: check)
        else { return .blocked }
        if index < failedIndex { return .passed }
        if index == failedIndex { return .failed(hint: failure.hint) }
        return .blocked
    }

    var isFullyPassed: Bool {
        failure == nil
    }
}
