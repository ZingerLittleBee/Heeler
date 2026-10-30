import Foundation

/// Opens a connected Transport for the given settings: the seam between UI
/// stores and real SSH. Production is `SSHTransportConnector`; tests inject
/// a scripted fake, so screen logic never touches an SSH library (ADR 0011).
protocol TransportConnector: Sendable {
    func connect(settings: SSHTransportSettings) async throws -> any Transport

    /// Dials a herdr-core Host. It never reaches `connect`'s Herdr TUI
    /// transport, and connecting starts no core (ADR 0031).
    func connectCore(settings: SSHTransportSettings) async throws -> any HerdrCoreTransport
}

extension TransportConnector {
    /// A connector that serves only Herdr TUI Hosts says so.
    func connectCore(settings: SSHTransportSettings) async throws -> any HerdrCoreTransport {
        throw TransportError.hostFeatureUnavailable(feature: "herdr-core Hosts")
    }
}

/// The one production SSH backend: libssh2 reaching the herdr socket over
/// direct-streamlocal (ADR 0011). There is deliberately no second path — a
/// Host that denies stream-local forwarding is a server policy to fix, not a
/// case to fall back from.
struct SSHTransportConnector: TransportConnector {
    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        // No Herdr TUI request ever goes to a herdr-core Host, whose core is
        // not the server this transport speaks to, or to a Host whose kind is
        // not confirmed yet.
        guard settings.serverKind == .herdrTUI else {
            throw TransportError.hostFeatureUnavailable(
                feature: "Herdr TUI on a \(settings.serverKind.displayName) Host")
        }
        return try await HeelerSSHTransport.connect(settings: settings)
    }

    func connectCore(settings: SSHTransportSettings) async throws -> any HerdrCoreTransport {
        HerdrCoreSSHTransport(
            connection: try await HeelerSSHTransport.connect(settings: settings),
            session: settings.coreSessionName)
    }
}

extension SSHTransportSettings {
    /// Transport settings for a catalog Host, given resolved credentials and
    /// the TOFU policy the UI wires up. Every route of the Host is offered
    /// to the race, and the Host's key is trusted by Host, whichever route
    /// reaches it (ADR 0022). `overlays` resolves each route's Overlay
    /// Network, if it names one; the route itself fails the dial when that
    /// network has since been removed.
    init(
        host: Host,
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy,
        overlays: OverlayNetworkRuntime = .shared
    ) {
        self.init(
            routes: host.routes.map { route in
                SSHRoute(
                    host: route.address.trimmingCharacters(in: .whitespaces),
                    port: route.port,
                    // Both hops use the Host's resolved credential. Device Key
                    // is the normal case; password Hosts require the same
                    // password at both hops.
                    jump: route.usesJumpHost
                        ? SSHJumpSettings(
                            host: route.jumpAddress.trimmingCharacters(in: .whitespaces),
                            port: route.jumpPort,
                            username: host.jumpUsername(on: route),
                            credentials: credentials)
                        : nil,
                    overlay: route.overlayNetworkID.map { networkID in
                        overlays.route(for: networkID)
                    },
                    id: route.id)
            },
            username: host.username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            hostKeyTrust: .host(host.id),
            socket: host.socketLocation)
        serverKind = host.serverKind
        coreSessionName = HerdrCoreSessionName.normalized(host.sessionName)
        // A Pairing Code v2 endpoint (ADR 0023) replaces the `herdr` on the
        // SSH PATH for every herdr exec; `socket` already names its socket.
        if let endpoint = host.herdrEndpoint,
            let launcher = HerdrLauncher(
                executablePath: endpoint.executablePath, socketPath: endpoint.socketPath)
        {
            herdrLauncher = launcher
            sessionListCommand = launcher.sessionListCommand
            pluginListCommand = launcher.pluginListCommand
            notificationConfigDirCommand = launcher.notificationConfigDirCommand
        }
    }
}
