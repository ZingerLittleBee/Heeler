import Foundation

/// Opens a connected Transport for the given settings: the seam between UI
/// stores and real SSH. Production is `SSHTransportConnector`; tests inject
/// a scripted fake, so screen logic never touches an SSH library (ADR 0011).
protocol TransportConnector: Sendable {
    func connect(settings: SSHTransportSettings) async throws -> any Transport
}

/// The one production SSH backend: libssh2 reaching the herdr socket over
/// direct-streamlocal (ADR 0011). There is deliberately no second path — a
/// Host that denies stream-local forwarding is a server policy to fix, not a
/// case to fall back from.
struct SSHTransportConnector: TransportConnector {
    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await HeelerSSHTransport.connect(settings: settings)
    }
}

extension SSHTransportSettings {
    /// Transport settings for a catalog Host, given resolved credentials and
    /// the TOFU policy the UI wires up. `overlays` resolves the Host's
    /// Overlay Network, if it names one; the route itself fails the dial when
    /// that network has since been removed.
    init(
        host: Host,
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy,
        overlays: OverlayNetworkRuntime = .shared
    ) {
        self.init(
            host: host.address,
            port: host.port,
            username: host.username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            socket: host.socketLocation,
            // Both hops use the Host's resolved credential. Device Key is the
            // normal case; password Hosts require the same password at both hops.
            jump: host.usesJumpHost
                ? SSHJumpSettings(
                    host: host.jumpAddress.trimmingCharacters(in: .whitespaces),
                    port: host.jumpPort,
                    username: host.resolvedJumpUsername,
                    credentials: credentials)
                : nil,
            overlay: host.overlayNetworkID.map { networkID in
                overlays.route(for: networkID)
            })
    }
}
