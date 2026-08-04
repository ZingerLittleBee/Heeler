import Foundation

/// An unknown host key awaiting the user's trust decision on first connect.
struct HostKeyCandidate: Sendable, Equatable {
    let host: String
    let port: Int
    let fingerprint: HostKeyFingerprint
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
