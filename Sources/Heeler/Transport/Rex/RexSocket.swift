import Foundation

/// Where a Rex Host's server listens: the Unix socket detection found it on
/// (ADR 0049). Absolute and quotable as one remote shell word, like every path
/// Heeler names on a Host, so a path with spaces, such as macOS's
/// `~/Library/Application Support/rex/server.sock`, is fine.
struct RexSocket: Codable, Hashable, Sendable {
    let path: String

    init?(path: String) {
        guard RemoteShellPath.isQuotableAbsolute(path), !path.hasSuffix("/") else { return nil }
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case path
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        guard let socket = RexSocket(path: path) else {
            throw DecodingError.dataCorruptedError(
                forKey: .path, in: container, debugDescription: "Invalid Rex socket path")
        }
        self = socket
    }
}
