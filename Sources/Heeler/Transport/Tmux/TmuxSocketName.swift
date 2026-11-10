import Foundation

/// The name of the socket a tmux Host's server listens on, as `tmux -L` takes it
/// (ADR 0042). A blank name is tmux's own default. A socket path is not a name:
/// Heeler resolves the path itself and never takes one from the user.
enum TmuxSocketName {
    /// What tmux calls the socket of a server started without `-L`.
    static let defaultName = "default"
    static let maximumUTF8Length = 64

    static func normalized(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultName : name
    }

    /// Letters, digits, `.`, `_` and `-`: a name that is one word to every shell
    /// and to tmux, and one file name in the socket directory.
    static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        return name != "." && name != ".." && !name.hasPrefix("-")
            && name.utf8.count <= maximumUTF8Length
            && name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            }
    }

    /// Why Heeler cannot use this name, nil when it can.
    static func refusal(_ value: String) -> String? {
        guard !isValid(value) else { return nil }
        return String(localized: "Heeler cannot use the tmux socket name \"\(normalized(value))\". A name uses letters, digits, \".\", \"_\" and \"-\", up to \(maximumUTF8Length) bytes, and does not start with \"-\". A socket path is not supported.")
    }
}

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
