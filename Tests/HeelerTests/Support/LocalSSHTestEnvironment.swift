import CryptoKit
import Foundation

@testable import Heeler

/// Probes for the local e2e prerequisites: an sshd on localhost and an Ed25519
/// key seed whose public half is authorized for the current user. Tests that
/// need real SSH are skipped when either piece is missing, so the pure parts
/// of the suite still run anywhere.
///
/// Defaults match the transport-spike setup (`.local/transport-spike`);
/// everything is overridable via environment variables:
///   HERDR_TEST_SSH_SEED  path to a 32-byte Ed25519 raw seed file
///   HERDR_TEST_SSH_USER  ssh username (default: the host user, derived from
///                        the simulator container path)
///   HERDR_TEST_SSH_PORT  sshd port (default 22)
struct LocalSSHTestEnvironment: Sendable {
    let host = "127.0.0.1"
    let port: Int
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey

    static let current: LocalSSHTestEnvironment? = probe()

    private static func probe() -> LocalSSHTestEnvironment? {
        let environment = ProcessInfo.processInfo.environment

        // Tests run in the simulator but share the host filesystem, so the
        // repo path derived from #filePath is directly readable.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // HeelerTests
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

        let port = environment["HERDR_TEST_SSH_PORT"].flatMap(Int.init) ?? 22
        guard sshdIsListening(onPort: port) else { return nil }

        return LocalSSHTestEnvironment(port: port, username: username, privateKey: key)
    }

    /// The simulator has no usable user database (NSUserName and getpwuid are
    /// both empty), but its HOME sits inside the host user's home directory:
    /// /Users/<name>/Library/Developer/CoreSimulator/... — parse the name out.
    private static func hostUsername() -> String? {
        let components = URL(fileURLWithPath: NSHomeDirectory()).pathComponents
        guard components.count >= 3, components[1] == "Users" else { return nil }
        return components[2]
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
