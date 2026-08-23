/// What one `TransportError` is allowed to say: a Summary, an optional Detail
/// carrying the error's own words, and an optional Recovery Suggestion.
/// See Transport Error Presentation in `CONTEXT.md`.
struct TransportErrorPresentation: Equatable, Sendable {
    /// Short, stable, standalone. No trailing period. Safe on an ambient
    /// surface while automatic recovery is running.
    let summary: String
    /// The error's own interpolated text — a transport detail string, or
    /// herdr's code and message. Never authored instruction.
    let detail: String?
    /// Present only when the error itself supports a safe next step.
    let recoverySuggestion: String?

    /// `summary` [+ ": " + `detail`] + "." — what happened, no instruction.
    var explanation: String {
        if let detail {
            return "\(summary): \(detail)."
        }
        return "\(summary)."
    }

    /// `explanation` [+ " " + `recoverySuggestion`] — the whole presentation.
    var message: String {
        if let recoverySuggestion {
            return "\(explanation) \(recoverySuggestion)"
        }
        return explanation
    }
}

extension TransportError {
    var presentation: TransportErrorPresentation {
        switch self {
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: "SSH unavailable",
                detail: detail,
                recoverySuggestion:
                    "Check that the Host is awake and reachable, then verify its address and port.")
        case .jumpHostFailed(let underlying):
            Self.jumpHostPresentation(underlying)
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: "SSH TCP forwarding is disabled",
                detail: nil,
                recoverySuggestion: "Enable it on the Jump Host.")
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: "Authentication failed",
                detail: nil,
                recoverySuggestion: "Update this Host's credentials or authorized key.")
        case .deviceKeyCorrupt:
            TransportErrorPresentation(
                summary: "The Device Key is corrupted",
                detail: nil,
                recoverySuggestion: "Replace it and install the new public key on the Host.")
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: "The host key is not trusted",
                detail: nil,
                recoverySuggestion: "Verify it before reconnecting.")
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: "The host key changed",
                detail: nil,
                recoverySuggestion: "Verify the machine before updating trust.")
        case .socketNotFound(let path):
            TransportErrorPresentation(
                summary: "The herdr socket was not found",
                detail: path,
                recoverySuggestion: "Check this Host's session.")
        case .herdrBinaryNotFound:
            TransportErrorPresentation(
                summary: "herdr is not on this Host's SSH PATH",
                detail: nil,
                recoverySuggestion:
                    "Homebrew installs are often at /opt/homebrew/bin or /home/linuxbrew/.linuxbrew/bin — "
                    + "put that directory on the account's non-interactive PATH, "
                    + "or symlink herdr into ~/.local/bin.")
        case .streamLocalOpenFailed:
            TransportErrorPresentation(
                summary: "herdr is not running on this Host",
                detail: nil,
                recoverySuggestion: "If it is running, check SSH stream-local forwarding.")
        case .protocolVersionMismatch(let server, let supported):
            TransportErrorPresentation(
                summary: "Incompatible herdr protocol",
                detail: "herdr speaks protocol \(server); this app needs at least \(supported)",
                recoverySuggestion: "Update herdr on the Host.")
        case .homeDirectoryUnresolvable(let detail):
            TransportErrorPresentation(
                summary: "The remote home directory could not be resolved",
                detail: detail,
                recoverySuggestion: nil)
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            TransportErrorPresentation(
                summary: "The connection is busy",
                detail: nil,
                recoverySuggestion: "Close the other terminal before reconnecting.")
        case .timedOut:
            TransportErrorPresentation(
                summary: "Connection timed out",
                detail: nil,
                recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: "Connection cancelled",
                detail: nil,
                recoverySuggestion: nil)
        case .malformedResponse(let payload):
            TransportErrorPresentation(
                summary: "herdr returned an invalid response",
                detail: payload,
                recoverySuggestion: "Check its version.")
        case .apiRejected(let code, let message):
            TransportErrorPresentation(
                summary: "herdr rejected the request",
                detail: "\(message) (\(code))",
                recoverySuggestion: nil)
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: "Connection dropped",
                detail: detail,
                recoverySuggestion: nil)
        }
    }

    /// A changed host key is a security refusal, not an ordinary outage.
    /// Nested first-hop failures keep that classification: a Jump Host key
    /// change is still a host-key refusal.
    var isHostKeySecurityFailure: Bool {
        switch self {
        case .hostKeyMismatch: true
        case .jumpHostFailed(let underlying): underlying.isHostKeySecurityFailure
        default: false
        }
    }

    private static func jumpHostPresentation(
        _ underlying: TransportError
    ) -> TransportErrorPresentation {
        switch underlying {
        case .jumpHostFailed:
            underlying.presentation
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: "Jump Host unavailable",
                detail: detail,
                recoverySuggestion:
                    "Check that the Jump Host is awake and reachable, then verify its address and port.")
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: "The Jump Host rejected authentication",
                detail: nil,
                recoverySuggestion: "Update the Jump Host's credentials or authorized key.")
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: "The Jump Host's key is not trusted",
                detail: nil,
                recoverySuggestion: "Verify it before reconnecting.")
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: "The Jump Host's key changed",
                detail: nil,
                recoverySuggestion: "Verify the machine before updating trust.")
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: "SSH TCP forwarding is disabled on the Jump Host",
                detail: nil,
                recoverySuggestion: "Enable it on the Jump Host.")
        case .timedOut:
            TransportErrorPresentation(
                summary: "The Jump Host did not answer in time",
                detail: nil,
                recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: "Jump Host connection cancelled",
                detail: nil,
                recoverySuggestion: nil)
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: "The Jump Host connection dropped",
                detail: detail,
                recoverySuggestion: nil)
        case .deviceKeyCorrupt:
            underlying.presentation
        default:
            TransportErrorPresentation(
                summary: "Jump Host: \(underlying.presentation.summary)",
                detail: underlying.presentation.detail,
                recoverySuggestion: nil)
        }
    }
}
