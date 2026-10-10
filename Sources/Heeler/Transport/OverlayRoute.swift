import Foundation
import HeelerOverlay

/// How a Host's first hop reaches its SSH server through an Overlay Network
/// (ADR 0021). The route replaces only the byte stream under SSH: host-key
/// verification, authentication, and every channel stay the same.
///
/// `dial` opens one fresh TCP stream to `host:port` on the overlay within
/// `timeout`. It throws `TransportError` — `.overlayFailed` for the overlay's
/// own failures — so the app's error taxonomy is never bypassed.
struct OverlayRoute: Sendable {
    /// The Overlay Network's display name, for diagnostics and copy.
    let networkName: String
    let dial: @Sendable (_ host: String, _ port: UInt16, _ timeout: Duration) async throws
        -> OverlayDialedStream
}

/// Why an Overlay Network could not carry a connection. See
/// `TransportError.overlayFailed`.
enum OverlayFailure: Sendable, Equatable {
    /// The Host names an Overlay Network that no longer exists.
    case notConfigured
    /// The saved Overlay Network catalog could not be read, so no network
    /// can be resolved (typically one written by a newer Heeler).
    case catalogUnreadable
    /// The network's settings or stored secret are incomplete or malformed.
    case misconfigured(String)
    /// Tailscale wants an interactive sign-in at this URL first.
    case loginRequired(URL)
    /// The user signed this device out of the Tailscale network; it stays
    /// out until they connect it again in Settings.
    case signedOut
    /// The node has not come online yet for a reason that can clear on its
    /// own: awaiting an admin's approval, no address assigned, a controller
    /// briefly unreachable. Retried with the usual backoff, up to
    /// `OverlayNetworkRuntime.startFailureLimit` consecutive attempts.
    case notReady(String)
    /// The node kept failing to start or join (rejected key, wrong
    /// controller…); automatic retries have stopped.
    case startFailed(String)
    /// The node is up, but the peer did not accept the connection.
    case unreachable(String)
    /// The node did not come up or connect in time.
    case timedOut
}

extension TransportError {
    /// Maps a node failure into the app taxonomy. Cancellation stays plain
    /// `.cancelled`: it says nothing about the overlay. A start failure is
    /// `.notReady` (retryable) until `isPersistent` says retries have run out.
    init(overlay error: OverlayError, network: String, isPersistent: Bool = false) {
        switch error {
        case .startFailed(let detail):
            self = .overlayFailed(
                network: network, reason: isPersistent ? .startFailed(detail) : .notReady(detail))
        case .loginRequired(let url):
            self = .overlayFailed(network: network, reason: .loginRequired(url))
        case .dialFailed(let detail):
            self = .overlayFailed(network: network, reason: .unreachable(detail))
        case .timedOut:
            self = .overlayFailed(network: network, reason: .timedOut)
        case .cancelled:
            self = .cancelled
        case .invalidConfiguration(let detail):
            self = .overlayFailed(network: network, reason: .misconfigured(detail))
        }
    }

    /// The sign-in URL an overlay failure is waiting on, if any.
    var overlayLoginURL: URL? {
        guard case .overlayFailed(_, .loginRequired(let url)) = self else { return nil }
        return url
    }
}
