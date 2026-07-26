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

    /// Where socat usually lives on a stock Linux server. Tried first, then
    /// the Host's own PATH; editable per Host for the case where neither
    /// answers (ADR 0002).
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
    /// Preferred absolute socat path on the Host.
    var socatPath: String

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName, socatPath
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        socatPath: String = Host.defaultSocatPath
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.socatPath = socatPath
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
