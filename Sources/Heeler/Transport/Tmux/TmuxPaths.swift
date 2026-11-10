import Foundation

/// Where a tmux Host's tmux and its server's socket are, as the user's
/// interactive login shell resolved them (ADR 0042). Every command runs
/// `executable` with `-S socket`, so both are absolute and quotable as one
/// remote shell word.
struct TmuxPaths: Codable, Hashable, Sendable {
    let executable: String
    let socket: String

    init?(executable: String, socket: String) {
        guard RemoteShellPath.isQuotableAbsolute(executable), RemoteShellPath.isQuotableAbsolute(socket),
            !executable.hasSuffix("/"), !socket.hasSuffix("/")
        else { return nil }
        self.executable = executable
        self.socket = socket
    }

    private enum CodingKeys: String, CodingKey {
        case executable, socket
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let executable = try container.decode(String.self, forKey: .executable)
        let socket = try container.decode(String.self, forKey: .socket)
        guard let paths = TmuxPaths(executable: executable, socket: socket) else {
            throw DecodingError.dataCorruptedError(
                forKey: .executable, in: container, debugDescription: "Invalid tmux paths")
        }
        self = paths
    }

    /// Whether `socket` is the one this socket name resolves to. Paths resolved
    /// for another name say nothing of this one.
    func serves(socketName: String) -> Bool {
        socket.hasSuffix("/" + TmuxSocketName.normalized(socketName))
    }
}
