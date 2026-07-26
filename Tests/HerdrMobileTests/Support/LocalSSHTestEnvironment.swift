import CryptoKit
import Foundation

@testable import HerdrMobile

/// Probes for the local e2e prerequisites: an sshd on localhost, a socat
/// binary, and an Ed25519 key seed whose public half is authorized for the
/// current user. Tests that need real SSH are skipped when any piece is
/// missing, so the pure parts of the suite still run anywhere.
///
/// Defaults match the transport-spike setup (`.local/transport-spike`);
/// everything is overridable via environment variables:
///   HERDR_TEST_SSH_SEED  path to a 32-byte Ed25519 raw seed file
///   HERDR_TEST_SSH_USER  ssh username (default: the host user, derived from
///                        the simulator container path)
///   HERDR_TEST_SSH_PORT  sshd port (default 22)
///   HERDR_TEST_SOCAT     absolute socat path (default /opt/homebrew/bin/socat)
struct LocalSSHTestEnvironment: Sendable {
    let host = "127.0.0.1"
    let port: Int
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey
    let socatPath: String

    static var isAvailable: Bool { current != nil }

    static let current: LocalSSHTestEnvironment? = probe()

    private static func probe() -> LocalSSHTestEnvironment? {
        let environment = ProcessInfo.processInfo.environment

        // Tests run in the simulator but share the host filesystem, so the
        // repo path derived from #filePath is directly readable.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // HerdrMobileTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let seedPath =
            environment["HERDR_TEST_SSH_SEED"]
            ?? repoRoot.appendingPathComponent(".local/transport-spike/.spike_seed").path

        guard
            let seed = try? Data(contentsOf: URL(fileURLWithPath: seedPath)),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }

        guard let username = environment["HERDR_TEST_SSH_USER"] ?? hostUsername() else {
            return nil
        }

        let socatPath = environment["HERDR_TEST_SOCAT"] ?? "/opt/homebrew/bin/socat"
        guard FileManager.default.isExecutableFile(atPath: socatPath) else { return nil }

        let port = environment["HERDR_TEST_SSH_PORT"].flatMap(Int.init) ?? 22
        guard sshdIsListening(onPort: port) else { return nil }

        return LocalSSHTestEnvironment(
            port: port, username: username, privateKey: key, socatPath: socatPath)
    }

    /// The simulator has no usable user database (NSUserName and getpwuid are
    /// both empty), but its HOME sits inside the host user's home directory:
    /// /Users/<name>/Library/Developer/CoreSimulator/... — parse the name out.
    private static func hostUsername() -> String? {
        let components = URL(fileURLWithPath: NSHomeDirectory()).pathComponents
        guard components.count >= 3, components[1] == "Users" else { return nil }
        return components[2]
    }

    /// The harness sshd standing in for a Jump Host. Hopping 127.0.0.1 ->
    /// 127.0.0.1 drives the same direct-tcpip path a real Jump Host would,
    /// without needing a second machine.
    var loopbackJump: SSHJumpSettings {
        SSHJumpSettings(
            host: host, port: port, username: username, credentials: .ed25519(privateKey))
    }

    /// Transport settings for the harness Host with test defaults: seeded-key
    /// credentials and an auto-accepting TOFU policy over a fresh in-memory
    /// store. Host key behavior itself is under test only in
    /// `SSHHostKeyE2ETests`, which passes its own policy.
    func makeSettings(
        socket: HerdrSocketLocation,
        socatPath: String? = nil,
        socatDiscovery: SocatDiscovery? = nil,
        wakeCommand: String? = nil,
        requestTimeout: Duration? = nil,
        homeCommand: String? = nil,
        stageDirectoryCommand: String? = nil,
        credentials: SSHCredentials? = nil,
        hostKeyPolicy: HostKeyPolicy? = nil,
        jump: SSHJumpSettings? = nil
    ) -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host,
            port: port,
            username: username,
            credentials: credentials ?? .ed25519(privateKey),
            hostKeyPolicy: hostKeyPolicy
                ?? HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: socket,
            socatPath: socatPath ?? self.socatPath,
            jump: jump)
        if let socatDiscovery { settings.socatDiscovery = socatDiscovery }
        if let wakeCommand { settings.wakeCommand = wakeCommand }
        if let requestTimeout { settings.requestTimeout = requestTimeout }
        if let homeCommand { settings.homeCommand = homeCommand }
        if let stageDirectoryCommand { settings.stageDirectoryCommand = stageDirectoryCommand }
        return settings
    }

    private static func sshdIsListening(onPort port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
