import Foundation

/// The onboarding checklist (#14): the M0 `TransportError` taxonomy rendered
/// as actionable checks, no new probing machinery (spec #20). One connect +
/// ping exercises the whole chain, so a run fails at exactly one check —
/// everything before it demonstrably worked, everything after it is unknown.
enum PreflightCheck: CaseIterable, Sendable {
    /// SSH reachable, credentials accepted, host key trusted.
    case connection
    /// socat answers at its configured absolute path.
    case socat
    /// The herdr socket path exists on the Host.
    case herdrInstalled
    /// The socket accepts connections (a wake attempt already ran).
    case serverRunning
    /// The server speaks a protocol version this build supports.
    case protocolCompatible

    var title: String {
        switch self {
        case .connection: "SSH connection"
        case .socat: "socat installed"
        case .herdrInstalled: "herdr installed"
        case .serverRunning: "herdr server running"
        case .protocolCompatible: "protocol compatible"
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
            case .password:
                hint = "The Host rejected the login. Check the username and password."
            }
        case .hostKeyRejected:
            check = .connection
            hint = "The host key was not confirmed. Run the checks again and confirm the fingerprint."
        case .hostKeyMismatch(let known, let presented):
            check = .connection
            hint =
                "Host key changed: trusted \(known.displayString), the Host presented "
                + "\(presented.displayString). This can be a reinstalled server or an attack — "
                + "verify with the Host's owner before trusting it."
        case .socatMissing(let path):
            check = .socat
            hint =
                "socat was not found at \(path). Install it on the Host "
                + "(apt install socat / brew install socat), or correct the path "
                + "in this Host's settings."
        case .socketNotFound(let path):
            check = .herdrInstalled
            hint =
                "No herdr socket at \(path). Install and start herdr on the Host, "
                + "or fix the session name."
        case .homeDirectoryUnresolvable(let detail):
            check = .herdrInstalled
            hint =
                "Could not resolve the remote home directory, so the herdr socket "
                + "path is unknown. (\(detail))"
        case .serverNotRunning(let path):
            check = .serverRunning
            hint =
                "The socket at \(path) exists but nothing answers: the herdr server "
                + "is not running. Start herdr on the Host and run the checks again."
        case .protocolVersionMismatch(let server, let supported):
            check = .protocolCompatible
            hint =
                "The Host speaks herdr protocol \(server); this app supports "
                + "\(supported). Update herdr on the Host or update the app."
        case .malformedResponse(let detail):
            check = .protocolCompatible
            hint = "The server's reply did not parse as herdr protocol. (\(detail))"
        case .timedOut:
            check = .connection
            hint = "The Host did not answer in time. Check the connection and try again."
        case .cancelled:
            check = .connection
            hint = "The check was cancelled before it finished."
        case .channelFailed(let detail):
            check = .connection
            hint = "The connection failed unexpectedly. (\(detail))"
        case .eventsChannelAlreadyOpen:
            // Not reachable from a connect+ping preflight; keep the closed
            // taxonomy total anyway.
            check = .connection
            hint = "The connection is busy. Try again."
        }
        return PreflightReport(failure: Failure(check: check, hint: hint))
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
