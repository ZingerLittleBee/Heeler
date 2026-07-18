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
    /// Manual named-session field (#14: no enumeration); blank means the
    /// default herdr session.
    var sessionName: String
    /// Absolute socat path on the Host.
    var socatPath: String

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
