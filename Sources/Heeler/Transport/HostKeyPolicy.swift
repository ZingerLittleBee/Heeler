import Foundation

/// An unknown host key awaiting the user's trust decision on first connect.
struct HostKeyCandidate: Sendable, Equatable {
    let host: String
    let port: Int
    let fingerprint: HostKeyFingerprint
}

/// Where a hop's trusted host-key fingerprints live in `KnownHostsStore`.
enum HostKeyTrust: Sendable, Equatable {
    /// Keyed by the endpoint dialled, as OpenSSH's known_hosts is: Jump
    /// Hosts, and connections not made for a catalog Host.
    case endpoint
    /// Keyed by a catalog Host, so every Route reaching it must present the
    /// same key (ADR 0022). A Route's LAN address answered by some other
    /// machine elsewhere is then refused before authentication.
    case host(UUID)

    /// The store key (`host`, `port`) for this trust at `host:port`.
    func storageKey(host: String, port: Int) -> (host: String, port: Int) {
        switch self {
        case .endpoint:
            (host, port)
        case .host(let id):
            Self.hostKey(id)
        }
    }

    /// The store key of a catalog Host's trust. Port 0 never names a real
    /// endpoint, so it cannot collide with an endpoint entry.
    static func hostKey(_ id: UUID) -> (host: String, port: Int) {
        ("heeler-host:\(id.uuidString.lowercased())", 0)
    }
}

/// TOFU host key policy: trust the fingerprint the user confirmed on first
/// connect, hard-fail when a known Host's key changes. No SSH primitive
/// leaks through this surface — the UI implements the confirmation and injects
/// the store without seeing one.
struct HostKeyPolicy: Sendable {
    /// Fingerprints of already-trusted Hosts.
    var knownHosts: any KnownHostsStore

    /// First-connect confirmation, implemented by the UI: shown the
    /// candidate, returns whether the user trusts it. Returning false fails
    /// the connection with `.hostKeyRejected` and stores nothing.
    var confirmFirstConnect: @Sendable (HostKeyCandidate) async -> Bool

    init(
        knownHosts: any KnownHostsStore,
        confirmFirstConnect: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) {
        self.knownHosts = knownHosts
        self.confirmFirstConnect = confirmFirstConnect
    }
}
