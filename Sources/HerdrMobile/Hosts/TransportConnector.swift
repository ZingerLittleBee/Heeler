import Foundation

/// Opens a connected Transport for the given settings: the seam between UI
/// stores and real SSH. Production is `SSHTransportConnector`; tests inject
/// a scripted fake, so screen logic never touches Citadel (ADR 0002).
protocol TransportConnector: Sendable {
    func connect(settings: SSHTransportSettings) async throws -> any Transport
}

struct SSHTransportConnector: TransportConnector {
    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await SSHTransport.connect(settings: settings)
    }
}

extension SSHTransportSettings {
    /// Transport settings for a catalog Host, given resolved credentials and
    /// the TOFU policy the UI wires up.
    init(host: Host, credentials: SSHCredentials, hostKeyPolicy: HostKeyPolicy) {
        self.init(
            host: host.address,
            port: host.port,
            username: host.username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            socket: host.socketLocation,
            socatPath: host.socatPath)
    }
}
