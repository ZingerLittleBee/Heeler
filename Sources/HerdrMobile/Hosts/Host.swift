import Foundation

/// A user-added Host (CONTEXT.md): connection coordinates, how to
/// authenticate, and which herdr session to reach. Never carries a secret —
/// the password lives in the Keychain keyed by `id`, the device key in
/// `DeviceKeyStore`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    /// How the app authenticates against this Host. OpenSSH key import is
    /// deliberately absent (out of scope per spec #20).
    enum AuthMethod: String, Codable, Sendable {
        case deviceKey
        case password
    }

    /// Where socat usually lives on a stock Linux server; editable per Host
    /// because login-shell PATH cannot be trusted (ADR 0002).
    static let defaultSocatPath = "/usr/bin/socat"

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
    /// Absolute socat path on the Host.
    var socatPath: String
    /// Optional bastion this Host is reached through. Blank means a direct
    /// connection; when set, `address`/`port` are resolved *from the bastion*
    /// and normally point at a loopback port held open by a reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the bastion. Blank reuses `username`, which is the common
    /// case only when both machines share an account name.
    var jumpUsername: String

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName, socatPath
        case jumpAddress, jumpPort, jumpUsername
    }

    /// Whether this Host is reached through a bastion.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The bastion account, falling back to the Host's own username.
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
        socatPath: String = Host.defaultSocatPath,
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = ""
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.socatPath = socatPath
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        socatPath =
            try container.decodeIfPresent(String.self, forKey: .socatPath) ?? Self.defaultSocatPath
        // Absent in Hosts saved before jump-host support; a blank address
        // decodes as the direct connection those Hosts already had.
        jumpAddress = try container.decodeIfPresent(String.self, forKey: .jumpAddress) ?? ""
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername) ?? ""

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
        guard RemoteShellPath.isQuotableAbsolute(socatPath) else {
            throw DecodingError.dataCorruptedError(
                forKey: .socatPath, in: container, debugDescription: "Invalid remote socat path")
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// The herdr socket this Host's session name points at.
    var socketLocation: HerdrSocketLocation {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }
}
