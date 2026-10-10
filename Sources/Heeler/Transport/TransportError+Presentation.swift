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
        case .hostFeatureUnavailable(let feature):
            TransportErrorPresentation(
                summary: "This feature is unavailable on the Host", detail: feature,
                recoverySuggestion: nil)
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: "SSH unavailable",
                detail: detail,
                recoverySuggestion:
                    "Check that the Host is awake and reachable, then verify its address and port.")
        case .jumpHostFailed(let underlying):
            Self.jumpHostPresentation(underlying)
        case .overlayFailed(let network, let reason):
            Self.overlayPresentation(network: network, reason: reason)
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
        case .rsaKeyCorrupt:
            TransportErrorPresentation(
                summary: "The RSA Key is corrupted",
                detail: nil,
                recoverySuggestion:
                    "Replace it and register the new public key on every Host that uses it.")
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: "The Host does not accept RSA-SHA2-512",
                detail: nil,
                recoverySuggestion:
                    "Enable rsa-sha2-512 signatures on the Host, or choose another "
                    + "authentication method.")
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
                    "Put herdr's install directory on the account's non-interactive SSH PATH.")
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
        case .invalidDirectoryPath(let path):
            TransportErrorPresentation(
                summary: "That folder path cannot be opened",
                detail: path,
                recoverySuggestion: "Pick a folder from the list instead of typing a path.")
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
        case .gitTimedOut:
            TransportErrorPresentation(
                summary: "Reading Changes timed out",
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

    /// Overlay failures name the network, not the Host: the Host was never
    /// contacted, and the fix lives in Settings › Overlay Networks.
    private static func overlayPresentation(
        network: String, reason: OverlayFailure
    ) -> TransportErrorPresentation {
        switch reason {
        case .notConfigured:
            TransportErrorPresentation(
                summary: "This Host's overlay network no longer exists",
                detail: nil,
                recoverySuggestion: "Choose another network in Edit Host.")
        case .catalogUnreadable:
            TransportErrorPresentation(
                summary: "The saved overlay networks could not be read",
                detail: nil,
                recoverySuggestion: "Update Heeler, then reconnect.")
        case .notReady(let detail):
            TransportErrorPresentation(
                summary: "Overlay network “\(network)” is not ready yet",
                detail: detail,
                recoverySuggestion:
                    "If it is waiting for approval, authorize this device in the network's "
                    + "admin console.")
        case .misconfigured(let detail):
            TransportErrorPresentation(
                summary: "Overlay network “\(network)” is misconfigured",
                detail: detail,
                recoverySuggestion: "Fix it in Settings › Overlay Networks.")
        case .loginRequired:
            TransportErrorPresentation(
                summary: "Overlay network “\(network)” needs sign-in",
                detail: nil,
                recoverySuggestion: "Sign in from Settings › Overlay Networks.")
        case .signedOut:
            TransportErrorPresentation(
                summary: "This device is signed out of overlay network “\(network)”",
                detail: nil,
                recoverySuggestion: "Connect it again in Settings › Overlay Networks.")
        case .startFailed(let detail):
            TransportErrorPresentation(
                summary: "Overlay network “\(network)” could not start",
                detail: detail,
                recoverySuggestion: "Check its settings in Settings › Overlay Networks.")
        case .unreachable(let detail):
            TransportErrorPresentation(
                summary: "Unreachable over overlay network “\(network)”",
                detail: detail,
                recoverySuggestion:
                    "Check that the machine has joined the network, then verify its overlay "
                    + "address and port.")
        case .timedOut:
            TransportErrorPresentation(
                summary: "Overlay network “\(network)” did not answer in time",
                detail: nil,
                recoverySuggestion: nil)
        }
    }

    private static func jumpHostPresentation(
        _ underlying: TransportError
    ) -> TransportErrorPresentation {
        switch underlying {
        case .hostFeatureUnavailable:
            underlying.presentation
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
        case .deviceKeyCorrupt, .rsaKeyCorrupt:
            underlying.presentation
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: "The Jump Host does not accept RSA-SHA2-512",
                detail: nil,
                recoverySuggestion:
                    "Enable rsa-sha2-512 signatures on the Jump Host, or choose another "
                    + "authentication method.")
        default:
            TransportErrorPresentation(
                summary: "Jump Host: \(underlying.presentation.summary)",
                detail: underlying.presentation.detail,
                recoverySuggestion: nil)
        }
    }
}
