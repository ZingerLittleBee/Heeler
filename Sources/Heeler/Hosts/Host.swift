import Foundation

/// A user-added Host (CONTEXT.md): connection coordinates, how to
/// authenticate, and which herdr session to reach. Never carries a secret —
/// the password lives in the Keychain keyed by `id`, and private keys live in
/// `DeviceKeyStore` or `RSAKeyStore`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    /// How the app authenticates against this Host. OpenSSH key import is
    /// deliberately absent (out of scope per spec #20).
    enum AuthMethod: String, Codable, Sendable {
        case deviceKey
        case rsaKey
        case password
    }

    let id: UUID
    /// Optional display label; blank falls back to `user@address`.
    var name: String
    var address: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    /// Persisted session selection; onboarding discovers available sessions,
    /// while this field remains editable for older herdr versions. Blank
    /// means the default herdr session.
    var sessionName: String
    /// Optional Jump Host this Host is reached through. Blank means a direct
    /// connection; when set, `address`/`port` are resolved from the Jump Host
    /// and normally point at a loopback port held open by a reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the Jump Host. Blank reuses `username`, which is the common
    /// case only when both machines share an account name.
    var jumpUsername: String
    /// The Host's own herdr endpoint, from a Pairing Code v2 (ADR 0021). When
    /// set it wins over `sessionName`: every connection uses its socket and
    /// every herdr exec its launcher. nil keeps the home-relative session
    /// socket and the `herdr` on the SSH PATH.
    var herdrEndpoint: HerdrEndpoint?

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName
        case jumpAddress, jumpPort, jumpUsername
        case herdrEndpoint
    }

    /// Whether this Host is reached through a Jump Host.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Jump Host account, falling back to the Host's own username.
    var resolvedJumpUsername: String {
        let trimmed = jumpUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username : trimmed
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        herdrEndpoint: HerdrEndpoint? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.herdrEndpoint = herdrEndpoint
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        let authMethodValue = try container.decode(String.self, forKey: .authMethod)
        guard let decodedAuthMethod = AuthMethod(rawValue: authMethodValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .authMethod,
                in: container,
                debugDescription: "Unknown authentication method: \(authMethodValue)")
        }
        authMethod = decodedAuthMethod
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        // Absent in Hosts saved before jump-host support; a blank address
        // decodes as the direct connection those Hosts already had.
        jumpAddress = try container.decodeIfPresent(String.self, forKey: .jumpAddress) ?? ""
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername) ?? ""
        // Absent in Hosts saved before Pairing Code v2, and in every Host not
        // paired from one. The synthesized encoder omits nil, so those Hosts
        // keep their stored bytes.
        herdrEndpoint = try container.decodeIfPresent(HerdrEndpoint.self, forKey: .herdrEndpoint)

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// The herdr socket this Host targets: its endpoint's socket when it has
    /// one, otherwise the socket its session name points at.
    var socketLocation: HerdrSocketLocation {
        if let herdrEndpoint {
            return .absolutePath(herdrEndpoint.socketPath)
        }
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }
}

/// A herdr instance a Host runs outside the user's own config home, such as
/// one bundled inside a desktop app with its own `XDG_CONFIG_HOME`. Carried
/// by a Pairing Code v2 (`plugin/README.md`, ADR 0021). Both paths are
/// validated on construction and on decode, so a value always satisfies the
/// v2 rules.
struct HerdrEndpoint: Codable, Hashable, Sendable {
    /// Absolute path of the herdr API socket. Always in herdr's own layout,
    /// `…/herdr/herdr.sock` or `…/herdr/sessions/<name>/herdr.sock`, so the
    /// plugin's hooks can name the session it serves (ADR 0020).
    let socketPath: String
    /// Absolute path of an executable that behaves as `herdr` for this
    /// endpoint. It runs as a positional argument of a POSIX `/bin/sh -c`
    /// body, never spliced into one, and never falls back to PATH.
    let executablePath: String

    /// The longest socket path every supported Host can bind and connect.
    /// Attach and wake reach herdr's client socket, named by inserting
    /// `-client` before `.sock`, so that sibling must fit too: macOS
    /// `sun_path` holds 104 bytes including the terminating NUL, leaving
    /// 103 for the client socket and 96 for this one.
    static let maximumSocketPathUTF8Length = 96

    /// nil when either path breaks the v2 rules: both must be absolute and
    /// quotable as one remote shell word, and the socket must be in herdr's
    /// layout and short enough to connect.
    init?(socketPath: String, executablePath: String) {
        guard Self.isValidPath(socketPath), Self.isValidPath(executablePath),
            socketPath.utf8.count <= Self.maximumSocketPathUTF8Length,
            Self.session(fromSocketPath: socketPath) != nil
        else { return nil }
        self.socketPath = socketPath
        self.executablePath = executablePath
    }

    private enum CodingKeys: String, CodingKey {
        case socketPath, executablePath
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let socketPath = try container.decode(String.self, forKey: .socketPath)
        let executablePath = try container.decode(String.self, forKey: .executablePath)
        guard let endpoint = HerdrEndpoint(socketPath: socketPath, executablePath: executablePath)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .socketPath, in: container,
                debugDescription: "Invalid herdr endpoint")
        }
        self = endpoint
    }

    /// The herdr session this endpoint's hooks report: `""` for the default
    /// session, otherwise the session name.
    var session: String {
        Self.session(fromSocketPath: socketPath) ?? ""
    }

    /// Absolute and quotable as one remote shell word: no `'`, `\`, or
    /// ASCII control characters (the `RemoteShellPath` rule). Spaces are fine.
    static func isValidPath(_ path: String) -> Bool {
        RemoteShellPath.isQuotableAbsolute(path)
    }

    /// The session a hook whose `HERDR_SOCKET_PATH` is `socketPath` reports,
    /// mirroring the plugin's `sessionFromSocketPath` (`plugin/src/session.js`)
    /// and its shared vectors: unset or empty is the default session `""`;
    /// `…/herdr/sessions/<name>/herdr.sock` with a valid name is `<name>`,
    /// checked first so a session named `herdr` is not read as the default;
    /// `…/herdr/herdr.sock` is `""`; any other shape is unknown (nil).
    static func session(fromSocketPath socketPath: String?) -> String? {
        guard let socketPath, !socketPath.isEmpty else { return "" }
        let socketSuffix = "/herdr.sock"
        if socketPath.hasSuffix(socketSuffix) {
            let directory = socketPath.dropLast(socketSuffix.count)
            if let slash = directory.lastIndex(of: "/") {
                let name = String(directory[directory.index(after: slash)...])
                if directory[..<slash].hasSuffix("/herdr/sessions"), HerdrSessionName.isValid(name) {
                    return name
                }
            }
        }
        return socketPath.hasSuffix("/herdr/herdr.sock") ? "" : nil
    }
}
